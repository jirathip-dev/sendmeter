import Foundation

public extension Date {
    /// Epoch milliseconds — the time unit of the persisted routine-run clock.
    var millisecondsSince1970: Int64 {
        Int64((timeIntervalSince1970 * 1_000).rounded())
    }
}

/// Wall-clock state of an in-progress guided routine, persisted so a
/// killed/backgrounded app can resume the run on relaunch (#633). Mirrors
/// the web's `sendmeter:routine-run` record (src/lib/routineRun.ts): the
/// timer is wall-clock-derived, so persisting these fields is enough to
/// resume exactly where it left off — the clock keeps ticking against
/// `startedMs`. The JSON shape uses the web's key names on purpose so the
/// two implementations' records are byte-comparable.
public struct PersistedRoutineRun: Codable, Equatable, Sendable {
    public let presetID: UUID
    /// Epoch ms of the run start (a restored run keeps its original start).
    public let startedMs: Int64
    /// Whole seconds fast-forwarded by Skip presses — adds to the position
    /// (`elapsedS`) but never to the real time worked (`realElapsedS`).
    public let skippedS: Int
    /// Epoch ms when Pause was hit, or nil while running.
    public let pausedAtMs: Int64?
    /// Accumulated paused time (ms) across prior pause/resume cycles.
    public let pausedTotalMs: Int64
    /// Epoch ms of the last time the runner confirmed it was actually
    /// on-screen and ticking — a heartbeat throttled to ~`RoutineGate
    /// .heartbeatMs`. This is the one field that tells "present until (near)
    /// the end, then killed" apart from "abandoned minutes ago" — wall-clock
    /// elapsed alone reads identically for both (#483's F1/F5 class).
    public let lastSeenMs: Int64

    public init(
        presetID: UUID,
        startedMs: Int64,
        skippedS: Int,
        pausedAtMs: Int64?,
        pausedTotalMs: Int64,
        lastSeenMs: Int64
    ) {
        self.presetID = presetID
        self.startedMs = startedMs
        self.skippedS = skippedS
        self.pausedAtMs = pausedAtMs
        self.pausedTotalMs = pausedTotalMs
        self.lastSeenMs = lastSeenMs
    }

    public var isPaused: Bool { pausedAtMs != nil }

    private enum CodingKeys: String, CodingKey {
        case presetID = "presetId"
        case startedMs
        case skippedS
        case pausedAtMs
        case pausedTotalMs
        case lastSeenMs
    }

    /// A fresh heartbeat — the run was confirmed on-screen and ticking at
    /// `atMs`.
    public func heartbeat(atMs: Int64) -> PersistedRoutineRun {
        PersistedRoutineRun(
            presetID: presetID,
            startedMs: startedMs,
            skippedS: skippedS,
            pausedAtMs: pausedAtMs,
            pausedTotalMs: pausedTotalMs,
            lastSeenMs: atMs
        )
    }

    /// Pause pressed at `atMs` — the clock freezes here until resume. Like
    /// the web, only the heartbeat advances `lastSeenMs`; a structural
    /// change leaves it untouched.
    public func paused(atMs: Int64) -> PersistedRoutineRun {
        guard !isPaused else { return self }
        return PersistedRoutineRun(
            presetID: presetID,
            startedMs: startedMs,
            skippedS: skippedS,
            pausedAtMs: atMs,
            pausedTotalMs: pausedTotalMs,
            lastSeenMs: lastSeenMs
        )
    }

    /// Resume pressed at `atMs` — fold the just-finished pause into
    /// `pausedTotalMs` and unfreeze.
    public func resumed(atMs: Int64) -> PersistedRoutineRun {
        guard let pausedAtMs else { return self }
        return PersistedRoutineRun(
            presetID: presetID,
            startedMs: startedMs,
            skippedS: skippedS,
            pausedAtMs: nil,
            pausedTotalMs: pausedTotalMs + max(0, atMs - pausedAtMs),
            lastSeenMs: lastSeenMs
        )
    }

    /// Skip fast-forwards the routine's position by `seconds`.
    public func skipped(_ seconds: Int, atMs: Int64) -> PersistedRoutineRun {
        PersistedRoutineRun(
            presetID: presetID,
            startedMs: startedMs,
            skippedS: skippedS + max(0, seconds),
            pausedAtMs: pausedAtMs,
            pausedTotalMs: pausedTotalMs,
            lastSeenMs: lastSeenMs
        )
    }
}

