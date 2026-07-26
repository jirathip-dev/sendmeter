import Foundation
import Capacitor
import SendLogWatchCore
import WatchConnectivity

/// The last build the watch reported (#228), kept in UserDefaults so a report
/// that arrived during yesterday's workout still answers "which build is on
/// the wrist?" today — the watch only talks to the phone when it has
/// something to say, so holding this in memory would make the answer depend
/// on when the account sheet happened to be opened.
private enum WatchBuildStore {
    private static let versionKey = "sendmeter.watchBuild.version"
    private static let buildKey = "sendmeter.watchBuild.build"
    private static let reportedAtKey = "sendmeter.watchBuild.reportedAt"

    static var identity: BuildIdentity? {
        BuildIdentity(
            version: UserDefaults.standard.string(forKey: versionKey),
            build: UserDefaults.standard.string(forKey: buildKey)
        )
    }

    /// Epoch seconds, or nil if nothing has ever been reported.
    static var reportedAt: Double? {
        let t = UserDefaults.standard.double(forKey: reportedAtKey)
        return t > 0 ? t : nil
    }

    private static let lock = NSLock()
    private static var lastWrite: (identity: BuildIdentity, at: Double)?

    static func record(_ identity: BuildIdentity) {
        let now = Date().timeIntervalSince1970
        lock.lock()
        // The live-force beat runs at ~2 Hz: rewriting three keys per beat
        // would be pure churn. The same build seen a moment ago says nothing
        // new — only a changed build, or a report worth re-timestamping,
        // reaches the disk.
        if let last = lastWrite, last.identity == identity, now - last.at < 60 {
            lock.unlock()
            return
        }
        lastWrite = (identity, now)
        lock.unlock()

        let defaults = UserDefaults.standard
        defaults.set(identity.version, forKey: versionKey)
        defaults.set(identity.build, forKey: buildKey)
        defaults.set(now, forKey: reportedAtKey)
    }
}

/// Relays the Supabase session to the paired Watch app so it can sign in
/// without its own login flow. No token persistence here — supabase-js
/// already owns the session copy in the WebView; this plugin's only job
/// is forwarding it over WatchConnectivity. `updateApplicationContext` is
/// opportunistic (delivered next time the watch is reachable/launches),
/// not a push — the watch reads `receivedApplicationContext` synchronously
/// at its own launch too, so it never depends on catching a live delegate
/// callback.
@objc(SendLogAuthBridge)
public class SendLogAuthBridge: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "SendLogAuthBridge"
    public let jsName = "SendLogAuthBridge"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "setSession", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearSession", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getWatchInfo", returnType: CAPPluginReturnPromise)
    ]

    // nil on devices that can never have a paired watch (e.g. iPad) — the
    // app is universal (TARGETED_DEVICE_FAMILY "1,2"), and WCSession.isSupported()
    // is false there.
    private var session: WCSession? {
        guard WCSession.isSupported() else { return nil }
        return WCSession.default
    }

    override public func load() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    @objc func setSession(_ call: CAPPluginCall) {
        guard
            let accessToken = call.getString("accessToken"),
            let refreshToken = call.getString("refreshToken")
        else {
            call.reject("Missing accessToken/refreshToken")
            return
        }
        let expiresAt = call.getDouble("expiresAt") ?? 0
        relay([
            "event": "signedIn",
            "accessToken": accessToken,
            "refreshToken": refreshToken,
            "expiresAt": expiresAt
        ])
        call.resolve()
    }

    @objc func clearSession(_ call: CAPPluginCall) {
        relay(["event": "signedOut"])
        call.resolve()
    }

    /// The paired watch's reported build against this phone's own (#228).
    /// Read-only: it reports what the watch has already told us on its
    /// existing messages, and never asks the watch for anything.
    @objc func getWatchInfo(_ call: CAPPluginCall) {
        let wc = session
        // isPaired / isWatchAppInstalled only mean anything once the session
        // has activated — `activated` is carried through so a pre-activation
        // read is reported as "can't tell", not as "no watch".
        let pairing = WatchPairing(
            supported: wc != nil,
            activated: wc?.activationState == .activated,
            paired: wc?.isPaired ?? false,
            appInstalled: wc?.isWatchAppInstalled ?? false
        )
        let watch = WatchBuildStore.identity
        let phone = BuildIdentity(infoDictionary: Bundle.main.infoDictionary)
        var result: [String: Any] = [
            "status": WatchBuildReport.status(
                watch: watch, phone: phone, pairing: pairing
            ).rawValue,
            "supported": pairing.supported,
            "activated": pairing.activated,
            "paired": pairing.paired,
            "appInstalled": pairing.appInstalled
        ]
        if let watch {
            result["watchVersion"] = watch.version
            result["watchBuild"] = watch.build
            result["watchDisplay"] = watch.display
        }
        if let reportedAt = WatchBuildStore.reportedAt {
            result["reportedAt"] = reportedAt
        }
        if let phone {
            result["phoneDisplay"] = phone.display
        }
        call.resolve(result)
    }

    /// Silently no-ops if there's no supported/activated session (no paired
    /// watch, or activation hasn't completed yet) — a later auth event
    /// (e.g. the next silent token refresh) will relay successfully.
    private func relay(_ context: [String: Any]) {
        guard let session, session.activationState == .activated else { return }
        try? session.updateApplicationContext(context)
    }
}

extension SendLogAuthBridge: WCSessionDelegate {
    public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    public func sessionDidBecomeInactive(_ session: WCSession) {}

    public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    /// Watch → phone messages. The workout live-beat rides this session as a
    /// Bluetooth-fast mirror path (sub-second, no network hop) alongside the
    /// Supabase heartbeat; the WebView keeps whichever source is newest. The
    /// force-gauge beat (SL-87) uses the same path, WC-only (no network
    /// fallback — it's a ~2 Hz gauge stream). `requestSession` is the watch
    /// asking to be re-supplied with a fresh session when its relayed token
    /// went stale — the WebView answers by relaying the current session again.
    public func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        handleWatchMessage(message)
    }

    /// Queued (guaranteed-delivery) variant — used when the phone wasn't
    /// reachable at send time, so a `requestSession` still arrives once the
    /// phone app runs.
    public func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        handleWatchMessage(userInfo)
    }

    private func handleWatchMessage(_ message: [String: Any]) {
        // #228: every watch→phone message carries the watch's build. Recorded
        // before the kind switch, so a message this build doesn't understand
        // still tells us which watch build sent it.
        if let identity = WatchBuildReport.identity(in: message) {
            WatchBuildStore.record(identity)
        }
        guard let kind = message["kind"] as? String else { return }
        switch kind {
        case "liveWorkout", "liveForce":
            // Stripped, so the forwarded payloads keep exactly the shape the
            // WebView's LiveWorkoutMessage / LiveForceMessage types describe.
            var payload = WatchBuildReport.stripped(message)
            payload.removeValue(forKey: "kind")
            notifyListeners(kind, data: payload as [String: Any])
        case "requestSession":
            // The WebView (useAuth) listens and re-relays the current session.
            notifyListeners("sessionRequested", data: [:])
        default:
            break
        }
    }
}
