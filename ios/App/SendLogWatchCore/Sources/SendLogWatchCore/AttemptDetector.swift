import Foundation

/// Pure end-state policy shared by automatic and assisted-manual attempts.
/// An established altitude ascent closes on return regardless of floor-level
/// motion; an HR-only attempt has no return signal, so quiet is its fallback.
public enum AttemptEndResolver {
    public static func shouldEnd(
        establishedAltitudeAscent: Bool,
        returnedToFloor: Bool,
        hasHRSupport: Bool,
        quiet: Bool,
        durationS: Double,
        maxDurationS: Double
    ) -> Bool {
        if durationS > maxDurationS { return true }
        if establishedAltitudeAscent { return returnedToFloor }
        return hasHRSupport && quiet
    }
}

/// Pure Swift boulder-attempt detector — no frameworks, unit-testable.
/// Fed 1 Hz MotionSamples fused from CMAltimeter + CMMotionManager + HR.
public final class AttemptDetector {
    private enum Phase {
        case rest
        case climbing(startTick: Int, startDate: Date, baselineAtStart: Double, maxAlt: Double)
        // A manually-logged boulder (Boulder/Stop button). Auto detection is
        // suspended while one is open, so manual and auto never overlap.
        case manual(startTick: Int, startDate: Date, baselineAtStart: Double, maxAlt: Double)
    }

    private typealias RawAttempt = (
        startTick: Int, endTick: Int, startDate: Date,
        baselineAtStart: Double, maxAlt: Double, source: AttemptSource
    )

    private let t: Tunables
    private var phase: Phase = .rest
    private var baseline: Double?
    private var restingAltitudes: [(tick: Int, altitude: Double)] = []
    private var restingHR: Double?
    private var ticks: [MotionSample] = []
    private var rawAttempts: [RawAttempt] = []
    private var workoutStart: Date?

    public init(tunables: Tunables) {
        self.t = tunables
    }

    /// Live count for the workout UI (post-processing applied incrementally).
    public var liveAttemptCount: Int {
        processedAttempts().count
    }

    /// True only for a manual boulder. Visible UI state should use `snapshot`.
    public var isManualAttemptOpen: Bool {
        if case .manual = phase { return true }
        return false
    }

    public var snapshot: AttemptDetectorSnapshot {
        switch phase {
        case .rest:
            return AttemptDetectorSnapshot(state: .resting, phaseStartedAt: nil, localHeightM: 0)
        case .climbing(_, let date, let floor, let maxAlt):
            return AttemptDetectorSnapshot(
                state: .autoClimbing, phaseStartedAt: date,
                localHeightM: max(0, (ticks.last?.altitude ?? maxAlt) - floor)
            )
        case .manual(_, let date, let floor, let maxAlt):
            return AttemptDetectorSnapshot(
                state: .manualClimbing, phaseStartedAt: date,
                localHeightM: max(0, (ticks.last?.altitude ?? maxAlt) - floor)
            )
        }
    }

    public var totalElevationGainM: Double {
        processedAttempts().reduce(0) { $0 + max(0, $1.elevationGainM) }
    }

