import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics

enum AudioCaptureStatus: Equatable, Sendable {
    case idle
    case notDetermined
    case denied
    case starting
    case capturing
    case failed(String)
}

/// Captures system audio (never the microphone) with ScreenCaptureKit and feeds the analyser.
///
/// A tiny 2×2 video stream is configured because ScreenCaptureKit requires a display filter;
/// its frames are discarded. All sample handling happens on a private queue.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let store: AudioLevelStore
    private let queue = DispatchQueue(label: "app.vela.audio", qos: .userInteractive)
    private var stream: SCStream?
    private var analyzer = SpectrumAnalyzer()
    private var ring: [Float] = []
    private var stopHandler: (@Sendable (String) -> Void)?

    init(store: AudioLevelStore) {
        self.store = store
        super.init()
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Prompts the user once; later calls return `false` without prompting if denied.
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    func start(onStop: @escaping @Sendable (String) -> Void) async throws {
        stopHandler = onStop
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw AudioCaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        configuration.showsCursor = false
        configuration.queueDepth = 4
        if #available(macOS 15.0, *) {
            configuration.captureMicrophone = false
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        store.markInactive()
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let description = sampleBuffer.formatDescription,
              let asbd = description.audioStreamBasicDescription else { return }
        let channels = Int(asbd.mChannelsPerFrame)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        guard isFloat else { return }

        try? sampleBuffer.withAudioBufferList { list, _ in
            let buffers = Array(list)
            guard let first = buffers.first, let base = first.mData else { return }
            let frames: Int
            if interleaved {
                frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * max(1, channels))
                let ptr = base.assumingMemoryBound(to: Float.self)
                ring.reserveCapacity(ring.count + frames)
                for frame in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += ptr[frame * channels + c] }
                    ring.append(sum / Float(channels))
                }
            } else {
                frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                var mono = [Float](repeating: 0, count: frames)
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    let ptr = data.assumingMemoryBound(to: Float.self)
                    for frame in 0..<frames { mono[frame] += ptr[frame] }
                }
                let divisor = Float(max(1, buffers.count))
                ring.append(contentsOf: mono.map { $0 / divisor })
            }
            drainRing()
        }
    }

    private func drainRing() {
        let size = analyzer.frameCount
        guard ring.count >= size else { return }
        // Keep the analyser on the freshest block; drop backlog to avoid latency build-up.
        if ring.count > size * 3 { ring.removeFirst(ring.count - size * 2) }
        let bands = ring.withUnsafeBufferPointer { ptr in
            analyzer.analyze(UnsafeBufferPointer(rebasing: ptr[(ring.count - size)...]))
        }
        ring.removeFirst(min(ring.count, size / 2))
        store.publish(bands)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        store.markInactive()
        stopHandler?(error.localizedDescription)
    }
}

enum AudioCaptureError: Error {
    case noDisplay
}
