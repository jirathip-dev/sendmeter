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

    /// Records the report and returns whether the identity actually changed.
    @discardableResult
    static func record(_ identity: BuildIdentity) -> Bool {
        let now = Date().timeIntervalSince1970
        lock.lock()
        let changed = self.identity != identity
        // The live-force beat runs at ~2 Hz: rewriting three keys per beat
        // would be pure churn. The same build seen a moment ago says nothing
        // new — only a changed build, or a report worth re-timestamping,
        // reaches the disk.
        if let last = lastWrite, last.identity == identity, now - last.at < 60 {
            lock.unlock()
            return changed
        }
        lastWrite = (identity, now)
        lock.unlock()

        let defaults = UserDefaults.standard
        defaults.set(identity.version, forKey: versionKey)
        defaults.set(identity.build, forKey: buildKey)
        defaults.set(now, forKey: reportedAtKey)
        return changed
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

    /// Records the report and returns whether the depth actually changed.
    @discardableResult
    static func record(_ count: Int) -> Bool {
        let now = Date().timeIntervalSince1970
        lock.lock()
        let changed = pendingCount != count
        // Same throttle as the build store — the force beat runs at ~2 Hz and
        // an unchanged count says nothing new. A *changed* count always
        // writes: that's the transition worth seeing.
        if let last = lastWrite, last.count == count, now - last.at < 60 {
            lock.unlock()
            return changed
        }
        lastWrite = (count, now)
        lock.unlock()

        let defaults = UserDefaults.standard
        defaults.set(count, forKey: countKey)
        defaults.set(now, forKey: reportedAtKey)
        return changed
    }
}

/// The watch's last-reported QUARANTINE count (#475 F1) — items a permanent
/// DB rejection or a bounded run of failed retries took off the drain path
/// entirely. Same storage shape and throttle as `WatchSyncStore`, but
/// deliberately a separate store/key: a quarantined item is NOT "pending" —
/// folding the two counts together would make a permanently-stuck workout
/// read as "waiting to upload", which the app's own #264 rule forbids for
/// anything that will never sync on its own.
private enum QuarantinedSyncStore {
    private static let countKey = "sendmeter.watchSync.quarantined"
    private static let reportedAtKey = "sendmeter.watchSync.quarantinedReportedAt"

    static var count: Int? {
        guard UserDefaults.standard.object(forKey: countKey) != nil else { return nil }
        return UserDefaults.standard.integer(forKey: countKey)
    }

    static var reportedAt: Double? {
        let t = UserDefaults.standard.double(forKey: reportedAtKey)
        return t > 0 ? t : nil
    }

    private static let lock = NSLock()
    private static var lastWrite: (count: Int, at: Double)?

    @discardableResult
    static func record(_ count: Int) -> Bool {
        let now = Date().timeIntervalSince1970
        lock.lock()
        let changed = self.count != count
        if let last = lastWrite, last.count == count, now - last.at < 60 {
            lock.unlock()
            return changed
        }
        lastWrite = (count, now)
        lock.unlock()

        let defaults = UserDefaults.standard
        defaults.set(count, forKey: countKey)
        defaults.set(now, forKey: reportedAtKey)
        return changed
    }
}

/// The watch's last-reported `.stuckRetrying` SUBSET of the quarantine count
/// (#475 F13), stored the same way and for the same reason as
/// `QuarantinedSyncStore`. Kept separate because the two `QuarantineReason`
/// cases need different, non-interchangeable copy on the phone:
/// `.schemaRejection` (the remainder, `QuarantinedSyncStore.count` minus
/// this) truly will never sync on its own; `.stuckRetrying` (this store)
/// gets one more automatic attempt after a backoff. Telling the user the
/// wrong one of those two facts about their own data is worse than not
/// splitting them at all.
private enum QuarantinedStuckSyncStore {
    private static let countKey = "sendmeter.watchSync.quarantinedStuck"
    private static let reportedAtKey = "sendmeter.watchSync.quarantinedStuckReportedAt"

