import Foundation
import Observation
import Supabase
import WatchConnectivity

/// Companion-app auth: the paired iPhone app relays the Supabase session
/// over WatchConnectivity (see sendlog-auth-bridge on the iOS side) so the
/// watch signs in automatically. `updateApplicationContext` is opportunistic
/// (delivered next time the counterpart is reachable/launches), not a push —
/// bootstrap() reads `receivedApplicationContext` synchronously so a cold
/// watch launch doesn't miss data already queued, rather than only relying
/// on the didReceiveApplicationContext delegate callback firing later.
/// Manual email+password sign-in (SignInView) stays as a fallback for
/// first-ever launch before any phone sync, or if hydration fails.
@Observable
final class AuthManager: NSObject {
    enum State {
        case loading
        case signedOut
        case signedIn(userId: UUID)
    }

    var state: State = .loading
    var errorMsg: String?

    private var client: SupabaseClient { SupabaseService.client }

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        Task { await bootstrap() }
    }

    @MainActor
    func bootstrap() async {
        if WCSession.isSupported() {
            let context = WCSession.default.receivedApplicationContext
            // An empty dict means "nothing synced yet", not a sign-out —
            // only an explicit event should ever end the fallback chain.
            if !context.isEmpty, await applyWatchConnectivityEvent(context) {
                return
            }
        }
        // Fall back to the Keychain session WITHOUT refreshing it
        // (`auth.session` refreshes when expired — with a refresh token the
        // phone has since rotated, that trips replay detection and revokes
        // the whole session family; that's how the watch "randomly" signed
        // itself out after an app update). An expired local session just
        // waits: the next phone-app foreground relays fresh tokens.
        if let session = client.auth.currentSession,
           session.expiresAt > Date().timeIntervalSince1970 + 60 {
            state = .signedIn(userId: session.user.id)
        } else {
            state = .signedOut
        }
    }

    /// Applies a `{"event": "signedIn"|"signedOut", ...}` payload relayed
    /// from the phone. Returns true if it resolved auth state (bootstrap
    /// should stop there); false if there was nothing actionable (e.g. a
    /// signedIn event whose network hydration failed) — bootstrap then
    /// falls back to the existing Keychain session / manual login.
    @MainActor
    @discardableResult
    private func applyWatchConnectivityEvent(_ context: [String: Any]) async -> Bool {
        guard let event = context["event"] as? String else { return false }
        switch event {
        case "signedIn":
            guard
                let accessToken = context["accessToken"] as? String,
                let refreshToken = context["refreshToken"] as? String
            else { return false }
            // receivedApplicationContext is PERSISTED — on a cold launch this
            // payload can be hours old. setSession with an expired access
            // token immediately refreshes using the relayed refresh token,
            // which the phone's supabase-js has since rotated → Supabase's
            // replay detection revokes the whole session family. Only consume
            // a still-fresh pair; a stale one is ignored and the next phone
            // foreground re-relays a live session.
            let expiresAt = (context["expiresAt"] as? Double) ?? 0
            guard expiresAt > Date().timeIntervalSince1970 + 60 else { return false }
            do {
                let session = try await client.auth.setSession(
                    accessToken: accessToken, refreshToken: refreshToken
                )
                state = .signedIn(userId: session.user.id)
                return true
            } catch {
                return false
            }
        case "signedOut":
            await signOut()
            return true
        default:
            return false
        }
    }

    /// Email + password sign-in — manual fallback. The password is set once
    /// from the web app (Account sheet); web login itself stays magic-link.
    @MainActor
    func signIn(email: String, password: String) async {
        errorMsg = nil
        do {
            let session = try await client.auth.signIn(
                email: email.trimmingCharacters(in: .whitespaces),
                password: password
            )
            state = .signedIn(userId: session.user.id)
        } catch {
            errorMsg = friendlyAuthError(error)
        }
    }

    @MainActor
    func signOut() async {
        try? await client.auth.signOut()
        state = .signedOut
    }

    private func friendlyAuthError(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("invalid login credentials") {
            return "Wrong email or password. Set the watch password from the web app first (Watch button, top right)."
        }
        return text
    }
}

extension AuthManager: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            await applyWatchConnectivityEvent(applicationContext)
        }
    }
}
