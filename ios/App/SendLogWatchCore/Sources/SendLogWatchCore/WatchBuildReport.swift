import Foundation

/// A bundle's `CFBundleShortVersionString` + `CFBundleVersion` (#228).
///
/// The watch app installs from TestFlight independently of the phone app and
/// routinely lags behind it, so "which build is the watch on?" is a real
/// question the phone could not answer — a phone carrying the #208 rotation
/// fix paired with a pre-#208 watch still has its session family revoked by
/// the watch.
public struct BuildIdentity: Equatable, Sendable {
    public let version: String
    public let build: String

    /// nil when neither field carries anything — "we know nothing" must stay
    /// distinguishable from "we know it's blank", or a watch that never
    /// reported would render as a real (empty) build.
    public init?(version: String?, build: String?) {
        let v = version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let b = build?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !v.isEmpty || !b.isEmpty else { return nil }
        self.version = v.isEmpty ? "?" : v
        self.build = b.isEmpty ? "?" : b
    }

    /// Reads the two Info.plist keys. Takes the dictionary rather than a
    /// `Bundle` so the parsing is exercisable off-device.
    public init?(infoDictionary: [String: Any]?) {
        self.init(
            version: infoDictionary?["CFBundleShortVersionString"] as? String,
            build: infoDictionary?["CFBundleVersion"] as? String
        )
    }

    /// `"1.4.0 (57)"` — the shape the phone's own build already renders in
    /// the account sheet (#225), so the two lines read as one pair.
    public var display: String { "\(version) (\(build))" }

    /// `fastlane beta` injects an integer `CURRENT_PROJECT_VERSION` into the
    /// app, watch and widget at archive time, so build numbers are ordered
    /// within a release train — that's what makes "behind" sayable rather
    /// than just "different". Non-integer (a hand-built Debug install) → nil.
    public var buildNumber: Int? { Int(build) }
}

/// What the account sheet should say about the paired watch's build. The
/// three "we don't have a build" cases are deliberately distinct: a watch
/// that never reported must never render as up to date (#228).
public enum WatchBuildStatus: String, Sendable, Equatable {
    /// No watch paired, or a device that can't have one (iPad).
    case notPaired = "not-paired"
    /// Watch paired, Sendmeter not installed on it.
    case appNotInstalled = "app-not-installed"
    /// Watch app installed but has never sent a message since this phone
    /// install started listening — nothing to compare.
    case notReported = "not-reported"
    case match
    case watchBehind = "watch-behind"
    case watchAhead = "watch-ahead"
    /// Builds differ but aren't orderable (non-integer build numbers).
    case differs
    /// WCSession hasn't activated yet, or the phone's own build is
    /// unreadable — the honest answer is "can't tell", not "fine".
    case unknown
}

/// What the account sheet should say about the watch's offline upload queues
/// (#21). Same honest-states rule as `WatchBuildStatus`: an empty queue and a
/// watch that has never reported one are different facts, and only the first
/// of them means "nothing is stuck".
public enum WatchSyncStatus: String, Sendable, Equatable {
    /// No watch paired, or a device that can't have one (iPad).
    case notPaired = "not-paired"
    /// Watch paired, Sendmeter not installed on it.
    case appNotInstalled = "app-not-installed"
    /// Watch app installed but has never reported a queue depth to this phone
    /// install — nothing is known, which is NOT the same as nothing pending.
    case notReported = "not-reported"
    /// WCSession hasn't activated yet — "can't tell", not "fine".
    case unknown
    /// Reported zero pending items: everything the watch recorded has landed.
    case empty
    /// A few items waiting — normal right after an offline session.
    case pending
    /// Enough items queued that the watch is probably not draining at all.
    case backedUp = "backed-up"
}

