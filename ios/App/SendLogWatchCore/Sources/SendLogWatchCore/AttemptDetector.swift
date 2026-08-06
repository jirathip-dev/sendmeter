import Foundation

/// Pure end-state policy shared by automatic and assisted-manual attempts.
/// An established altitude ascent closes on return regardless of floor-level
/// motion; an HR-only attempt has no return signal, so quiet is its fallback.
public enum AttemptEndResolver {
    /// Why an attempt closed. The three `*Cap` cases are a duration bound
    /// firing rather than a genuine end signal — #473: hitting one always
    /// means detection was wrong about something, so callers can report it
    /// instead of it reading as an ordinary close.
    public enum EndReason: Equatable, Sendable {
        case returnedToFloor
        case hrQuietFallback
        case unestablishedCap
        case establishedDriftCap
        case hardCap

        public var isCap: Bool {
            switch self {
            case .returnedToFloor, .hrQuietFallback: return false
            case .unestablishedCap, .establishedDriftCap, .hardCap: return true
            }
        }
    }

    public static func endReason(
        establishedAltitudeAscent: Bool,
        returnedToFloor: Bool,
        hasHRSupport: Bool,
        quiet: Bool,
        durationS: Double,
        maxDurationS: Double,
        unestablishedMaxS: Double,
        establishedDriftMaxS: Double
    ) -> EndReason? {
        if durationS > maxDurationS { return .hardCap }
        if establishedAltitudeAscent {
            if returnedToFloor { return .returnedToFloor }
            // #473: real barometric drift over a long hold means the climber
            // can genuinely be back on the ground without ever reading within
            // endReturnM of the stale startline. Quiet motion for this long
            // while established is only explained by that, not by a mid-climb
            // rest (those are bounded well under establishedDriftMaxS).
            if quiet && durationS > establishedDriftMaxS { return .establishedDriftCap }
            return nil
        }
        if hasHRSupport && quiet { return .hrQuietFallback }
        // #473: a floor-level attempt that never establishes altitude and
        // never gets HR+quiet support (e.g. HR unavailable) used to fall
        // through all the way to maxDurationS. Bound it separately.
        if durationS > unestablishedMaxS { return .unestablishedCap }
        return nil
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

    private struct RawAttempt {
        var startTick: Int
        var endTick: Int
        var startDate: Date
        var baselineAtStart: Double
        var maxAlt: Double
        var source: AttemptSource
        /// #473: set only by an explicit user Stop (endCurrentAttempt /
        /// endManualAttempt), independent of `source` — an auto-detected
        /// attempt the user explicitly stopped is still `source == .auto`
        /// but must skip the auto post-filters below. Never set by an
        /// automatic close, an assisted-manual close, or a finalize() flush.
        var explicitlyEnded: Bool
        /// #473: this fragment closed via one of AttemptEndResolver's cap
        /// reasons rather than a genuine end signal.
        var hitCap: Bool
    }

    private let t: Tunables
    private var phase: Phase = .rest
    private var baseline: Double?
    private var restingAltitudes: [(tick: Int, altitude: Double)] = []
    private var restingHR: Double?
    private var ticks: [MotionSample] = []
    private var rawAttempts: [RawAttempt] = []
    private var workoutStart: Date?
    /// #473: after ANY attempt closes, auto detection stays disarmed until
    /// the trailing motion window it just closed on has fully cleared (no
    /// active ticks), so residual walk-off motion can't qualify a new auto
    /// start on the very next tick. `beginManualAttempt` never consults this
    /// — manual Play always bypasses it.
    private var disarmed = false

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

            // #473: re-arm only once the trailing motion window this tick
            // would gate on is fully quiet — walk-off motion right after a
            // close keeps auto disarmed no matter how confident the score.
            if disarmed {
                if activeMotionTicks(at: i, windowS: t.startMotionWindowS) == 0 {
                    disarmed = false
                }
            }

            if !disarmed, shouldStartAttempt(at: i) {
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
            if let reason = AttemptEndResolver.endReason(
                establishedAltitudeAscent: maxAlt - baselineAtStart >= t.establishedAltitudeGainM,
                returnedToFloor: hasReturnedToGround(at: i, baseline: baselineAtStart),
                hasHRSupport: hasHRSupport(from: startTick, through: i),
                quiet: hasGoneQuiet(at: i),
                durationS: duration,
                maxDurationS: t.maxAttemptS,
                unestablishedMaxS: t.unestablishedMaxS,
                establishedDriftMaxS: t.establishedDriftMaxS
            ) {
                rawAttempts.append(RawAttempt(
                    startTick: startTick, endTick: i, startDate: startDate,
                    baselineAtStart: baselineAtStart, maxAlt: maxAlt, source: .auto,
                    explicitlyEnded: false, hitCap: reason.isCap
                ))
                phase = .rest
                disarmed = true
            }

        case .manual(let startTick, let startDate, let baselineAtStart, var maxAlt):
            maxAlt = max(maxAlt, sample.altitude)
            phase = .manual(startTick: startTick, startDate: startDate, baselineAtStart: baselineAtStart, maxAlt: maxAlt)
            let duration = Double(i - startTick) / t.tickHz
            if duration >= t.assistedManualMinS,
               let reason = AttemptEndResolver.endReason(
                   establishedAltitudeAscent: maxAlt - baselineAtStart >= t.establishedAltitudeGainM,
                   returnedToFloor: hasReturnedToGround(at: i, baseline: baselineAtStart),
                   hasHRSupport: hasHRSupport(from: startTick, through: i),
                   quiet: hasGoneQuiet(at: i),
                   durationS: duration,
                   maxDurationS: t.maxAttemptS,
                   unestablishedMaxS: t.unestablishedMaxS,
                   establishedDriftMaxS: t.establishedDriftMaxS
               ) {
                rawAttempts.append(RawAttempt(
                    startTick: startTick, endTick: i, startDate: startDate,
                    baselineAtStart: baselineAtStart, maxAlt: maxAlt, source: .manual,
                    explicitlyEnded: false, hitCap: reason.isCap
                ))
                phase = .rest
                disarmed = true
            }
        }
    }

