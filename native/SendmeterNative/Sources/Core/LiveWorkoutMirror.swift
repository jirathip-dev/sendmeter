import Foundation

// MARK: - Live workout mirror (native port of the web's src/lib/liveWorkoutMirror.ts)

/// The transport that delivered the last accepted packet. `watch-direct` is
/// the low-latency WatchConnectivity fast path; `server-fallback` is the
/// durable Supabase row (initial fetch + realtime). Both feeds reduce through
/// the same run/sequence cursor, so a reconnect or a late packet can never
/// roll the mirror back.
public enum LiveWorkoutMirrorSource: String, Equatable, Sendable {
    case watchDirect = "watch-direct"
    case serverFallback = "server-fallback"
}

/// Honest transport state for the live workout card. `watch-direct` and
/// `server-fallback` name the transport of the last accepted message;
/// `temporarily-unreachable` means neither path has delivered anything fresh
/// for `LiveWorkoutMirrorConstants.directQuietSeconds`; `unknown` covers
/// "no live row / ended / nothing known yet". Unknown must never be
/// presented as healthy.
public enum LiveWorkoutSyncState: String, Equatable, Sendable {
    case watchDirect = "watch-direct"
    case serverFallback = "server-fallback"
    case temporarilyUnreachable = "temporarily-unreachable"
    case unknown
}

public enum LiveWorkoutMirrorConstants {
    /// How long a heartbeat may go quiet before the workout is presumed dead
    /// (watch upserts every ~5s; 30s of silence = app killed / walked away).
    public static let staleSeconds: TimeInterval = 30

    /// How long the row may go quiet (by the phone's own clock since the last
    /// ACCEPTED packet — see `LiveWorkoutMirrorState.lastAcceptedAtMs`) before
    /// the phone stops claiming a working link. Even if the last accepted
    /// message came over WatchConnectivity, beyond this the card must say the
    /// link is paused, not live. ~2 workout heartbeat intervals. Phone-local,
    /// so device clock skew cannot trip it.
    public static let directQuietSeconds: TimeInterval = 10
}

/// The mirror cursor: the accepted row plus the phone-local receipt time.
/// Duplicate/out-of-order packets and late live packets after End never reach
/// this state (see `reduceLiveWorkoutMirror`).
public struct LiveWorkoutMirrorState: Equatable, Sendable {
    public var row: LiveWorkout?
    public var source: LiveWorkoutMirrorSource
    /// Phone-local wall-clock ms when the last packet was ACCEPTED into this
    /// cursor. Quiet-state derivation compares against this (same clock),
    /// never against `row.updatedAt` (a watch/DB clock) — comparing a phone
    /// clock to a device clock makes a watch lagging >10s read
    /// "temporarily unreachable" forever.
    public var lastAcceptedAtMs: TimeInterval

    public init(
        row: LiveWorkout?,
        source: LiveWorkoutMirrorSource,
        lastAcceptedAtMs: TimeInterval
    ) {
        self.row = row
        self.source = source
        self.lastAcceptedAtMs = lastAcceptedAtMs
    }

    /// Empty cursor for a freshly signed-in account. AppModel resets to this
    /// before subscribing to the next user's channel so an older account's
    /// high sequence can never reject the new account's first (possibly
    /// older) run.
    public static let empty = LiveWorkoutMirrorState(
        row: nil,
        source: .serverFallback,
        lastAcceptedAtMs: 0
    )
}

/// Returns whether `incoming` can replace `previous`. Run freshness is judged
/// BEFORE terminal dominance (#614 review F11 order, kept from the web): a
/// packet from an older run arriving after a terminal row reads as stale
/// rather than being accepted then blocked by the terminal row.
public func liveWorkoutMirrorAccepts(previous: LiveWorkout?, incoming: LiveWorkout) -> Bool {
    guard let previous else { return true }
    if !isFreshRun(previous: previous, incoming: incoming) { return false }
    if previous.runID != incoming.runID { return true }
    if previous.terminal { return false }
    if incoming.terminal { return true }

    if let previousSequence = previous.sequence, let incomingSequence = incoming.sequence {
        return incomingSequence > previousSequence
    }
    // Mixed-version fallback (one side lacks a sequence).
    return incoming.updatedAt >= previous.updatedAt
}