/// Pure routine-completion-gate and resume/stale math (#633) — the native
/// mirror of the web's `src/lib/routineRun.ts`, kept to its exact semantics
/// so the two apps classify a run identically.
public enum RoutineGate {
    /// How often the runner stamps a fresh `lastSeenMs` heartbeat while
    /// genuinely ticking (ms) — the web's HEARTBEAT_MS.
    public static let heartbeatMs: Int64 = 5_000
    /// How stale a run's `lastSeenMs` can be (seconds) before wall-clock-
    /// since-start is no longer trusted as "still in progress" — the web's
    /// STALE_GAP_S. Generous relative to `heartbeatMs` (6x) to tolerate a
    /// couple of missed ticks, short enough to catch a genuinely suspended
    /// app promptly.
    public static let staleGapS: Double = 30
    /// How close a "confirmed" elapsed has to be to the routine's own total
    /// to count as completed rather than partial — the web's
    /// PRESENCE_MARGIN_S.
    public static let presenceMarginS: Double = 10
    /// A run is worth logging as a (partial) session only past a minute —
    /// briefer runs are accidental opens and are discarded. The web's
    /// `shouldLog` bar.
    public static let minLogSeconds: Double = 60

    /// Elapsed routine seconds — a *position in the routine's timeline*
    /// (drives resume gating), identical formula to the web's `elapsedS`.
    /// Includes `skippedS`; for the duration to log see `realElapsedS`.
    public static func elapsedS(_ run: PersistedRoutineRun, nowMs: Int64) -> Double {
        Double((run.pausedAtMs ?? nowMs) - run.startedMs - run.pausedTotalMs) / 1_000
            + Double(run.skippedS)
    }

    /// Real seconds actually spent on the routine — same as `elapsedS` but
    /// WITHOUT skipped-segment credit (the web's `realElapsedS`). Skip can
    /// fast-forward position to "done" sooner, but a logged duration must
    /// reflect real time worked.
    public static func realElapsedS(_ run: PersistedRoutineRun, nowMs: Int64) -> Double {
        Double((run.pausedAtMs ?? nowMs) - run.startedMs - run.pausedTotalMs) / 1_000
    }

    /// A run is worth logging as a (partial) session only past a minute —
    /// briefer runs are accidental opens and are discarded.
    public static func shouldLog(_ elapsedSeconds: Double) -> Bool {
        elapsedSeconds >= minLogSeconds
    }

    /// Whole minutes for the logged session, clamped to the `sessions` table's
    /// `duration_min` check (1..600). NaN fails every comparison, so it
    /// slips through min/max unclamped — the web's #483 F6 guard: any
    /// non-finite input must still land inside 1..600.
    public static func partialMinutes(_ elapsedSeconds: Double) -> Int {
        if elapsedSeconds.isNaN { return 1 }
        guard elapsedSeconds.isFinite else {
            return elapsedSeconds > 0 ? 600 : 1
        }
        return min(600, max(1, Int((elapsedSeconds / 60).rounded())))
    }

    /// Minutes to log for a completed routine, capped at what the routine
    /// could actually have taken (`totalSeconds`) rather than raw wall clock
    /// — wall-clock elapsed can run far past the routine's total (a resumed-
    /// then-abandoned run) and must not be logged as-is.
    public static func loggedMinutes(_ elapsedSeconds: Double, totalSeconds: Int) -> Int {
        partialMinutes(min(elapsedSeconds, Double(totalSeconds)))
    }

    /// A persisted run whose wall-clock elapsed already meets or exceeds its
    /// own total duration was not "in progress" when it was left, as far as
    /// wall clock alone can tell. Reads `elapsedS` (resolves a paused run to
    /// its frozen elapsed), so a genuinely paused run is never "abandoned"
    /// as long as its frozen elapsed is still under total. Necessary but not
    /// sufficient on its own — `resolveRoutineResume` combines it with the
    /// `lastSeenMs` heartbeat.
    public static func isAbandoned(
        _ run: PersistedRoutineRun,
        totalSeconds: Int,
        nowMs: Int64
    ) -> Bool {
        elapsedS(run, nowMs: nowMs) >= Double(totalSeconds)
    }