/// What the account sheet should say about the watch's quarantined uploads
/// (#475 F1) — bundles a permanent DB rejection or a bounded run of failed
/// retries took OFF the ORDINARY drain path. Deliberately not a case of
/// `WatchSyncStatus`: a quarantined item is not "pending" or "backed up" —
/// it needs a different fact told about it, and (#475 F12/F13) not even the
/// SAME fact for every quarantined item: `.schemaRejection` truly will
/// never sync on its own, but `.stuckRetrying` gets one more automatic
/// attempt after a long backoff. This coarse status only says whether
/// anything is quarantined at all; `quarantinedStuckSync`
/// (`WatchBuildReport.quarantinedStuckSyncKey`) carries the breakdown for
/// callers that need to say which. Same honest-states rule: a watch that
/// never reported a count is distinct from one that reported zero.
public enum WatchQuarantineStatus: String, Sendable, Equatable {
    /// No watch paired, or a device that can't have one (iPad).
    case notPaired = "not-paired"
    /// Watch paired, Sendmeter not installed on it.
    case appNotInstalled = "app-not-installed"
    /// Watch app installed but has never reported a quarantine count to this
    /// phone install — nothing is known, which is NOT the same as none.
    case notReported = "not-reported"
    /// WCSession hasn't activated yet — "can't tell", not "fine".
    case unknown
    /// Reported zero quarantined items: nothing is off the drain path.
    case none
    /// At least one item is off the ordinary drain path — see
    /// `quarantinedStuckSync` for whether any of it will actually retry.
    case stuck
}

/// Pairing facts as WatchConnectivity reports them on the phone. `paired` /
/// `appInstalled` are only meaningful once the session has activated, which
/// is why activation is carried alongside them rather than collapsed away.
public struct WatchPairing: Sendable, Equatable {
    public let supported: Bool
    public let activated: Bool
    public let paired: Bool
    public let appInstalled: Bool

    public init(supported: Bool, activated: Bool, paired: Bool, appInstalled: Bool) {
        self.supported = supported
        self.activated = activated
        self.paired = paired
        self.appInstalled = appInstalled
    }
}

/// The watch→phone build report: the wire keys, the stamping/parsing, and the
/// verdict. Piggybacks on the messages the watch already sends (the live
/// workout beat, the live force beat, and the `requestSession` ask) — the
/// auth path gains no new message, only two extra fields (#228).
public enum WatchBuildReport {
    /// Account owner for queue telemetry and domain payloads. It is the same
    /// immutable owner stamp used by live workout/force/completion messages;
    /// a legacy or ownerless payload must not be retroactively attributed to
    /// whichever account is relayed when its completion is delivered.
    public static let accountUserIdKey = "account_user_id"
    public static let versionKey = "watch_app_version"
    public static let buildKey = "watch_app_build"
    /// Depth of the watch's offline upload queues at send time (#21) — the
    /// same telemetry channel as the build, so a stuck queue is visible from
    /// the phone without picking the watch up.
    public static let pendingSyncKey = "watch_pending_sync"
    /// Ownerless legacy queue items are intentionally not included in the
    /// account's pending total. This separate device diagnostic keeps
    /// "unknown ownership" distinct from both zero and another account's
    /// queue, so a legacy row is visible without being drainable.
    public static let unscopedSyncKey = "watch_unscoped_sync"
    /// Count of items the watch has quarantined (#475 F1) — off the drain
    /// path, on the SAME channel and the SAME honest-states rules as
    /// `pendingSyncKey`, but deliberately a separate key: folding this into
    /// `pendingSyncKey` would tell the user a quarantined item is "waiting
    /// to upload", which the CLAUDE.md #264 rule forbids for anything that
    /// isn't actually queued to sync right now. This is the TOTAL across
    /// both `QuarantineReason` cases.
    public static let quarantinedSyncKey = "watch_quarantined_sync"
    /// Subset of `quarantinedSyncKey` whose reason is `.stuckRetrying`
    /// (#475 F13) — items that WILL be automatically re-attempted after a
    /// backoff (`QueueRetryPolicy.stuckRetryBackoffS`), as opposed to the
    /// `.schemaRejection` remainder (`quarantinedSyncKey` minus this key),
    /// which is proven permanent. Reported separately because the two cases
    /// need different, non-interchangeable copy on the phone — telling a
    /// user their data "will not retry" when it actually will (or the
    /// reverse) is worse than saying nothing distinguishing at all.
    public static let quarantinedStuckSyncKey = "watch_quarantined_stuck_sync"

