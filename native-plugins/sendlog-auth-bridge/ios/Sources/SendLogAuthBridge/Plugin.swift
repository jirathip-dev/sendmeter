import Foundation
import Capacitor
import WatchConnectivity

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
        CAPPluginMethod(name: "clearSession", returnType: CAPPluginReturnPromise)
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
}