    public func ingest(_ sample: MotionSample, at date: Date) {
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
            restingAltitudes.append((i, sample.altitude))
            let oldest = i - Int(t.localFloorWindowS * t.tickHz)
            restingAltitudes.removeAll { $0.tick < oldest }
            if let hr = sample.hr {
                restingHR = restingHR.map { $0 + (hr - $0) * (dt / t.baselineTauS) } ?? hr
            }

            if shouldStartAttempt(at: i) {
                let startTick = riseStartTick(from: i)
                let floor = localFloor(at: i) ?? baseline!
                phase = .climbing(
                    startTick: startTick,
                    startDate: date.addingTimeInterval(-Double(i - startTick) / t.tickHz),
                    baselineAtStart: floor,
                    maxAlt: sample.altitude
                )
            }

        case .climbing(let startTick, let startDate, let baselineAtStart, var maxAlt):
            maxAlt = max(maxAlt, sample.altitude)
            phase = .climbing(startTick: startTick, startDate: startDate, baselineAtStart: baselineAtStart, maxAlt: maxAlt)

            let duration = Double(i - startTick) / t.tickHz
            if AttemptEndResolver.shouldEnd(
                establishedAltitudeAscent: maxAlt - baselineAtStart >= t.establishedAltitudeGainM,
                returnedToFloor: hasReturnedToGround(at: i, baseline: baselineAtStart),
                hasHRSupport: hasHRSupport(from: startTick, through: i),
                quiet: hasGoneQuiet(at: i),
                durationS: duration,
                maxDurationS: t.maxAttemptS
            ) {
                rawAttempts.append((startTick, i, startDate, baselineAtStart, maxAlt, .auto))
                phase = .rest
            }

        case .manual(let startTick, let startDate, let baselineAtStart, var maxAlt):
            maxAlt = max(maxAlt, sample.altitude)
            phase = .manual(startTick: startTick, startDate: startDate, baselineAtStart: baselineAtStart, maxAlt: maxAlt)
            let duration = Double(i - startTick) / t.tickHz
            if duration >= t.assistedManualMinS,
               AttemptEndResolver.shouldEnd(
                   establishedAltitudeAscent: maxAlt - baselineAtStart >= t.establishedAltitudeGainM,
                   returnedToFloor: hasReturnedToGround(at: i, baseline: baselineAtStart),
                   hasHRSupport: hasHRSupport(from: startTick, through: i),
                   quiet: hasGoneQuiet(at: i),
                   durationS: duration,
                   maxDurationS: t.maxAttemptS
               ) {
                rawAttempts.append((startTick, i, startDate, baselineAtStart, maxAlt, .manual))
                phase = .rest
            }
        }
    }

    /// Open a manual boulder attempt. Suspends auto detection; if an auto
    /// attempt was already open it's closed and kept first (no overlap).
    public func beginManualAttempt(at date: Date) {
        if case .manual = phase { return }
        if workoutStart == nil { workoutStart = date }
        if case .climbing(let s, let sd, let b, let m) = phase {
            rawAttempts.append((s, max(s, ticks.count - 1), sd, b, m, .auto))
        }
        let i = max(0, ticks.count - 1)
        let base = localFloor(at: i) ?? baseline ?? ticks.last?.altitude ?? 0
        let alt = ticks.last?.altitude ?? base
        phase = .manual(startTick: i, startDate: date, baselineAtStart: base, maxAlt: alt)
    }

    /// Close the open manual attempt (Stop). No-op if none is open.
    public func endManualAttempt(at date: Date) {
        guard case .manual(let s, let sd, let b, let m) = phase else { return }
        guard !ticks.isEmpty else {
            phase = .rest
            return
        }
        rawAttempts.append((s, ticks.count - 1, sd, b, m, .manual))
        phase = .rest
    }

    /// Close whichever attempt is visible. Its original provenance is kept.
    /// Repeated calls while resting are a no-op.
    public func endCurrentAttempt(at date: Date) {
        switch phase {
        case .climbing(let s, let sd, let b, let m):
            rawAttempts.append((s, max(s, ticks.count - 1), sd, b, m, .auto))
            phase = .rest
        case .manual:
            endManualAttempt(at: date)
        case .rest:
            break
        }
    }

    public func finalize() -> [Attempt] {
        // Flush an open attempt (auto or manual)
        switch phase {
        case .climbing(let s, let sd, let b, let m):
            rawAttempts.append((s, ticks.count - 1, sd, b, m, .auto))
        case .manual(let s, let sd, let b, let m):
            if !ticks.isEmpty {
                rawAttempts.append((s, ticks.count - 1, sd, b, m, .manual))
            }
        case .rest:
            break
        }
        phase = .rest
        return processedAttempts()
    }

    // MARK: Post-processing

    private func processedAttempts() -> [Attempt] {
        guard !ticks.isEmpty else { return [] }
        var open = rawAttempts
        switch phase {
        case .climbing(let s, let sd, let b, let m):
            open.append((s, ticks.count - 1, sd, b, m, .auto))
        case .manual(let s, let sd, let b, let m):
            open.append((s, ticks.count - 1, sd, b, m, .manual))
        case .rest:
            break
        }
        guard !open.isEmpty else { return [] }

        // Merge attempts separated by < mergeGapS. Only same-source, adjacent
        // attempts merge — a manual attempt never absorbs an auto one (auto is
        // suspended during manual, so they can't actually be adjacent, but the
        // guard keeps the sources honest).
        var merged: [RawAttempt] = []
        for a in open {
            if let last = merged.last,
               last.source == a.source,
               Double(a.startTick - last.endTick) / t.tickHz < t.mergeGapS {
                merged[merged.count - 1] = (
                    last.startTick, a.endTick, last.startDate,
                    min(last.baselineAtStart, a.baselineAtStart),
                    max(last.maxAlt, a.maxAlt),
                    last.source
                )
            } else {
                merged.append(a)
            }
        }

        return merged.compactMap { a in
            let duration = Double(a.endTick - a.startTick) / t.tickHz
            // #475: the DB's `climb_attempts.duration_s > 0` check rejects a
            // zero-duration attempt outright, and a rejected upload poisons
            // the offline queue (nothing about it is retryable). A same-tick
            // Begin/End on manual — or a manual phase flushed by finalize()
            // with no elapsed ticks — reaches here with `duration == 0`, and
            // manual attempts are otherwise exempt from every other filter
            // below. Enforce the invariant once, unconditionally, at this
            // single emit boundary — every emission path (manual stop,
            // current stop, finalize() flush, assisted auto-close) funnels
            // through it, so a call-site guard can't be bypassed by a path
            // nobody thought to add one to.
            guard duration > 0 else { return nil }
            let gain = max(0, a.maxAlt - a.baselineAtStart)
            // Manual attempts are exempt from the auto duration/motion filters
            // because the user explicitly logged them (e.g. a traverse).
            if a.source == .auto {
                guard duration >= t.minAttemptS else { return nil }
                let activeTicks = ticks[a.startTick...a.endTick]
                    .filter { $0.motionRMS >= t.startMotionG }.count
                guard activeTicks >= t.minActiveMotionTicks else { return nil }
            }

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
                effortScore: effortScore(durationS: duration, gainM: gain, peakHR: peakHR),
                source: a.source
            )
        }
    }

    // MARK: Transition predicates

    private func shouldStartAttempt(at i: Int) -> Bool {
        let sample = ticks[i]
        let motionStart = max(0, i - Int(t.startMotionWindowS * t.tickHz) + 1)
        let active = ticks[motionStart...i].filter { $0.motionRMS >= t.startMotionG }.count
        guard active >= t.startMotionTicks else { return false }

        guard let floor = localFloor(at: i) else { return false }
        let gain = sample.altitude - floor
        var confidence = 0
        if gain >= t.startAltitudeSupportM { confidence += 1 }
        if gain >= t.startStrongAltitudeM { confidence += 1 }
        if let hr = sample.hr, let restingHR, hr - restingHR >= t.startHRRiseBPM { confidence += 1 }
        if let hr = sample.hr, let restingHR, hr - restingHR >= t.startStrongHRRiseBPM { confidence += 1 }
        return confidence >= t.startConfidenceRequired
    }

    private func localFloor(at i: Int) -> Double? {
        let oldest = i - Int(t.localFloorWindowS * t.tickHz)
        return restingAltitudes.lazy.filter { $0.tick >= oldest }.map(\.altitude).min()
    }

    private func riseStartTick(from i: Int) -> Int {
        let windowStart = max(0, i - Int(t.startWindowS * t.tickHz))
        var minTick = windowStart
        var minAlt = ticks[windowStart].altitude
        // <= keeps the LAST tick at the minimum: flat rest before the rise
        // must not count toward attempt duration
        for j in windowStart...i where ticks[j].altitude <= minAlt {
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

    private func hasHRSupport(from start: Int, through end: Int) -> Bool {
        guard let restingHR,
              let peak = ticks[start...end].compactMap(\.hr).max() else { return false }
        return peak - restingHR >= t.startHRRiseBPM
    }

    // MARK: Effort & RPE math (v1 simple; replace with ML later)

    private func effortScore(durationS: Double, gainM: Double, peakHR: Double?) -> Double {
        let hrr = peakHR.map { max(0, min(1, ($0 - t.restHR) / (t.maxHR - t.restHR))) } ?? 0
        let raw = t.effortDurW * min(durationS / t.effortDurCapS, 1.5)
            + t.effortGainW * min(gainM / t.effortGainCapM, 1.5)
            + t.effortHRW * hrr
        return max(0, min(10, raw))
    }

    public static func predictRPE(
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