    /// Adds the report fields to an outgoing watch→phone message. Anything
    /// unknown is simply left off — reporting is observability, so it must
    /// never be able to break the message it rides on, and the facts are
    /// independent (a build with no queue reading still identifies the
    /// sender). A negative count is treated as no reading at all.
    public static func stamped(
        _ message: [String: Any],
        with identity: BuildIdentity?,
        accountUserID: UUID? = nil,
        pendingSync: Int? = nil,
        unscopedSync: Int? = nil,
        quarantinedSync: Int? = nil,
        quarantinedStuckSync: Int? = nil
    ) -> [String: Any] {
        var out = message
        if let identity {
            out[versionKey] = identity.version
            out[buildKey] = identity.build
        }
        if let accountUserID {
            out[accountUserIdKey] = accountUserID.uuidString
        }
        if let pendingSync, pendingSync >= 0 {
            out[pendingSyncKey] = pendingSync
        }
        if let unscopedSync, unscopedSync >= 0 {
            out[unscopedSyncKey] = unscopedSync
        }
        if let quarantinedSync, quarantinedSync >= 0 {
            out[quarantinedSyncKey] = quarantinedSync
        }
        if let quarantinedStuckSync, quarantinedStuckSync >= 0 {
            out[quarantinedStuckSyncKey] = quarantinedStuckSync
        }
        return out
    }

    /// Pulls the reported identity back out on the phone side.
    public static func identity(in message: [String: Any]) -> BuildIdentity? {
        BuildIdentity(
            version: message[versionKey] as? String,
            build: message[buildKey] as? String
        )
    }

    /// Reads a non-negative count from `key`, widening `Double` (WatchConnectivity
    /// round-trips numbers as whatever `NSNumber` fits them) and refusing a
    /// negative value the same way `stamped` refuses to write one.
    private static func nonNegativeCount(_ key: String, in message: [String: Any]) -> Int? {
        let raw: Int?
        if let i = message[key] as? Int {
            raw = i
        } else if let n = message[key] as? Double {
            raw = Int(n)
        } else {
            raw = nil
        }
        guard let raw, raw >= 0 else { return nil }
        return raw
    }

    /// Pulls the reported queue depth back out on the phone side. nil when the
    /// message carries no reading (an older watch build, or a watch that has
    /// not counted its queues yet) — "we don't know" must stay distinguishable
    /// from "the queue is empty".
    public static func pendingSync(in message: [String: Any]) -> Int? {
        nonNegativeCount(pendingSyncKey, in: message)
    }

    /// Pulls the count of ownerless legacy queue items back out. It is a
    /// quarantine/diagnostic count, never a promise that those rows can be
    /// uploaded under the current account.
    public static func unscopedSync(in message: [String: Any]) -> Int? {
        nonNegativeCount(unscopedSyncKey, in: message)
    }

    /// Pulls the reported quarantine count back out on the phone side, on the
    /// same "unknown vs zero" terms as `pendingSync`.
    public static func quarantinedSync(in message: [String: Any]) -> Int? {
        nonNegativeCount(quarantinedSyncKey, in: message)
    }

    /// Pulls the reported `.stuckRetrying` SUBSET back out on the phone
    /// side, same terms. Absent on an older watch build that reports only
    /// the combined total — callers should treat that as "breakdown
    /// unknown", not zero (see `watchBuild.ts`'s presentation logic, which
    /// defaults an unknown breakdown to the more cautious "permanent"
    /// framing rather than silently downgrading to "retrying").
    public static func quarantinedStuckSync(in message: [String: Any]) -> Int? {
        nonNegativeCount(quarantinedStuckSyncKey, in: message)
    }

