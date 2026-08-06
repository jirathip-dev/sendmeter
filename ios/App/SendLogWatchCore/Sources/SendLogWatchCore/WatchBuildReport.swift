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
/// retries took OFF the drain path. Deliberately not a case of
/// `WatchSyncStatus`: a quarantined item is not "pending" or "backed up" —
/// it is persisted and will NEVER sync on its own, which is a different
/// fact the user needs told differently. Same honest-states rule: a watch
/// that never reported a count is distinct from one that reported zero.
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
    /// Reported zero quarantined items: nothing is permanently stuck.
    case none
    /// At least one item will never sync on its own.
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
    public static let versionKey = "watch_app_version"
    public static let buildKey = "watch_app_build"
    /// Depth of the watch's offline upload queues at send time (#21) — the
    /// same telemetry channel as the build, so a stuck queue is visible from
    /// the phone without picking the watch up.
    public static let pendingSyncKey = "watch_pending_sync"
    /// Count of items the watch has quarantined (#475 F1) — permanently off
    /// the drain path, on the SAME channel and the SAME honest-states rules
    /// as `pendingSyncKey`, but deliberately a separate key: folding this
    /// into `pendingSyncKey` would tell the user a quarantined item is
    /// "waiting to upload", which the CLAUDE.md #264 rule forbids for
    /// anything that will never sync on its own.
    public static let quarantinedSyncKey = "watch_quarantined_sync"

    /// Adds the report fields to an outgoing watch→phone message. Anything
    /// unknown is simply left off — reporting is observability, so it must
    /// never be able to break the message it rides on, and the facts are
    /// independent (a build with no queue reading still identifies the
    /// sender). A negative count is treated as no reading at all.
    public static func stamped(
        _ message: [String: Any],
        with identity: BuildIdentity?,
        pendingSync: Int? = nil,
        quarantinedSync: Int? = nil
    ) -> [String: Any] {
        var out = message
        if let identity {
            out[versionKey] = identity.version
            out[buildKey] = identity.build
        }
        if let pendingSync, pendingSync >= 0 {
            out[pendingSyncKey] = pendingSync
        }
        if let quarantinedSync, quarantinedSync >= 0 {
            out[quarantinedSyncKey] = quarantinedSync
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

    /// Pulls the reported quarantine count back out on the phone side, on the
    /// same "unknown vs zero" terms as `pendingSync`.
    public static func quarantinedSync(in message: [String: Any]) -> Int? {
        nonNegativeCount(quarantinedSyncKey, in: message)
    }

    /// Drops the report fields before the payload is forwarded to the WebView —
    /// the live-workout / live-force message shapes stay exactly as they were.
    public static func stripped(_ message: [String: Any]) -> [String: Any] {
        var out = message
        out.removeValue(forKey: versionKey)
        out.removeValue(forKey: buildKey)
        out.removeValue(forKey: pendingSyncKey)
        out.removeValue(forKey: quarantinedSyncKey)
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
    /// quarantined item never resolves itself the way a pending upload
    /// drains on its own; nothing on the watch currently ever removes a
    /// `.quarantine` file (see `OfflineQueue`'s doc comment, #475 F8), so
    /// the count can only grow or stay flat between reports. "Stale" would
    /// imply it might have gotten better since — it can't have.
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