private func isFreshRun(previous: LiveWorkout, incoming: LiveWorkout) -> Bool {
    if previous.runID == incoming.runID { return true }
    // UUIDs are opaque. The start timestamp is the only safe mixed-version
    // ordering signal for an old run arriving after a new run. Equal starts
    // are treated as current to preserve a just-created run during the
    // fetch/WC race; the run/sequence cursor then handles all subsequent
    // packets.
    return incoming.startedAt >= previous.startedAt
}

public struct LiveWorkoutMirrorReduceResult: Equatable, Sendable {
    public let state: LiveWorkoutMirrorState
    public let accepted: Bool
}

/// Reducer used by AppModel for BOTH producers (WC beat and realtime row).
/// `nowMs` (phone wall clock) stamps the state's `lastAcceptedAtMs` so
/// quiet-state derivation is clock-skew-free.
public func reduceLiveWorkoutMirror(
    state: LiveWorkoutMirrorState,
    incoming: LiveWorkout,
    source: LiveWorkoutMirrorSource,
    nowMs: TimeInterval
) -> LiveWorkoutMirrorReduceResult {
    guard liveWorkoutMirrorAccepts(previous: state.row, incoming: incoming) else {
        return LiveWorkoutMirrorReduceResult(state: state, accepted: false)
    }
    return LiveWorkoutMirrorReduceResult(
        state: LiveWorkoutMirrorState(
            row: incoming,
            source: source,
            lastAcceptedAtMs: nowMs
        ),
        accepted: true
    )
}

// MARK: - Wire parsers

/// WatchConnectivity beat → `LiveWorkout`. Epoch-seconds timestamps, `run_id`
/// optional for pre-#521 watch builds — a stable legacy identity is derived
/// from `started_at` so old-build beats join the same run instead of looking
/// like a fresh one on every packet.
public func liveWorkoutFromWCMessage(
    message: [String: Any],
    previous: LiveWorkout?
) -> LiveWorkout? {
    guard let status = message["status"] as? String,
          let updated = epochSeconds(message["updated_at"])
    else { return nil }
    let rawStartedAt = epochSeconds(message["started_at"])
    let startedAt = rawStartedAt.map(Date.init(timeIntervalSince1970:))
        ?? previous?.startedAt
        ?? Date(timeIntervalSince1970: updated)
    let terminal = bool(message["terminal"]) ?? (status == "ended")
    let runID: UUID
    if let stamped = uuid(message["run_id"]) {
        runID = stamped
    } else if let raw = rawStartedAt {
        runID = legacyRunID(from: Date(timeIntervalSince1970: raw))
    } else if let previous {
        runID = previous.runID
    } else {
        runID = UUID()
    }
    return LiveWorkout(
        workoutID: uuid(message["workout_id"]) ?? previous?.workoutID ?? runID,
        runID: runID,
        sequence: int(message["sequence"]),
        event: message["event"] as? String ?? "telemetry",
        terminal: terminal,
        status: status,
        startedAt: startedAt,
        heartRate: double(message["hr"]),
        attemptCount: int(message["attempt_count"]) ?? 0,
        activeKilocalories: double(message["active_kcal"]),
        elevationGainMeters: double(message["elevation_gain_m"]),
        climbing: bool(message["climbing"]) ?? false,
        climbingSince: epochSeconds(message["climbing_since"]).map(Date.init(timeIntervalSince1970:)),
        restStartedAt: epochSeconds(message["rest_started_at"]).map(Date.init(timeIntervalSince1970:)),
        restTargetSeconds: int(message["rest_target_s"]),
        updatedAt: Date(timeIntervalSince1970: updated),
        userID: uuid(message["account_user_id"])
    )
}

/// Supabase `live_workouts` row (realtime record or initial fetch) →
/// `LiveWorkout`. ISO-8601 timestamps, always carries the durable identity.
public func liveWorkoutFromRow(record: [String: Any]) -> LiveWorkout? {
    guard let status = record["status"] as? String,
          let workoutID = uuid(record["workout_id"]),
          let startedAt = isoDate(record["started_at"]),
          let updatedAt = isoDate(record["updated_at"])
    else { return nil }
    let runID = uuid(record["run_id"]) ?? workoutID
    let terminal = bool(record["terminal"]) ?? (status == "ended")
    return LiveWorkout(
        workoutID: workoutID,
        runID: runID,
        sequence: int(record["sequence"]),
        event: record["event"] as? String ?? "telemetry",
        terminal: terminal,
        status: status,
        startedAt: startedAt,
        heartRate: double(record["hr"]),
        attemptCount: int(record["attempt_count"]) ?? 0,
        activeKilocalories: double(record["active_kcal"]),
        elevationGainMeters: double(record["elevation_gain_m"]),
        climbing: bool(record["climbing"]) ?? false,
        climbingSince: isoDate(record["climbing_since"]),
        restStartedAt: isoDate(record["rest_started_at"]),
        restTargetSeconds: int(record["rest_target_s"]),
        updatedAt: updatedAt,
        userID: uuid(record["user_id"])
    )
}

