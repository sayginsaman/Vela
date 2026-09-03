import Foundation

/// Turns a stream of `FrameDescriptor`s into a `MusicFeatureSnapshot`: normalised bands,
/// per-band transient impulses, onset detection, BPM by autocorrelation of the onset envelope,
/// beat-phase tracking, and the slow statistics the profile classifier needs.
///
/// Deterministic and allocation-free per frame; all history lives in fixed ring buffers.
/// Used unchanged by the live capture path, the demo fixtures and profile previews.
struct FeatureExtractor: Sendable {
    static let gridRate: Double = 50
    static let windowSeconds: Double = 6
    static let statsSeconds: Double = 4

    private let hop: Double
    private let capacity: Int
    private var envelope: [Float]
    private var levelHistory: [Float]
    private var head = 0
    private var filled = 0
    private var lastGridTime: Double?

    private var bassNorm = RunningNormalizer()
    private var midNorm = RunningNormalizer()
    private var highNorm = RunningNormalizer()
    /// Loudness adapts slowly so quiet passages actually read as quiet (dynamic range, loudness).
    private var levelNorm = RunningNormalizer(decay: 0.9995)

    private var bandSmooth: (bass: AttackReleaseSmoother, mid: AttackReleaseSmoother, high: AttackReleaseSmoother, level: AttackReleaseSmoother)
    private var lowImpulse = Impulse(decayRate: 9)
    private var midImpulse = Impulse(decayRate: 10)
    private var highImpulse = Impulse(decayRate: 14)
    private var onsetImpulse = Impulse(decayRate: 8)
    private var beatImpulse = Impulse(decayRate: 7)
    private var prevBass: Float = 0, prevMid: Float = 0, prevHigh: Float = 0

    private var fluxMean: Float = 0.05
    private var fluxSlow: Float = 0.05
    private var lastRawFlux: Float = 0
    private var prevRawFlux: Float = 0
    private var envMean: Float = 1
    private var envVar: Float = 0.2
    private var lastEnv: Float = 0
    private var lastLastEnv: Float = 0
    private var lastOnsetTime: Double = -10
    private var onsetTimes: [Double]
    private var onsetPeaks: [Float]
    private var onsetHead = 0
    private var onsetCount = 0

    private var bpmHistory: [Float] = []
    private var lastAutocorrTime: Double = -10
    private var autocorrBuffer: [Float]
    private var correlation: [Float]
    private var lastBeatTime: Double?
    private var previousPhase: Float = 0

    private var bassRawMean: Float = 0.01
    private var midRawMean: Float = 0.01
    private var highRawMean: Float = 0.01
    private var centroidMean: Float = 0.5
    private var lastTime: Double?

    private(set) var snapshot = MusicFeatureSnapshot.silent

    init(gridRate: Double = FeatureExtractor.gridRate) {
        hop = 1 / gridRate
        capacity = Int(gridRate * Self.windowSeconds)
        envelope = [Float](repeating: 0, count: capacity)
        levelHistory = [Float](repeating: 0, count: capacity)
        autocorrBuffer = [Float](repeating: 0, count: capacity)
        correlation = [Float](repeating: 0, count: capacity / 2 + 1)
        onsetTimes = [Double](repeating: -10, count: 64)
        onsetPeaks = [Float](repeating: 0, count: 64)
        bandSmooth = (AttackReleaseSmoother(attack: 0.03, release: 0.18),
                      AttackReleaseSmoother(attack: 0.04, release: 0.2),
                      AttackReleaseSmoother(attack: 0.02, release: 0.14),
                      AttackReleaseSmoother(attack: 0.05, release: 0.25))
    }

    /// Forgets rhythm history (call on track change). Gain normalisation is kept.
    mutating func reset() {
        head = 0; filled = 0; lastGridTime = nil
        for i in envelope.indices { envelope[i] = 0; levelHistory[i] = 0 }
        onsetHead = 0; onsetCount = 0; lastOnsetTime = -10
        bpmHistory.removeAll(keepingCapacity: true)
        lastAutocorrTime = -10
        lastBeatTime = nil
        previousPhase = 0
        lastEnv = 0; lastLastEnv = 0
        lastRawFlux = 0; prevRawFlux = 0
        lowImpulse.value = 0; midImpulse.value = 0; highImpulse.value = 0; onsetImpulse.value = 0; beatImpulse.value = 0
        snapshot = .silent
        lastTime = nil
    }

