import Foundation
import Accelerate

/// Turns mono PCM blocks into smoothed, auto-gain-controlled band levels using vDSP.
///
/// Not thread-safe by itself; the owner calls it from a single audio queue.
struct SpectrumAnalyzer {
    let frameCount: Int
    let sampleRate: Double
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var magnitudes: [Float]

    // Smoothing / AGC state
    private var smoothed = AudioBands.silent
    private var ceilings: (bass: Float, mid: Float, high: Float, level: Float) = (0.02, 0.02, 0.02, 0.02)

    static let bassRange: ClosedRange<Double> = 30...160
    static let midRange: ClosedRange<Double> = 160...2200
    static let highRange: ClosedRange<Double> = 2200...11000

    init(frameCount: Int = 1024, sampleRate: Double = 48000) {
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        log2n = vDSP_Length(log2(Double(frameCount)).rounded())
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: frameCount)
        vDSP_hann_window(&window, vDSP_Length(frameCount), Int32(vDSP_HANN_NORM))
        real = [Float](repeating: 0, count: frameCount / 2)
        imag = [Float](repeating: 0, count: frameCount / 2)
        magnitudes = [Float](repeating: 0, count: frameCount / 2)
    }

    /// Analyses one block of `frameCount` mono samples. Returns smoothed bands.
    mutating func analyze(_ samples: UnsafeBufferPointer<Float>) -> AudioBands {
        precondition(samples.count >= frameCount)
        var windowed = [Float](repeating: 0, count: frameCount)
        vDSP_vmul(samples.baseAddress!, 1, window, 1, &windowed, 1, vDSP_Length(frameCount))

        // RMS loudness straight from the time domain.
        var rms: Float = 0
        vDSP_rmsqv(samples.baseAddress!, 1, &rms, vDSP_Length(frameCount))

        let half = frameCount / 2
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                magnitudes.withUnsafeMutableBufferPointer { mags in
                    vDSP_zvmags(&split, 1, mags.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }
        // Normalise the FFT scaling (vDSP packs a 2x factor into the real FFT).
        var scale = 1 / Float(frameCount * frameCount)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(half))

        let bass = energy(in: Self.bassRange)
        let mid = energy(in: Self.midRange)
        let high = energy(in: Self.highRange)
        let raw = AudioBands(bass: bass, mid: mid, high: high, level: rms)
        return smooth(raw)
    }

    private func energy(in range: ClosedRange<Double>) -> Float {
        let binWidth = sampleRate / Double(frameCount)
        let low = max(1, Int(range.lowerBound / binWidth))
        let high = min(magnitudes.count - 1, Int(range.upperBound / binWidth))
        guard high >= low else { return 0 }
        var sum: Float = 0
        magnitudes.withUnsafeBufferPointer { ptr in
            vDSP_sve(ptr.baseAddress! + low, 1, &sum, vDSP_Length(high - low + 1))
        }
        // Convert power to something closer to perceived loudness.
        return sqrt(sum / Float(high - low + 1))
    }

    /// Adaptive gain + attack/release smoothing.
    private mutating func smooth(_ raw: AudioBands) -> AudioBands {
        func normalise(_ value: Float, ceiling: inout Float) -> Float {
            // Ceiling follows peaks quickly and decays slowly (roughly 4 s at 45 blocks/s).
            if value > ceiling { ceiling = ceiling + (value - ceiling) * 0.3 }
            else { ceiling = max(0.0005, ceiling * 0.995) }
            let normalised = min(1, value / max(ceiling, 0.0005))
            // Soft curve so quiet passages still show something without exaggerating peaks.
            return pow(normalised, 0.8)
        }
        let bass = normalise(raw.bass, ceiling: &ceilings.bass)
        let mid = normalise(raw.mid, ceiling: &ceilings.mid)
        let high = normalise(raw.high, ceiling: &ceilings.high)
        let level = normalise(raw.level, ceiling: &ceilings.level)
        let target = AudioBands(bass: bass, mid: mid, high: high, level: level)

        func follow(_ current: Float, _ goal: Float) -> Float {
            let coefficient: Float = goal > current ? 0.45 : 0.12
            return current + (goal - current) * coefficient
        }
        smoothed = AudioBands(bass: follow(smoothed.bass, target.bass),
                              mid: follow(smoothed.mid, target.mid),
                              high: follow(smoothed.high, target.high),
                              level: follow(smoothed.level, target.level))
        return smoothed
    }
}