    /// Open a manual boulder attempt. Suspends auto detection; if an auto
    /// attempt was already open it's closed and kept first (no overlap).
    public func beginManualAttempt(at date: Date) {
        if case .manual = phase { return }
        if workoutStart == nil { workoutStart = date }
        // #473: Play always bypasses the post-close motion disarm — a dead
        // Stop button must not be traded for a dead Play button.
        disarmed = false
        if case .climbing(let s, let sd, let b, let m) = phase {
            rawAttempts.append(RawAttempt(
                startTick: s, endTick: max(s, ticks.count - 1), startDate: sd,
                baselineAtStart: b, maxAlt: m, source: .auto,
                explicitlyEnded: false, hitCap: false
            ))
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
        rawAttempts.append(RawAttempt(
            startTick: s, endTick: ticks.count - 1, startDate: sd,
            baselineAtStart: b, maxAlt: m, source: .manual,
            explicitlyEnded: true, hitCap: false
        ))
        phase = .rest
        disarmed = true
    }

    /// Close whichever attempt is visible. Its original provenance is kept.
    /// Repeated calls while resting are a no-op.
    public func endCurrentAttempt(at date: Date) {
        switch phase {
        case .climbing(let s, let sd, let b, let m):
            rawAttempts.append(RawAttempt(
                startTick: s, endTick: max(s, ticks.count - 1), startDate: sd,
                baselineAtStart: b, maxAlt: m, source: .auto,
                explicitlyEnded: true, hitCap: false
            ))
            phase = .rest
            disarmed = true
        case .manual:
            endManualAttempt(at: date)
        case .rest:
            break
        }
    }

    public func finalize() -> [Attempt] {
        // Flush an open attempt (auto or manual) — ending the workout
        // without ever tapping Stop, so this is not an explicit close.
        switch phase {
        case .climbing(let s, let sd, let b, let m):
            rawAttempts.append(RawAttempt(
                startTick: s, endTick: ticks.count - 1, startDate: sd,
                baselineAtStart: b, maxAlt: m, source: .auto,
                explicitlyEnded: false, hitCap: false
            ))
        case .manual(let s, let sd, let b, let m):
            if !ticks.isEmpty {
                rawAttempts.append(RawAttempt(
                    startTick: s, endTick: ticks.count - 1, startDate: sd,
                    baselineAtStart: b, maxAlt: m, source: .manual,
                    explicitlyEnded: false, hitCap: false
                ))
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
            open.append(RawAttempt(
                startTick: s, endTick: ticks.count - 1, startDate: sd,
                baselineAtStart: b, maxAlt: m, source: .auto,
                explicitlyEnded: false, hitCap: false
            ))
        case .manual(let s, let sd, let b, let m):
            open.append(RawAttempt(
                startTick: s, endTick: ticks.count - 1, startDate: sd,
                baselineAtStart: b, maxAlt: m, source: .manual,
                explicitlyEnded: false, hitCap: false
            ))
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
                merged[merged.count - 1] = RawAttempt(
                    startTick: last.startTick, endTick: a.endTick, startDate: last.startDate,
                    baselineAtStart: min(last.baselineAtStart, a.baselineAtStart),
                    maxAlt: max(last.maxAlt, a.maxAlt),
                    source: last.source,
                    // #473: a confirmed short fragment must not exempt a
                    // merged phantom spanning minutes — only carry the
                    // exemption through if EVERY merged fragment was itself
                    // an explicit close. `hitCap` is diagnostic only (not a
                    // filter gate), so it just reflects how the merged
                    // attempt's final fragment ended.
                    explicitlyEnded: last.explicitlyEnded && a.explicitlyEnded,
                    hitCap: a.hitCap
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
            // #473: so is an auto attempt the user explicitly stopped — Stop
            // must always record, not fall through the same filters that
            // exist to catch UNDETECTED phantoms.
            if a.source == .auto && !a.explicitlyEnded {
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
                source: a.source,
                hitCap: a.hitCap
            )
        }
    }

    // MARK: Transition predicates

    private func shouldStartAttempt(at i: Int) -> Bool {
        let sample = ticks[i]
        // Hard candidate gate: motion must be active recently, full stop.
        guard activeMotionTicks(at: i, windowS: t.startMotionWindowS) >= t.startMotionTicks else { return false }

        guard let floor = localFloor(at: i) else { return false }
        let gain = sample.altitude - floor
        var confidence = 0
        if gain >= t.startAltitudeSupportM { confidence += 1 }
        if gain >= t.startStrongAltitudeM { confidence += 1 }
        // #473: HR contributes at most +1 — see Tunables.startHRRiseBPM.
        if let hr = sample.hr, let restingHR, hr - restingHR >= t.startHRRiseBPM {
            confidence += 1
            // #473: sustained motion is a second point ONLY alongside a real
            // HR rise — this is specifically the zero-altitude traverse's own
            // two-point combo (restores what capping HR alone deletes), not
            // a freestanding candidate. Pairing it with the (much weaker)
            // altitude-support point instead would let ordinary
            // walking-around-the-gym motion plus a borderline altitude blip
            // fake the same total — see testWalkingNoiseRejected, which
            // regressed under that version of this change.
            if activeMotionTicks(at: i, windowS: t.startMotionSustainedWindowS) >= t.startMotionSustainedTicks {
                confidence += 1
            }
        }
        return confidence >= t.startConfidenceRequired
    }

    /// Count of ticks with `motionRMS >= startMotionG` in the trailing
    /// `windowS` seconds ending at (and including) tick `i`.
    private func activeMotionTicks(at i: Int, windowS: Double) -> Int {
        let start = max(0, i - Int(windowS * t.tickHz) + 1)
        return ticks[start...i].filter { $0.motionRMS >= t.startMotionG }.count
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
