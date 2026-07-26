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

    /// Adds the build fields to an outgoing watch→phone message. A nil
    /// identity leaves the message untouched — reporting is observability, so
    /// it must never be able to break the message it rides on.
    public static func stamped(
        _ message: [String: Any],
        with identity: BuildIdentity?
    ) -> [String: Any] {
        guard let identity else { return message }
        var out = message
        out[versionKey] = identity.version
        out[buildKey] = identity.build
        return out
    }

    /// Pulls the reported identity back out on the phone side.
    public static func identity(in message: [String: Any]) -> BuildIdentity? {
        BuildIdentity(
            version: message[versionKey] as? String,
            build: message[buildKey] as? String
        )
    }

    /// Drops the build fields before the payload is forwarded to the WebView —
    /// the live-workout / live-force message shapes stay exactly as they were.
    public static func stripped(_ message: [String: Any]) -> [String: Any] {
        var out = message
        out.removeValue(forKey: versionKey)
        out.removeValue(forKey: buildKey)
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
}
