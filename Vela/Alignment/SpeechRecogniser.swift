import Foundation
import Speech
import AVFoundation

/// Anything that can turn audio into timed words. Vela uses Apple's on-device recogniser, but the
/// aligner only needs `HeardWord`s, so a stronger engine can be dropped in behind this later.
protocol SpeechRecognising: AnyObject, Sendable {
    /// Receives the words heard so far, in song time, repeatedly, as the recogniser refines what
    /// it thinks it heard. Called on an arbitrary queue.
    func setWordsHandler(_ handler: @escaping @Sendable ([HeardWord]) -> Void)
    /// Begins a session. `songTime` anchors recogniser timestamps to the song's own timeline.
    func begin(at songTime: TimeInterval) throws
    /// Forgets everything heard so far, for a new track.
    func reset()
    func append(samples: [Float], sampleRate: Double)
    func end()
}

enum SpeechRecogniserError: Error, Equatable {
    case unavailable
    case notAuthorised
    case onDeviceUnavailable
}

/// On-device speech recognition through Apple's Speech framework.
///
/// Recognising sung words over a backing track is genuinely hard, and much of what comes back is
/// wrong. That is expected: `WordAligner` only needs the words it *does* get right, as timing
/// anchors against lyrics we already have.
///
/// Sessions are restarted periodically because a recognition task is not meant to run forever;
/// each restart re-anchors to the current song position.
final class AppleSpeechRecogniser: NSObject, SpeechRecognising, @unchecked Sendable {
    static let maximumSessionDuration: TimeInterval = 45

    private var onWords: (@Sendable ([HeardWord]) -> Void)?

    private let recogniser: SFSpeechRecognizer?
    private let queue = DispatchQueue(label: "app.vela.speech")
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var format: AVAudioFormat?
    private var anchor: TimeInterval = 0
    private var sessionStarted = Date.distantPast
    private var accumulated: [HeardWord] = []

    static var authorisationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    static func requestAuthorisation() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    func setWordsHandler(_ handler: @escaping @Sendable ([HeardWord]) -> Void) {
        queue.sync { onWords = handler }
    }

    override init() {
        recogniser = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer()
        super.init()
    }

    var isUsable: Bool {
        guard let recogniser, recogniser.isAvailable else { return false }
        return recogniser.supportsOnDeviceRecognition
    }

    func begin(at songTime: TimeInterval) throws {
        guard let recogniser, recogniser.isAvailable else { throw SpeechRecogniserError.unavailable }
        guard Self.authorisationStatus == .authorized else { throw SpeechRecogniserError.notAuthorised }
        guard recogniser.supportsOnDeviceRecognition else { throw SpeechRecogniserError.onDeviceUnavailable }
        queue.sync { startSession(at: songTime) }
    }

    func append(samples: [Float], sampleRate: Double) {
        queue.async { [weak self] in
            guard let self, let request = self.request else { return }
            if Date().timeIntervalSince(self.sessionStarted) > Self.maximumSessionDuration {
                // Roll over to a fresh task, anchored where this one left off.
                let nextAnchor = self.anchor + Date().timeIntervalSince(self.sessionStarted)
                self.stopSession()
                self.startSession(at: nextAnchor)
            }
            guard let buffer = self.buffer(from: samples, sampleRate: sampleRate) else { return }
            (self.request ?? request).append(buffer)
        }
    }

    func end() {
        queue.sync { stopSession() }
    }

    func reset() {
        queue.sync {
            stopSession()
            accumulated.removeAll()
        }
    }

    // MARK: Session

    private func startSession(at songTime: TimeInterval) {
        anchor = songTime
        sessionStarted = Date()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        if #available(macOS 13.0, *) { request.addsPunctuation = false }
        self.request = request
        let sessionAnchor = songTime
        task = recogniser?.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            let words = result.bestTranscription.segments.compactMap { segment -> HeardWord? in
                let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return HeardWord(text: text,
                                 start: sessionAnchor + segment.timestamp,
                                 end: sessionAnchor + segment.timestamp + segment.duration,
                                 confidence: Double(segment.confidence))
            }
            self.publish(words, anchor: sessionAnchor)
        }
    }

    private func stopSession() {
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    /// Replaces this session's words and republishes everything heard so far, so a later partial
    /// result never loses what an earlier session established.
    private func publish(_ words: [HeardWord], anchor: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            self.accumulated.removeAll { $0.start >= anchor - 0.001 }
            self.accumulated.append(contentsOf: words)
            self.accumulated.sort { $0.start < $1.start }
            let snapshot = self.accumulated
            self.onWords?(snapshot)
        }
    }

    private func buffer(from samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        if format == nil || format?.sampleRate != sampleRate {
            format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        }
        guard let format, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }
}