    mutating func ingest(_ frame: FrameDescriptor) -> MusicFeatureSnapshot {
        let dt = lastTime.map { max(0, frame.time - $0) } ?? hop
        lastTime = frame.time

        // Normalised, smoothed bands.
        let bass = bassNorm.normalize(frame.bass)
        let mid = midNorm.normalize(frame.mid)
        let high = highNorm.normalize(frame.high)
        let level = levelNorm.normalize(frame.level)
        bandSmooth.bass.update(Double(bass), dt: dt)
        bandSmooth.mid.update(Double(mid), dt: dt)
        bandSmooth.high.update(Double(high), dt: dt)
        bandSmooth.level.update(Double(level), dt: dt)

        // Per-band transients (kick / snare / hat proxies).
        let fdt = Float(dt)
        lowImpulse.advance(dt: fdt); midImpulse.advance(dt: fdt); highImpulse.advance(dt: fdt)
        onsetImpulse.advance(dt: fdt); beatImpulse.advance(dt: fdt)
        lowImpulse.hit(Self.transient(bass, previous: prevBass, threshold: 0.12, scale: 0.35))
        midImpulse.hit(Self.transient(mid, previous: prevMid, threshold: 0.12, scale: 0.35))
        highImpulse.hit(Self.transient(high, previous: prevHigh, threshold: 0.1, scale: 0.3))
        prevBass = bass; prevMid = mid; prevHigh = high

        // Onset envelope: flux relative to its running mean.
        fluxMean += (frame.flux - fluxMean) * 0.01
        fluxSlow += (frame.flux - fluxSlow) * 0.02
        let env = frame.flux / max(fluxMean, 1e-5)
        envMean += (env - envMean) * 0.02
        envVar += ((env - envMean) * (env - envMean) - envVar) * 0.02
        let threshold = max(1.15, envMean + 1.0 * sqrt(max(envVar, 1e-4)))
        var onsetStrength: Float = 0
        // Local peak test uses the previous frame as the candidate.
        if lastEnv > threshold, lastEnv >= env, lastEnv >= lastLastEnv, frame.time - lastOnsetTime >= 0.09 {
            onsetStrength = min(1, (lastEnv - envMean) / max(threshold - envMean, 1e-3) * 0.5)
            registerOnset(at: frame.time - dt, peak: lastRawFlux)
        }
        lastLastEnv = lastEnv
        lastEnv = env
        prevRawFlux = lastRawFlux
        lastRawFlux = frame.flux
        if onsetStrength > 0 { onsetImpulse.hit(onsetStrength) }

        // Fixed-rate grid for autocorrelation and statistics.
        pushGrid(time: frame.time, env: env, level: Float(bandSmooth.level.value))

        // Slow statistics.
        bassRawMean += (frame.bass - bassRawMean) * 0.02
        midRawMean += (frame.mid - midRawMean) * 0.02
        highRawMean += (frame.high - highRawMean) * 0.02
        centroidMean += (frame.centroid - centroidMean) * 0.03

        if frame.time - lastAutocorrTime >= 0.5, filled >= capacity / 2 {
            lastAutocorrTime = frame.time
            estimateTempo()
        }
        updateBeatPhase(at: frame.time)

        // Assemble.
        var s = snapshot
        s.time = frame.time
        s.bands = AudioBands(bass: Float(bandSmooth.bass.value), mid: Float(bandSmooth.mid.value),
                             high: Float(bandSmooth.high.value), level: Float(bandSmooth.level.value))
        s.onsetImpulse = onsetImpulse.value
        s.beatImpulse = beatImpulse.value
        s.lowImpulse = lowImpulse.value
        s.midImpulse = midImpulse.value
        s.highImpulse = highImpulse.value
        s.bassToMid = Self.ratioToUnit(bassRawMean / max(midRawMean, 1e-5))
        s.highEnergy = min(1, highRawMean / max(bassRawMean + midRawMean + highRawMean, 1e-5) * 2.5)
        s.spectralCentroid = centroidMean
        s.spectralFlux = min(1, fluxSlow * 2.5)
        s.onsetDensity = onsetDensity(at: frame.time)
        s.transientStrength = transientStrength(at: frame.time)
        let (range, loudness) = levelStatistics()
        s.dynamicRange = range
        s.averageLoudness = loudness
        snapshot = s
        return s
    }

