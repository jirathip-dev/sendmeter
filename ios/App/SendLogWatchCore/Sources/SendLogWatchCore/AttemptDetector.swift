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
        /// #473 F-A: a manual attempt's own stillness-based close, requiring
        /// no HR corroboration — see the `isManual && quiet` branch below.
        case manualQuietFallback
        case unestablishedCap
        case establishedDriftCap
        case hardCap

        public var isCap: Bool {
            switch self {
            case .returnedToFloor, .hrQuietFallback, .manualQuietFallback: return false
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
        establishedDriftMaxS: Double,
        isManual: Bool
    ) -> EndReason? {
        if durationS > maxDurationS { return .hardCap }
        if establishedAltitudeAscent {
            if returnedToFloor { return .returnedToFloor }
            // #473 R1: `unestablishedMaxS`/`establishedDriftMaxS` exist to
            // bound a MIS-detection — an auto attempt the detector opened on
            // a signal that turned out not to be a real close-ended climb.
            // A manual (Boulder-button) attempt is by definition not a
            // mis-detection: the user is telling the detector this IS a real
            // attempt, so it stays on the shipped `maxAttemptS` bound (300s)
            // instead of being cut off mid-traverse on a stopwatch — see the
            // R1 review finding (a 61-90s truncation is exactly the "button
            // doesn't match reality" complaint this issue exists to fix,
            // from the other side, and RELEASE_NOTES directs flat/HR-only
            // traverses to this exact button).
            if !isManual && durationS > establishedDriftMaxS { return .establishedDriftCap }
            return nil
        }
        if hasHRSupport && quiet { return .hrQuietFallback }
        // #473 F-A (cross-wave sweep, composed with #477): #477 nils
        // `sample.hr` after a HealthKit gap (no fresh sample within
        // `hrStaleAfterS`), and R1 correctly exempted `.manual` from the
        // duration caps. Composed, a FLAT manual attempt with no HR from its
        // first tick had `hasHRSupport` false for its entire life, so
        // `hrQuietFallback` above could never fire — its only remaining exit
        // was `maxAttemptS` (300s), reintroducing #473's own symptom (a
        // multi-minute banked attempt) through a different door, on exactly
        // the workflow RELEASE_NOTES now tells users to use for a flat
        // traverse. A manual attempt is explicitly opened by the user, so
        // sustained stillness alone (`quiet`, no HR corroboration required)
        // is an unambiguous "I'm done" signal — unlike an UNDETECTED auto
        // phantom, there's no false-positive-open to protect against here.
        // This is a genuine end signal, not a duration bound: it does NOT
        // reintroduce a cap (R1's constraint) — `durationS` plays no role,
        // only the same trailing-quiet-ticks trigger `hrQuietFallback` uses.
        if isManual && quiet { return .manualQuietFallback }
        // #473: a floor-level attempt that never establishes altitude and
        // never gets HR+quiet support (e.g. HR unavailable) used to fall
        // through all the way to maxDurationS. Bound it separately — but
        // only for auto (see the R1 comment above `establishedDriftCap`).
        // NOTE: currently unreachable for `.auto` too — every auto-opened
        // attempt is established from its very first tick, because
        // `startAltitudeSupportM` (0.45m) already exceeds
        // `establishedAltitudeGainM` (0.4m), and HR-only auto opening was
        // retired in F1. Kept (not deleted) as a defensive bound in case the
        // confidence formula changes again — see the AttemptDetector-level
        // comment on `unestablishedMaxS` in Tunables.swift.
        if !isManual && durationS > unestablishedMaxS { return .unestablishedCap }
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
            if let reason = AttemptEndResolver.endReason(
                establishedAltitudeAscent: maxAlt - baselineAtStart >= t.establishedAltitudeGainM,
                returnedToFloor: hasReturnedToGround(at: i, baseline: baselineAtStart),
                hasHRSupport: hasHRSupport(from: startTick, through: i),
                quiet: hasGoneQuiet(at: i),
                durationS: duration,
                maxDurationS: t.maxAttemptS,
                unestablishedMaxS: t.unestablishedMaxS,
                establishedDriftMaxS: t.establishedDriftMaxS,
                isManual: false
            ) {
                rawAttempts.append(RawAttempt(
                    startTick: startTick, endTick: i, startDate: startDate,
                    baselineAtStart: baselineAtStart, maxAlt: maxAlt, source: .auto,
                    explicitlyEnded: false, hitCap: reason.isCap
                ))
                phase = .rest
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
                   establishedDriftMaxS: t.establishedDriftMaxS,
                   isManual: true
               ) {
                rawAttempts.append(RawAttempt(
                    startTick: startTick, endTick: i, startDate: startDate,
                    baselineAtStart: baselineAtStart, maxAlt: maxAlt, source: .manual,
                    explicitlyEnded: false, hitCap: reason.isCap
                ))
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
                    // an explicit close (AND, not OR). See
                    // testExplicitFragmentMergedWithPhantomLosesExemption for
                    // the case this guards. The residual this buys: an
                    // explicitly-stopped fragment merged with a LATER
                    // non-explicit auto open (< mergeGapS away) also loses
                    // the exemption in the other direction — a real Stop can
                    // end up filtered if what follows it doesn't independently
                    // pass minAttemptS/minActiveMotionTicks. Narrower and
                    // safer than the leak AND prevents: it only bites a
                    // rapid, borderline re-open right after a Stop, not an
                    // ordinary session. `hitCap` is diagnostic only (not a
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
        // #473: HR contributes at most +1 (was +1 for this AND +1 more past
        // the old startStrongHRRiseBPM, so a decaying post-climb HR alone
        // could reach startConfidenceRequired with zero altitude evidence —
        // the phantom re-open). A sustained-motion second point was tried to
        // restore HR-only (flat, zero-altitude) "traverse" detection and
        // reverted: measured against a walking probe (60s at 0.10g, HR +15,
        // flat altitude — ordinary walking between boulders with HR still
        // elevated), it opened an attempt shipped code correctly rejected,
        // because sustained motion at gym walking cadence is not
        // distinguishable from sustained motion at traverse cadence with
        // this sensor set. HR-only traverse detection is retired; log one
        // with the Boulder/Stop button instead.
        if let hr = sample.hr, let restingHR, hr - restingHR >= t.startHRRiseBPM { confidence += 1 }
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
