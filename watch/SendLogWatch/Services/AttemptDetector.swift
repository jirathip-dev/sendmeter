import Foundation

/// Pure Swift boulder-attempt detector — no frameworks, unit-testable.
/// Fed 1 Hz MotionSamples fused from CMAltimeter + CMMotionManager + HR.
final class AttemptDetector {
    private enum Phase {
        case rest
        case climbing(startTick: Int, startDate: Date, baselineAtStart: Double, maxAlt: Double)
    }

    private let t: Tunables
    private var phase: Phase = .rest
    private var baseline: Double?
    private var ticks: [MotionSample] = []
    private var rawAttempts: [(startTick: Int, endTick: Int, startDate: Date, baselineAtStart: Double, maxAlt: Double)] = []
    private var workoutStart: Date?

    init(tunables: Tunables) {
        self.t = tunables
    }

    /// Live count for the workout UI (post-processing applied incrementally).
    var liveAttemptCount: Int {
        processedAttempts().count
    }

    func ingest(_ sample: MotionSample, at date: Date) {
        if workoutStart == nil { workoutStart = date }
        ticks.append(sample)
        let i = ticks.count - 1

        if baseline == nil { baseline = sample.altitude }

        switch phase {
        case .rest:
            // Baseline EMA updated only while resting: HVAC drift is absorbed,
            // climbing never drags it up.
            let dt = 1.0 / t.tickHz
            baseline! += (sample.altitude - baseline!) * (dt / t.baselineTauS)

            if shouldStartAttempt(at: i) {
                let startTick = riseStartTick(from: i)
                phase = .climbing(
                    startTick: startTick,
                    startDate: date.addingTimeInterval(-Double(i - startTick) / t.tickHz),
                    baselineAtStart: baseline!,
                    maxAlt: sample.altitude
                )
            }

        case .climbing(let startTick, let startDate, let baselineAtStart, var maxAlt):
            maxAlt = max(maxAlt, sample.altitude)
            phase = .climbing(startTick: startTick, startDate: startDate, baselineAtStart: baselineAtStart, maxAlt: maxAlt)

            let duration = Double(i - startTick) / t.tickHz
            if hasReturnedToGround(at: i, baseline: baselineAtStart)
                || hasGoneQuiet(at: i)
                || duration > t.maxAttemptS {
                rawAttempts.append((startTick, i, startDate, baselineAtStart, maxAlt))
                phase = .rest
            }
        }
    }

    func finalize() -> [Attempt] {
        // Flush an open attempt
        if case .climbing(let startTick, let startDate, let baselineAtStart, let maxAlt) = phase {
            rawAttempts.append((startTick, ticks.count - 1, startDate, baselineAtStart, maxAlt))
            phase = .rest
        }
        return processedAttempts()
    }

    // MARK: Post-processing

    private func processedAttempts() -> [Attempt] {
        var open = rawAttempts
        if case .climbing(let startTick, let startDate, let baselineAtStart, let maxAlt) = phase {
            open.append((startTick, ticks.count - 1, startDate, baselineAtStart, maxAlt))
        }
        guard !open.isEmpty else { return [] }

        // Merge attempts separated by < mergeGapS
        var merged: [(startTick: Int, endTick: Int, startDate: Date, baselineAtStart: Double, maxAlt: Double)] = []
        for a in open {
            if let last = merged.last,
               Double(a.startTick - last.endTick) / t.tickHz < t.mergeGapS {
                merged[merged.count - 1] = (
                    last.startTick, a.endTick, last.startDate,
                    min(last.baselineAtStart, a.baselineAtStart),
                    max(last.maxAlt, a.maxAlt)
                )
            } else {
                merged.append(a)
            }
        }

        return merged.compactMap { a in
            let duration = Double(a.endTick - a.startTick) / t.tickHz
            let gain = a.maxAlt - a.baselineAtStart
            guard duration >= t.minAttemptS, gain >= t.minGainM else { return nil }

            // HR window extended past the end to absorb sensor lag
            let hrEnd = min(ticks.count - 1, a.endTick + Int(t.hrLagS * t.tickHz))
            let hrs = ticks[a.startTick...hrEnd].compactMap(\.hr)
            let avgHR = hrs.isEmpty ? nil : hrs.reduce(0, +) / Double(hrs.count)
            let peakHR = hrs.max()

            let motions = ticks[a.startTick...a.endTick].map(\.motionRMS)
            let motionIntensity = motions.isEmpty ? 0 : motions.reduce(0, +) / Double(motions.count)

            return Attempt(
                startedAt: a.startDate,
                durationS: duration,
                elevationGainM: gain,
                avgHR: avgHR,
                peakHR: peakHR,
                motionIntensity: motionIntensity,
                effortScore: effortScore(durationS: duration, gainM: gain, peakHR: peakHR)
            )
        }
    }