/// The ownership decision behind AppModel's mirror admission guards (#626
/// review): a packet stamped with a DIFFERENT account is always rejected;
/// an un-stamped packet (pre-#530 watch build) is trusted only when the
/// caller says so — the native mirror resets to `.empty` on every account
/// change, so trusting an un-stamped beat is safe exactly then.
public func liveWorkoutOwnedBy(
    _ workout: LiveWorkout,
    userID: UUID,
    trustsUnstamped: Bool
) -> Bool {
    guard let owner = workout.userID else { return trustsUnstamped }
    return owner == userID
}

/// Stable legacy run identity for pre-#521 WC payloads, derived from the
/// workout's start time. The same run always maps to the same UUID; a fresh
/// `UUID()` is only used when even `started_at` is missing (degenerate packet
/// with no prior row).
private func legacyRunID(from startedAt: Date) -> UUID {
    let milliseconds = Int64(startedAt.timeIntervalSince1970 * 1_000)
    var bytes = [UInt8](repeating: 0, count: 16)
    for index in 0..<8 {
        bytes[index] = UInt8((milliseconds >> (8 * (7 - index))) & 0xFF)
    }
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

// MARK: - Visibility and sync state

/// The final visible row: hides an ended/missing/stale row. Freshness is
/// judged by TWO clocks on purpose: `lastAcceptedAtMs` (phone-local) decides
/// "has the phone accepted anything recently"; `row.updatedAt` (the
/// watch/DB clock) still gates DATA age so a server-only stale row (e.g. one
/// left `live` after a crash) is not presented as a live mirror.
public func visibleLiveWorkoutRow(_ state: LiveWorkoutMirrorState, nowMs: TimeInterval) -> LiveWorkout? {
    guard let row = state.row, row.status == "live", !row.terminal else { return nil }
    if nowMs - state.lastAcceptedAtMs > LiveWorkoutMirrorConstants.staleSeconds * 1_000 { return nil }
    if nowMs - row.updatedAt.timeIntervalSince1970 * 1_000 > LiveWorkoutMirrorConstants.staleSeconds * 1_000 {
        return nil
    }
    return row
}

/// Honest transport state for the currently-visible row. Quietness is
/// measured from `lastAcceptedAtMs` — the phone's OWN clock when it last
/// accepted a packet — NOT from `row.updatedAt` (a watch/DB clock). If
/// neither path has delivered anything fresh for `directQuietSeconds`, the
/// card must not claim a working link.
public func liveWorkoutSyncState(
    for state: LiveWorkoutMirrorState,
    nowMs: TimeInterval
) -> LiveWorkoutSyncState {
    guard let row = state.row, row.status == "live", !row.terminal else { return .unknown }
    let quietAgeMs = nowMs - state.lastAcceptedAtMs
    if quietAgeMs > LiveWorkoutMirrorConstants.staleSeconds * 1_000 { return .unknown }
    if quietAgeMs > LiveWorkoutMirrorConstants.directQuietSeconds * 1_000 {
        return .temporarilyUnreachable
    }
    return state.source == .watchDirect ? .watchDirect : .serverFallback
}

// MARK: - Parsing helpers

private func double(_ value: Any?) -> Double? {
    if let value = value as? Double { return value }
    if let value = value as? Int { return Double(value) }
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) }
    return nil
}

private func int(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? Double, value.rounded() == value, abs(value) < 9_007_199_254_740_992 {
        return Int(value)
    }
    if let value = value as? String { return Int(value) }
    return nil
}

private func bool(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String { return value == "true" }
    return nil
}

private func uuid(_ value: Any?) -> UUID? {
    if let value = value as? UUID { return value }
    if let value = value as? String { return UUID(uuidString: value) }
    return nil
}

private func epochSeconds(_ value: Any?) -> TimeInterval? {
    double(value)
}

private func isoDate(_ value: Any?) -> Date? {
    guard let value = value as? String else { return nil }
    return LocalDateSupport.iso8601Date(from: value)
}