    // MARK: Pieces

    private static func transient(_ value: Float, previous: Float, threshold: Float, scale: Float) -> Float {
        let rise = value - previous
        guard rise > threshold else { return 0 }
        return min(1, (rise - threshold) / scale + 0.25)
    }

    /// Maps a bass/mid energy ratio onto 0…1 with 0.5 meaning balanced.
    static func ratioToUnit(_ ratio: Float) -> Float {
        let l = log2(max(ratio, 1e-4))
        return min(1, max(0, 0.5 + l / 5))
    }

    private mutating func registerOnset(at time: Double, peak: Float) {
        lastOnsetTime = time
        onsetTimes[onsetHead] = time
        onsetPeaks[onsetHead] = peak
        onsetHead = (onsetHead + 1) % onsetTimes.count
        onsetCount = min(onsetCount + 1, onsetTimes.count)
        // Beat-phase correction: snap to the predicted beat when the onset is close to it.
        guard snapshot.bpmConfidence > 0.3, snapshot.bpm > 0 else {
            if lastBeatTime == nil { lastBeatTime = time }
            return
        }
        let period = 60 / Double(snapshot.bpm)
        guard let anchor = lastBeatTime else { lastBeatTime = time; return }
        let beats = ((time - anchor) / period).rounded()
        let predicted = anchor + beats * period
        let error = time - predicted
        if abs(error) < period * 0.2 {
            lastBeatTime = predicted + error * 0.5
        }
    }

    private mutating func pushGrid(time: Double, env: Float, level: Float) {
        guard let last = lastGridTime else {
            lastGridTime = time
            write(env: env, level: level)
            return
        }
        var slots = Int(((time - last) / hop).rounded(.down))
        guard slots > 0 else { return }
        if slots > capacity { slots = capacity }
        for _ in 0..<slots { write(env: env, level: level) }
        lastGridTime = last + Double(slots) * hop
    }

    private mutating func write(env: Float, level: Float) {
        envelope[head] = env
        levelHistory[head] = level
        head = (head + 1) % capacity
        filled = min(filled + 1, capacity)
    }