    // MARK: Transition predicates

    private func shouldStartAttempt(at i: Int) -> Bool {
        guard let baseline else { return false }
        let sample = ticks[i]
        guard sample.altitude - baseline >= t.startGainM else { return false }
        // Rise must have happened within the trailing window
        let windowStart = max(0, i - Int(t.startWindowS * t.tickHz))
        guard let minInWindow = ticks[windowStart...i].map(\.altitude).min(),
              sample.altitude - minInWindow >= t.startGainM else { return false }
        // Motion gate: ≥ startMotionTicks of the last 5 above threshold
        let last5 = ticks[max(0, i - 4)...i]
        let active = last5.filter { $0.motionRMS >= t.startMotionG }.count
        return active >= t.startMotionTicks
    }

    private func riseStartTick(from i: Int) -> Int {
        let windowStart = max(0, i - Int(t.startWindowS * t.tickHz))
        var minTick = windowStart
        var minAlt = ticks[windowStart].altitude
        for j in windowStart...i where ticks[j].altitude < minAlt {
            minAlt = ticks[j].altitude
            minTick = j
        }
        return minTick
    }

    private func hasReturnedToGround(at i: Int, baseline: Double) -> Bool {
        let n = t.endReturnTicks
        guard i + 1 >= n else { return false }
        return ticks[(i - n + 1)...i].allSatisfy { $0.altitude <= baseline + t.endReturnM }
    }

    private func hasGoneQuiet(at i: Int) -> Bool {
        let n = t.quietTicks
        guard i + 1 >= n else { return false }
        return ticks[(i - n + 1)...i].allSatisfy { $0.motionRMS < t.quietMotionG }
    }

    // MARK: Effort & RPE math (v1 simple; replace with ML later)

    private func effortScore(durationS: Double, gainM: Double, peakHR: Double?) -> Double {
        let hrr = peakHR.map { max(0, min(1, ($0 - t.restHR) / (t.maxHR - t.restHR))) } ?? 0
        let raw = t.effortDurW * min(durationS / t.effortDurCapS, 1.5)
            + t.effortGainW * min(gainM / t.effortGainCapM, 1.5)
            + t.effortHRW * hrr
        return max(0, min(10, raw))
    }

    static func predictRPE(
        attempts: [Attempt],
        avgHR: Double?,
        durationS: Double,
        tunables t: Tunables
    ) -> Double {
        guard durationS > 0 else { return 5 }
        let sessionHRR = avgHR.map { max(0, min(1, ($0 - t.restHR) / (t.maxHR - t.restHR))) } ?? 0
        let meanEffort = attempts.isEmpty
            ? 0 : attempts.map(\.effortScore).reduce(0, +) / Double(attempts.count)
        let attemptsPer10m = Double(attempts.count) / (durationS / 600.0)
        let rpe = t.rpeBase
            + t.rpeHRRW * sessionHRR
            + t.rpeEffortW * meanEffort
            + t.rpeDensityW * attemptsPer10m
        return max(1, min(10, rpe))
    }
}