    static var count: Int? {
        guard UserDefaults.standard.object(forKey: countKey) != nil else { return nil }
        return UserDefaults.standard.integer(forKey: countKey)
    }

    static var reportedAt: Double? {
        let t = UserDefaults.standard.double(forKey: reportedAtKey)
        return t > 0 ? t : nil
    }

    private static let lock = NSLock()
    private static var lastWrite: (count: Int, at: Double)?

    @discardableResult
    static func record(_ count: Int) -> Bool {
        let now = Date().timeIntervalSince1970
        lock.lock()
        let changed = self.count != count
        if let last = lastWrite, last.count == count, now - last.at < 60 {
            lock.unlock()
            return changed
        }
        lastWrite = (count, now)
        lock.unlock()

        let defaults = UserDefaults.standard
        defaults.set(count, forKey: countKey)
        defaults.set(now, forKey: reportedAtKey)
        return changed
    }
}

/// Relays the Supabase **access token** to the paired Watch app so it can sign
/// in without its own login flow (#265 — never the refresh token; see
/// `setSession`). No token persistence here: supabase-js already owns the
/// session copy in the WebView, and this plugin's only job is forwarding it
/// over WatchConnectivity. `updateApplicationContext` is opportunistic
/// (delivered next time the watch is reachable/launches), not a push — the
/// watch reads its persisted incoming application context synchronously at its
/// own launch, so it never depends on catching a live delegate callback.
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

    /// The latest auth relay and readiness result are merged into one
    /// application context so a watch that was unreachable during the request
    /// still receives both its access-token context and compact snapshot on
    /// next activation. The pure merge rules live in SendLogWatchCore and are
    /// tested without WatchConnectivity.
    private let readinessLock = NSLock()
    private var applicationContext = ReadinessApplicationContext()
    /// `updateApplicationContext` can only persist a sign-out once
    /// WatchConnectivity is activated. Keep the logical hard-reset durable so
    /// a process restart cannot seed a stale signed-in outgoing context before
    /// the next auth event gets a chance to relay.
    private let signedOutKey = "sendmeter.authBridge.signedOut"

    override public func load() {
        // `applicationContext` is the phone's own last outgoing context and
        // survives a phone process restart. Seed the logical auth/readiness
        // state from it before registering any publisher so a background
        // watch result cannot replace the signed-in context with a
        // readiness-only payload. The counterpart's incoming direction must
        // not seed this state. Reconciliation strips old relay stamps;
        // signedOut is a hard reset and cannot resurrect stale state.
        let session = self.session
        readinessLock.lock()
        if UserDefaults.standard.bool(forKey: signedOutKey) {
            _ = applicationContext.reconcile(["event": "signedOut"])
        } else if let session {
            _ = applicationContext.reconcile(session.applicationContext)
        }
        readinessLock.unlock()

        SendLogReadinessBridge.registerResultPublisher { [weak self] result, immediate in
            self?.publishReadinessResult(result, immediate: immediate)
        }
        SendLogReadinessBridge.registerSessionRequestHandler { [weak self] in
            self?.notifyListeners("sessionRequested", data: ["reason": "readiness"])
        }

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
            "expiresAt": expiresAt,
            // #614 F6: this phone acknowledges watch workout beats over
            // WatchConnectivity (`didReceiveMessage(_:replyHandler:)` replies
            // `[:]`). The watch only engages its acknowledged-send/retry
            // contract when it has seen this stamp — an older phone build
            // omits it, and the watch then keeps the old fire-and-forget
            // behavior instead of counting a delivered-but-unacked send as a
            // failure. No capability negotiation is needed because the
            // stamp's ABSENCE is the negotiation: it proves nothing about
            // this phone build, so the watch falls back.
            "ack_capable": true,
            // Temporary #368 compatibility for pre-#270 watches, whose
            // decoder required this key. This fixed literal never came from
            // Supabase and therefore cannot rotate/revoke a session family.
            // Current watches ignore it and keep no refresh-token field.
            "refreshToken": SessionRelay.legacyRefreshTokenSentinel
        ]
        // A hint only — the watch reads `sub` out of the token itself.
        if let userId = call.getString("userId") { context["userId"] = userId }
        relay(context, guaranteed: call.getBool("guaranteed") ?? false)
        call.resolve()
    }

    @objc func clearSession(_ call: CAPPluginCall) {
        // `relay` performs the signedOut state transition and transport send
        // while holding the same lock as readiness publication. Resetting the
        // in-memory merger first would leave a window where a late readiness
        // result could be sent directly before the signedOut context won.
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
        // The watch's quarantine count (#475 F1) — same read-only terms as
        // the pending depth above, on its own key so it can never be
        // presented as "waiting to upload".
        let quarantined = QuarantinedSyncStore.count
        result["quarantineStatus"] = WatchBuildReport.quarantineStatus(
            quarantinedSync: quarantined, pairing: pairing
        ).rawValue
        if let quarantined {
            result["quarantinedSyncCount"] = quarantined
        }
        if let quarantinedReportedAt = QuarantinedSyncStore.reportedAt {
            result["quarantinedSyncReportedAt"] = quarantinedReportedAt
        }
        // The `.stuckRetrying` subset (#475 F13) — absent entirely on a
        // watch build that only ever reported the combined total; the JS
        // side treats that as "breakdown unknown", not zero.
        if let quarantinedStuck = QuarantinedStuckSyncStore.count {
            result["quarantinedStuckSyncCount"] = quarantinedStuck
        }
        if let quarantinedStuckReportedAt = QuarantinedStuckSyncStore.reportedAt {
            result["quarantinedStuckSyncReportedAt"] = quarantinedStuckReportedAt
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
    /// The readiness result's direct reply is sent while the same lock guards
    /// the logical state update. If a signedOut transition won the race, the
    /// result is reduced to a signedOut context and no direct result can
    /// resurrect the old watch state.
    private func relay(
        _ context: [String: Any],
        guaranteed: Bool = false,
        immediateReadiness: Bool = false,
        requireSignedOut: Bool = false
    ) {
        readinessLock.lock()
        if requireSignedOut,
           !applicationContext.isSignedOut,
           !UserDefaults.standard.bool(forKey: signedOutKey) {
            readinessLock.unlock()
            return
        }
        let payload = applicationContext.update(context)
        let signedOut = applicationContext.isSignedOut
        if signedOut {
            UserDefaults.standard.set(true, forKey: signedOutKey)
        } else if context["event"] as? String == "signedIn" {
            UserDefaults.standard.set(false, forKey: signedOutKey)
        }
        guard let session, session.activationState == .activated else {
            readinessLock.unlock()
            return
        }
        var stampedPayload = payload
        stampedPayload["relayId"] = UUID().uuidString
        stampedPayload["relayedAt"] = Date().timeIntervalSince1970
        try? session.updateApplicationContext(stampedPayload)
        if guaranteed { session.transferUserInfo(stampedPayload) }

        if immediateReadiness,
           !signedOut,
           context["kind"] as? String == ReadinessRefreshResult.kind,
           session.isReachable {
            var direct = context
            direct["relayId"] = UUID().uuidString
            direct["relayedAt"] = Date().timeIntervalSince1970
            session.sendMessage(direct, replyHandler: nil, errorHandler: nil)
        }
        readinessLock.unlock()
    }

    /// Stores the result in latest application context and, when the watch
    /// asked over a reachable `sendMessage`, sends a direct fast-path copy as
    /// well. The direct dictionary is intentionally compact and has no health
    /// raw samples or credentials; context retains only the latest result.
    private func publishReadinessResult(_ result: [String: Any], immediate: Bool) {
        relay(result, immediateReadiness: immediate)
    }
}

extension SendLogAuthBridge: WCSessionDelegate {
    public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated else { return }

        // `updateApplicationContext` is durable only after activation. If a
        // phone signed out while WC was inactive (or the process restarted
        // before the old clear could be delivered), flush a fresh-stamped
        // signedOut payload through both the latest-state and guaranteed
        // queues now. `relay` re-checks the locked logical context, stamps
        // fresh relayId/relayedAt values, and cannot resurrect readiness.
        relay(
            ["event": "signedOut"],
            guaranteed: true,
            requireSignedOut: true
        )
    }

    public func sessionDidBecomeInactive(_ session: WCSession) {}

    public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    public func sessionWatchStateDidChange(_ session: WCSession) {
        // Install/update/uninstall can change while AccountSheet is open.
        notifyListeners("watchInfoChanged", data: [:])
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
        handleWatchMessage(message, replyHandler: nil)
    }

    /// Reachable request path. The reply handler is passed through the narrow
    /// generic bridge seam; the health plugin executes the request on the
    /// iPhone even if the WebView is suspended.
    public func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        handleWatchMessage(message, replyHandler: replyHandler)
    }

    /// Queued (guaranteed-delivery) variant — used when the phone wasn't
    /// reachable at send time, so a `requestSession` still arrives once the
    /// phone app runs.
    public func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        handleWatchMessage(userInfo, replyHandler: nil)
    }

    private func handleWatchMessage(
        _ message: [String: Any],
        replyHandler: (([String: Any]) -> Void)? = nil
    ) {
        // #228: every watch→phone message carries the watch's build. Recorded
        // before the kind switch, so a message this build doesn't understand
        // still tells us which watch build sent it.
        let buildChanged = WatchBuildReport.identity(in: message)
            .map(WatchBuildStore.record) ?? false
        // #21: and its offline-queue depth, on the same terms — recorded here
        // so any message the watch sends refreshes the answer.
        let pendingChanged = WatchBuildReport.pendingSync(in: message)
            .map(WatchSyncStore.record) ?? false
        // #475 F1: and its quarantine count, on the same terms again — a
        // workout that gets quarantined must reach the phone the same way a
        // pending-count change does.
        let quarantinedChanged = WatchBuildReport.quarantinedSync(in: message)
            .map(QuarantinedSyncStore.record) ?? false
        // #475 F13: and the `.stuckRetrying` subset — a bundle moving
        // between reasons (the F12 resurrection path) can change this
        // without changing the total.
        let quarantinedStuckChanged = WatchBuildReport.quarantinedStuckSync(in: message)
            .map(QuarantinedStuckSyncStore.record) ?? false
        let kind = message["kind"] as? String
        // Live force arrives around 2 Hz. Refresh diagnostics only for a real
        // build/count transition, or explicit control/status messages where
        // pairing/install state may also have changed.
        if buildChanged || pendingChanged || quarantinedChanged || quarantinedStuckChanged || kind == "requestSession" || kind == "queueStatus" {
            notifyListeners("watchInfoChanged", data: [:])
        }
        if SendLogReadinessBridge.route(message, replyHandler: replyHandler) {
            return
        }
        guard let kind else { return }
        switch kind {
        case "liveWorkout", "liveForce":
            // Stripped, so the forwarded payloads keep exactly the shape the
            // WebView's LiveWorkoutMessage / LiveForceMessage types describe.
            var payload = WatchBuildReport.stripped(message)
            payload.removeValue(forKey: "kind")
            // #614: stamp the phone-side receipt boundary so the WebView can
            // split the watch-capture→plugin latency (wireMs) from the
            // plugin→WebView latency (latencyMs) instead of averaging them.
            payload["received_at"] = Date().timeIntervalSince1970
            notifyListeners(kind, data: payload as [String: Any])
            // #614: acknowledge the acknowledged-send contract the watch uses
            // for workout beats — the watch passes a `replyHandler` so a
            // failed/unreachable direct send can be retried once instead of
            // silently falling back to the ~5s Supabase heartbeat. The reply
            // is deliberately empty (there is no per-beat payload to return).
            replyHandler?([:])
        case "requestSession":
            // The WebView (useAuth) listens and re-relays the current session.
            notifyListeners("sessionRequested", data: [:])
        case "queueStatus":
            break
        default:
            break
        }
    }
}
