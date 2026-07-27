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

/// The watch's last-reported offline-queue depth (#21), stored the same way
/// and for the same reason as `WatchBuildStore`: the watch only talks when it
/// has something to say, so a count held in memory would answer "how backed up
/// is the watch?" only for watches that happened to send something while this
/// account sheet was open.
private enum WatchSyncStore {
    private static let countKey = "sendmeter.watchSync.pending"
    private static let reportedAtKey = "sendmeter.watchSync.reportedAt"

    /// nil when nothing has ever been reported — which must not be read as an
    /// empty queue (see `WatchSyncStatus.notReported`).
    static var pendingCount: Int? {
        guard UserDefaults.standard.object(forKey: countKey) != nil else { return nil }
        return UserDefaults.standard.integer(forKey: countKey)
    }

    /// Epoch seconds, or nil if nothing has ever been reported.
    static var reportedAt: Double? {
        let t = UserDefaults.standard.double(forKey: reportedAtKey)
        return t > 0 ? t : nil
    }

    private static let lock = NSLock()
    private static var lastWrite: (count: Int, at: Double)?

    static func record(_ count: Int) {
        let now = Date().timeIntervalSince1970
        lock.lock()
        // Same throttle as the build store — the force beat runs at ~2 Hz and
        // an unchanged count says nothing new. A *changed* count always
        // writes: that's the transition worth seeing.
        if let last = lastWrite, last.count == count, now - last.at < 60 {
            lock.unlock()
            return
        }
        lastWrite = (count, now)
        lock.unlock()

        let defaults = UserDefaults.standard
        defaults.set(count, forKey: countKey)
        defaults.set(now, forKey: reportedAtKey)
    }
}

/// Relays the Supabase **access token** to the paired Watch app so it can sign
/// in without its own login flow (#265 — never the refresh token; see
/// `setSession`). No token persistence here: supabase-js already owns the
/// session copy in the WebView, and this plugin's only job is forwarding it
/// over WatchConnectivity. `updateApplicationContext` is opportunistic
/// (delivered next time the watch is reachable/launches), not a push — the
/// watch reads `receivedApplicationContext` synchronously at its own launch
/// too, so it never depends on catching a live delegate callback.
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

    /// Relays the **access token only** (#265). The refresh token used to ride
    /// along here; supabase-swift on the watch then persisted it and would
    /// eventually present a copy the phone had long since rotated, which trips
    /// Supabase's reuse detection and revokes the whole session family — phone
    /// included. Nothing on the watch can refresh a token, so nothing on the
    /// watch needs one.
    ///
    /// `guaranteed` picks the WatchConnectivity channel — see `relay`.
    @objc func setSession(_ call: CAPPluginCall) {
        guard let accessToken = call.getString("accessToken") else {
            call.reject("Missing accessToken")
            return
        }
        let expiresAt = call.getDouble("expiresAt") ?? 0
        var context: [String: Any] = [
            "event": "signedIn",
            "accessToken": accessToken,
            "expiresAt": expiresAt
        ]
        // A hint only — the watch reads `sub` out of the token itself.
        if let userId = call.getString("userId") { context["userId"] = userId }
        relay(context, guaranteed: call.getBool("guaranteed") ?? false)
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
        // The watch's offline-queue depth (#21) — same read-only terms: it
        // reports what already arrived on the watch's own messages.
        let pending = WatchSyncStore.pendingCount
        let pendingReportedAt = WatchSyncStore.reportedAt
        result["syncStatus"] = WatchBuildReport.syncStatus(
            pendingSync: pending, pairing: pairing
        ).rawValue
        result["pendingSyncStale"] = WatchBuildReport.isPendingSyncStale(
            reportedAt: pendingReportedAt, now: Date().timeIntervalSince1970
        )
        if let pending {
            result["pendingSyncCount"] = pending
        }
        if let pendingReportedAt {
            result["pendingSyncReportedAt"] = pendingReportedAt
        }
        call.resolve(result)
    }

    /// Silently no-ops if there's no supported/activated session (no paired
    /// watch, or activation hasn't completed yet) — a later auth event
    /// (e.g. the next silent token refresh) will relay successfully.
    ///
    /// Every payload is stamped with a fresh `relayId` (#266). Two relays of
    /// the *same* Supabase session — which is what answering a watch's
    /// `requestSession` produces while the phone's access token is still valid
    /// — would otherwise be byte-identical dictionaries, and an application
    /// context identical to the one already set gives WatchConnectivity nothing
    /// new to deliver. That is the leading explanation for why the push path
    /// (sign out / sign in on the phone: genuinely different payloads) worked
    /// while the pull path never landed.
    ///
    /// `guaranteed` additionally queues the payload with `transferUserInfo`,
    /// used when answering a pull. Application context keeps only the latest
    /// value and is delivered opportunistically; a queued transfer is delivered
    /// exactly once, in order, whenever the watch app next runs. Push relays
    /// stay context-only on purpose — they fire on every foreground, and
    /// queueing each one would build a backlog of dead tokens for a watch
    /// that's been in a drawer.
    private func relay(_ context: [String: Any], guaranteed: Bool = false) {
        guard let session, session.activationState == .activated else { return }
        var payload = context
        payload["relayId"] = UUID().uuidString
        payload["relayedAt"] = Date().timeIntervalSince1970
        try? session.updateApplicationContext(payload)
        if guaranteed { session.transferUserInfo(payload) }
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
        // #21: and its offline-queue depth, on the same terms — recorded here
        // so any message the watch sends refreshes the answer.
        if let pending = WatchBuildReport.pendingSync(in: message) {
            WatchSyncStore.record(pending)
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