    /// Drops the report fields before the payload is forwarded to the WebView —
    /// the live-workout / live-force message shapes stay exactly as they were.
    public static func stripped(_ message: [String: Any]) -> [String: Any] {
        var out = message
        out.removeValue(forKey: versionKey)
        out.removeValue(forKey: buildKey)
        out.removeValue(forKey: pendingSyncKey)
        out.removeValue(forKey: unscopedSyncKey)
        out.removeValue(forKey: quarantinedSyncKey)
        out.removeValue(forKey: quarantinedStuckSyncKey)
        return out
    }

    public static func status(
        watch: BuildIdentity?,
        phone: BuildIdentity?,
        pairing: WatchPairing
    ) -> WatchBuildStatus {
        guard pairing.supported else { return .notPaired }
        guard pairing.activated else { return .unknown }
        guard pairing.paired else { return .notPaired }
        guard pairing.appInstalled else { return .appNotInstalled }
        guard let watch else { return .notReported }
        guard let phone else { return .unknown }
        if watch == phone { return .match }
        if let w = watch.buildNumber, let p = phone.buildNumber, w != p {
            return w < p ? .watchBehind : .watchAhead
        }
        return .differs
    }

    /// At this many queued items the queue reads as stuck rather than as a
    /// session waiting for signal: the watch drains on every launch and
    /// foreground, so a handful of items means several sessions in a row
    /// failed to upload.
    public static let backedUpThreshold = 5

    /// A report older than this describes a queue that may well have drained
    /// since — the count is still the only number we have, but it can no
    /// longer be read as current.
    public static let pendingSyncStaleAfterS: Double = 24 * 60 * 60

    public static func syncStatus(
        pendingSync: Int?,
        pairing: WatchPairing
    ) -> WatchSyncStatus {
        guard pairing.supported else { return .notPaired }
        guard pairing.activated else { return .unknown }
        guard pairing.paired else { return .notPaired }
        guard pairing.appInstalled else { return .appNotInstalled }
        guard let pendingSync, pendingSync >= 0 else { return .notReported }
        if pendingSync == 0 { return .empty }
        return pendingSync >= backedUpThreshold ? .backedUp : .pending
    }

    /// Whether a reported count is old enough that it describes the past
    /// rather than the present. `now` is injected so this is testable.
    public static func isPendingSyncStale(reportedAt: Double?, now: Double) -> Bool {
        guard let reportedAt, reportedAt > 0 else { return false }
        return now - reportedAt > pendingSyncStaleAfterS
    }

    /// #475 F1: no staleness concept here (unlike `syncStatus`) — a
    /// quarantined item does not resolve itself the way a pending upload
    /// drains on its own; nothing on the watch removes a `.quarantine` file
    /// except the F12 backoff resurrection (`.stuckRetrying` only, and even
    /// then it re-quarantines rather than vanishing unless the retry
    /// actually succeeds), so the count is monotonically non-decreasing
    /// between reports UNDER NORMAL OPERATION. "Stale" would wrongly imply
    /// it might have improved on its own, which it structurally can't.
    /// **Known hole (#475 F14), not fixed here:** deleting and reinstalling
    /// the watch app wipes its Documents directory, so the TRUE count drops
    /// to zero, but the phone keeps showing its last nonzero report until
    /// the watch sends a new one — a reinstalled watch reads as still stuck
    /// for a while. Worth a real fix if `.stuckRetrying` grows a purge path
    /// beyond F12's backoff.
    public static func quarantineStatus(
        quarantinedSync: Int?,
        pairing: WatchPairing
    ) -> WatchQuarantineStatus {
        guard pairing.supported else { return .notPaired }
        guard pairing.activated else { return .unknown }
        guard pairing.paired else { return .notPaired }
        guard pairing.appInstalled else { return .appNotInstalled }
        guard let quarantinedSync, quarantinedSync >= 0 else { return .notReported }
        return quarantinedSync == 0 ? .none : .stuck
    }
}
