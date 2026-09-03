import Foundation
import Accelerate

/// Turns mono PCM blocks into raw per-frame descriptors (band energies, RMS, spectral centroid
/// and flux) using vDSP. Normalisation and smoothing happen downstream in `FeatureExtractor`.
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
    private var previousMagnitudes: [Float]
    private var windowed: [Float]
    private var logPositions: [Float]

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
        let half = frameCount / 2
        real = [Float](repeating: 0, count: half)
        imag = [Float](repeating: 0, count: half)
        magnitudes = [Float](repeating: 0, count: half)
        previousMagnitudes = [Float](repeating: 0, count: half)
        windowed = [Float](repeating: 0, count: frameCount)
        // Log-frequency position of every bin, 0 at 40 Hz … 1 at 12 kHz, for the centroid.
        let binWidth = sampleRate / Double(frameCount)
        logPositions = (0..<half).map { bin in
            let hz = max(1, Double(bin) * binWidth)
            return Float(min(1, max(0, (log2(hz / 40) / log2(12000 / 40)))))
        }
    }

    /// Analyses one block of `frameCount` mono samples.
    mutating func analyze(_ samples: UnsafeBufferPointer<Float>, time: TimeInterval) -> FrameDescriptor {
        precondition(samples.count >= frameCount)
        vDSP_vmul(samples.baseAddress!, 1, window, 1, &windowed, 1, vDSP_Length(frameCount))

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
        var scale = 1 / Float(frameCount * frameCount)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(half))

        let bass = energy(in: Self.bassRange)
        let mid = energy(in: Self.midRange)
        let high = energy(in: Self.highRange)

        // Spectral centroid (log-frequency weighted) and positive flux, from bin 1 upward.
        var weightedSum: Float = 0
        var magnitudeSum: Float = 0
        var flux: Float = 0
        for bin in 1..<half {
            let m = sqrt(magnitudes[bin])
            weightedSum += m * logPositions[bin]
            magnitudeSum += m
            let delta = m - previousMagnitudes[bin]
            if delta > 0 { flux += delta }
            previousMagnitudes[bin] = m
        }
        let centroid = magnitudeSum > 1e-7 ? weightedSum / magnitudeSum : 0.5
        let normalisedFlux = magnitudeSum > 1e-7 ? flux / magnitudeSum : 0

        return FrameDescriptor(time: time, bass: bass, mid: mid, high: high, level: rms, centroid: centroid, flux: normalisedFlux)
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
        return sqrt(sum / Float(high - low + 1))
    }
}
