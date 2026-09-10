import Foundation
import CoreAudio
import os

/// Estimates how long audio takes to reach the listener from the default output device, using
/// the public CoreAudio latency properties. Bluetooth headphones report large values; built-in
/// speakers report a few milliseconds. The estimate is clamped and only ever used to shift the
/// lyric lookup, never playback.
final class OutputLatencyMonitor: @unchecked Sendable {
    struct Reading: Equatable, Sendable {
        var latency: TimeInterval
        var deviceName: String
        static let none = Reading(latency: 0, deviceName: "")
    }

    static let maximumLatency: TimeInterval = 0.6

    private let lock = OSAllocatedUnfairLock(initialState: Reading.none)
    private let queue = DispatchQueue(label: "app.vela.outputlatency")
    private var listener: AudioObjectPropertyListenerBlock?
    var onChange: (@Sendable (Reading) -> Void)?

    var reading: Reading { lock.withLock { $0 } }

    init() {
        refresh()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refresh()
        }
        listener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
    }

    func refresh() {
        let fresh = Self.measure() ?? .none
        let changed = lock.withLock { current -> Bool in
            guard current != fresh else { return false }
            current = fresh
            return true
        }
        if changed { onChange?(fresh) }
    }

    /// Converts the device's reported frame latencies into seconds.
    static func seconds(deviceLatency: UInt32, safetyOffset: UInt32, bufferFrames: UInt32, streamLatency: UInt32, sampleRate: Double) -> TimeInterval {
        guard sampleRate > 0 else { return 0 }
        let frames = Double(deviceLatency) + Double(safetyOffset) + Double(bufferFrames) + Double(streamLatency)
        return min(maximumLatency, max(0, frames / sampleRate))
    }

    static func measure() -> Reading? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }

        func uint32(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput, of object: AudioObjectID = 0) -> UInt32 {
            var value: UInt32 = 0
            var valueSize = UInt32(MemoryLayout<UInt32>.size)
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            let target = object == 0 ? device : object
            return AudioObjectGetPropertyData(target, &addr, 0, nil, &valueSize, &value) == noErr ? value : 0
        }

        var rate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                     mScope: kAudioObjectPropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(device, &rateAddress, 0, nil, &rateSize, &rate)

        // First output stream's own latency, if any.
        var streamLatency: UInt32 = 0
        var streamsAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                        mScope: kAudioObjectPropertyScopeOutput,
                                                        mElement: kAudioObjectPropertyElementMain)
        var streamsSize: UInt32 = 0
        if AudioObjectGetPropertyDataSize(device, &streamsAddress, 0, nil, &streamsSize) == noErr, streamsSize >= UInt32(MemoryLayout<AudioStreamID>.size) {
            var streams = [AudioStreamID](repeating: 0, count: Int(streamsSize) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(device, &streamsAddress, 0, nil, &streamsSize, &streams) == noErr, let first = streams.first {
                streamLatency = uint32(kAudioStreamPropertyLatency, scope: kAudioObjectPropertyScopeGlobal, of: first)
            }
        }

        let latency = seconds(deviceLatency: uint32(kAudioDevicePropertyLatency),
                              safetyOffset: uint32(kAudioDevicePropertySafetyOffset),
                              bufferFrames: uint32(kAudioDevicePropertyBufferFrameSize),
                              streamLatency: streamLatency,
                              sampleRate: rate)

        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
        withUnsafeMutablePointer(to: &name) { pointer in
            _ = AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, pointer)
        }
        return Reading(latency: latency, deviceName: name as String)
    }
}

/// How the lyric lookup time is derived from the playback position.
enum LyricTiming {
    /// Highlights land a touch before the sound; this is what feels "in time" to a viewer.
    static let visualLead: TimeInterval = 0.09
    static let nudgeStep: TimeInterval = 0.1

    /// Total shift added to the playback position: user offset, the perceptual lead, minus the
    /// time the audio spends in the output pipeline (when compensation is on).
    static func shift(userOffset: TimeInterval, outputLatency: TimeInterval, compensate: Bool) -> TimeInterval {
        let latency = compensate ? min(OutputLatencyMonitor.maximumLatency, max(0, outputLatency)) : 0
        return userOffset + visualLead - latency
    }
}