    /// Outcome of classifying a *confirmed* elapsed value against the
    /// routine's total: close enough to the total counts as completed; short
    /// of it but still worth logging (the ≥60s bar) is a partial; anything
    /// less is discarded. The caller MUST surface a "discarded" outcome
    /// visibly — never silently.
    public enum RoutineLogOutcome: Equatable, Sendable {
        case completed(durationMin: Int)
        case partial(durationMin: Int)
        case discarded
    }

    public static func classifyElapsed(
        seenElapsed: Double,
        totalSeconds: Int
    ) -> RoutineLogOutcome {
        if seenElapsed >= Double(totalSeconds) - presenceMarginS {
            return .completed(durationMin: loggedMinutes(seenElapsed, totalSeconds: totalSeconds))
        }
        if shouldLog(seenElapsed) {
            return .partial(durationMin: partialMinutes(seenElapsed))
        }
        return .discarded
    }

    /// The Log Routine & Close decision (#633). Unlike `classifyElapsed`
    /// (which trusts a "confirmed" elapsed against a routine total), this is
    /// a hard gate: a run under a minute is an accidental open and is
    /// discarded (visibly by the caller), regardless of how the routine's
    /// position got there; at or past a minute it logs a partial session with
    /// the honest real elapsed — min 1 minute, capped at the routine's staged
    /// total, never the full nominal total.
    public enum RoutineCompletionOutcome: Equatable, Sendable {
        case logged(durationMin: Int)
        case discarded
    }

    public static func completionOutcome(
        elapsedSeconds: Double,
        totalSeconds: Int
    ) -> RoutineCompletionOutcome {
        guard shouldLog(elapsedSeconds) else { return .discarded }
        return .logged(durationMin: loggedMinutes(elapsedSeconds, totalSeconds: totalSeconds))
    }

    /// What a persisted run should do on launch: auto-resume, log as
    /// completed/partial, or be discarded — never silently (the caller must
    /// surface a discarded outcome). Mirrors the web's `resolveRoutineResume`
    /// exactly. The caller resolves a missing preset itself (returns `none`).
    /// A paused run is frozen and fully trusted regardless of staleness —
    /// pause is explicit and deliberate. A running run is only trusted while
    /// its heartbeat is recent; past that, or once wall clock says it has run
    /// past its own total, the decision falls back to `classifyElapsed` on
    /// what the heartbeat actually confirmed — never raw wall clock across an
    /// unobserved gap.
    public enum RoutineResumeOutcome: Equatable, Sendable {
        case none
        case resume
        case logged(RoutineLogOutcome)
    }

    public static func resolveRoutineResume(
        run: PersistedRoutineRun?,
        totalSeconds: Int,
        nowMs: Int64
    ) -> RoutineResumeOutcome {
        guard let run else { return .none }
        if run.isPaused {
            guard !isAbandoned(run, totalSeconds: totalSeconds, nowMs: nowMs) else {
                return .logged(classifyElapsed(
                    seenElapsed: realElapsedS(run, nowMs: nowMs),
                    totalSeconds: totalSeconds
                ))
            }
            return .resume
        }
        let gapS = Double(nowMs - run.lastSeenMs) / 1_000
        if gapS <= staleGapS && !isAbandoned(run, totalSeconds: totalSeconds, nowMs: nowMs) {
            return .resume
        }
        return .logged(classifyElapsed(
            seenElapsed: realElapsedS(run, nowMs: run.lastSeenMs),
            totalSeconds: totalSeconds
        ))
    }
}

/// UserDefaults-backed persistence for the in-progress routine run — the
/// native mirror of the web's `localStorage` `sendmeter:routine-run` key
/// (`saveRoutineRun` / `loadRoutineRun` / `clearRoutineRun`), under the
/// `sendmeter.native.*` key namespace. Best-effort by contract: a storage
/// failure is swallowed, never thrown into the run loop.
public struct RoutineRunStore {
    private static let key = "sendmeter.native.routine-run"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> PersistedRoutineRun? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(PersistedRoutineRun.self, from: data)
    }

    public func save(_ run: PersistedRoutineRun) {
        guard let data = try? JSONEncoder().encode(run) else { return }
        defaults.set(data, forKey: Self.key)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