    private mutating func estimateTempo() {
        // Copy history in chronological order and remove the mean.
        let n = filled
        var mean: Float = 0
        for i in 0..<n {
            let idx = (head - n + i + capacity) % capacity
            autocorrBuffer[i] = envelope[idx]
            mean += envelope[idx]
        }
        mean /= Float(max(1, n))
        var energy: Float = 0
        for i in 0..<n { autocorrBuffer[i] -= mean; energy += autocorrBuffer[i] * autocorrBuffer[i] }
        guard energy > 1e-6 else { setTempo(bpm: 0, confidence: 0, regularity: 0); return }

        let rate = Float(1 / hop)
        let lagMin = max(2, Int(rate * 60 / 185))
        let lagMax = min(n / 2, Int(rate * 60 / 58))
        let maxLag = min(correlation.count - 1, n - 20)
        guard lagMax > lagMin, maxLag > lagMax else { return }
        // Normalised autocorrelation for every lag we might need (including harmonics).
        for lag in 0...maxLag {
            var acc: Float = 0
            var i = 0
            while i + lag < n { acc += autocorrBuffer[i] * autocorrBuffer[i + lag]; i += 1 }
            correlation[lag] = acc / energy
        }
        // Beat evidence: a beat lag also correlates at two and four beats. A mild prior around
        // 118 BPM breaks octave ties the way a listener would tap.
        var bestLag = lagMin
        var bestScore: Float = -10
        var sum: Float = 0
        for lag in lagMin...lagMax {
            var evidence = correlation[lag]
            if lag * 2 <= maxLag { evidence += 0.5 * correlation[lag * 2] }
            if lag * 4 <= maxLag { evidence += 0.25 * correlation[lag * 4] }
            let bpm = rate * 60 / Float(lag)
            let prior = 0.7 + 0.3 * exp(-pow((bpm - 118) / 40, 2))
            let score = evidence * prior
            sum += correlation[lag]
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        let bestR = correlation[bestLag]
        let meanR = sum / Float(max(1, lagMax - lagMin + 1))
        let bpm = rate * 60 / Float(bestLag)
        let peakiness = min(1, max(0, (bestR - meanR) * 2.5))
        let regularity = 0.5 * min(1, max(0, bestR)) + 0.5 * intervalRegularity()
        let confidence = min(1, peakiness * (0.6 + 0.4 * regularity))
        setTempo(bpm: bpm, confidence: confidence, regularity: regularity)
    }

    private mutating func setTempo(bpm: Float, confidence: Float, regularity: Float) {
        if bpm > 0 {
            bpmHistory.append(bpm)
            if bpmHistory.count > 5 { bpmHistory.removeFirst() }
        }
        let median = bpmHistory.sorted()[safe: bpmHistory.count / 2] ?? 0
        snapshot.bpm = median
        snapshot.bpmConfidence += (confidence - snapshot.bpmConfidence) * 0.35
        snapshot.rhythmicRegularity += (regularity - snapshot.rhythmicRegularity) * 0.35
    }

    /// 1 − coefficient of variation of recent inter-onset intervals, clamped.
    private func intervalRegularity() -> Float {
        guard onsetCount >= 4 else { return 0 }
        var intervals: [Double] = []
        intervals.reserveCapacity(onsetCount)
        var previous: Double?
        for k in 0..<onsetCount {
            let idx = (onsetHead - onsetCount + k + onsetTimes.count) % onsetTimes.count
            let t = onsetTimes[idx]
            if let previous, t > previous { intervals.append(t - previous) }
            previous = t
        }
        guard intervals.count >= 3 else { return 0 }
        // Fold intervals to the same octave so 8ths and quarters count as regular.
        let base = intervals.sorted()[intervals.count / 2]
        let folded = intervals.map { i -> Double in
            var v = i
            while v > base * 1.5 { v /= 2 }
            while v < base * 0.75 { v *= 2 }
            return v
        }
        let mean = folded.reduce(0, +) / Double(folded.count)
        let variance = folded.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(folded.count)
        let cv = sqrt(variance) / max(mean, 1e-3)
        return Float(min(1, max(0, 1 - cv * 2)))
    }

    private mutating func updateBeatPhase(at time: Double) {
        guard snapshot.bpm > 0, let anchor = lastBeatTime else { snapshot.beatPhase = 0; return }
        let period = 60 / Double(snapshot.bpm)
        var phase = ((time - anchor) / period).truncatingRemainder(dividingBy: 1)
        if phase < 0 { phase += 1 }
        let p = Float(phase)
        if p < previousPhase - 0.5, snapshot.bpmConfidence >= 0.4 {
            beatImpulse.hit(0.6 + 0.4 * snapshot.bpmConfidence)
        }
        previousPhase = p
        snapshot.beatPhase = p
    }

    private func onsetDensity(at time: Double) -> Float {
        var count = 0
        for k in 0..<onsetCount {
            let idx = (onsetHead - onsetCount + k + onsetTimes.count) % onsetTimes.count
            if time - onsetTimes[idx] <= Self.statsSeconds { count += 1 }
        }
        return Float(count) / Float(Self.statsSeconds)
    }

    private func transientStrength(at time: Double) -> Float {
        var sum: Float = 0
        var count = 0
        for k in 0..<onsetCount {
            let idx = (onsetHead - onsetCount + k + onsetTimes.count) % onsetTimes.count
            if time - onsetTimes[idx] <= Self.statsSeconds { sum += onsetPeaks[idx]; count += 1 }
        }
        guard count > 0 else { return 0 }
        let meanPeak = sum / Float(count)     // raw flux at onsets: how hard the attacks are
        return min(1, max(0, meanPeak * 1.5))
    }

    /// (dynamic range, average loudness) over the statistics window, both 0…1.
    private func levelStatistics() -> (Float, Float) {
        let n = filled
        guard n >= 8 else { return (0, 0) }
        var values: [Float] = []
        values.reserveCapacity(n)
        var sum: Float = 0
        for i in 0..<n {
            let idx = (head - n + i + capacity) % capacity
            values.append(levelHistory[idx]); sum += levelHistory[idx]
        }
        values.sort()
        let low = values[Int(Float(n - 1) * 0.1)]
        let high = values[Int(Float(n - 1) * 0.9)]
        return (min(1, max(0, (high - low) * 1.6)), sum / Float(n))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
