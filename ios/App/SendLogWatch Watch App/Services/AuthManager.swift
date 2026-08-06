import Foundation
import Observation
import OSLog
import SendLogWatchCore
import WatchConnectivity

/// Companion-app auth. The paired iPhone relays its Supabase **access token**
/// over WatchConnectivity (see sendlog-auth-bridge on the iOS side) and the
/// watch signs in from that alone — no refresh token ever crosses, and none is
/// stored (issue #265; see `SupabaseService` for the two failed attempts that
/// preceded this one).
///
/// Two consequences follow, and both are deliberate:
///
/// 1. **There is no manual sign-in.** An access token is all the watch can
///    hold, and only the phone can mint one, so an email+password form here
///    would have to create an independent session — which the next relay would
///    overwrite anyway, putting a refresh token back on the wrist. The screen
///    it used to occupy now explains what the watch is waiting for (#266).
/// 2. **The watch stays signed in when its token expires.** Identity outlives
///    the token; only an explicit `signedOut` relay clears it. See
///    `SessionRelay.state` for why the offline queues depend on that.
///
/// Recovery is a pull: `requestSession` → the phone's WebView answers by
/// relaying again. Triggered on launch, on reachability, on foreground, from
/// the waiting screen's Retry, and by a slow poll while the token is stale.
@Observable
final class AuthManager: NSObject {
    private static let log = Logger(
        subsystem: "com.jirathip.sendlog.watchkitapp", category: "auth"
    )

    private(set) var state: WatchAuthState = .signedOut
    /// True while we've asked the phone and are waiting for an answer — the
    /// waiting screen shows a small spinner and disables its Retry, so a tap
    /// doesn't look dropped. It no longer replaces the explanation with a
    /// "signing in…" state (#278); routine auto sign-in isn't worth narrating.
    private(set) var syncing = false
    /// Why the last relay was refused, if it was (#266: a rejected relay must
    /// be visible, not dropped silently). Cleared by the next good relay.
    private(set) var lastRejection: RelayRejection?
    /// When a relay last arrived at all — the difference between "the phone
    /// isn't answering" and "the phone answered with something unusable".
    private(set) var lastRelayAt: Date?

    private var syncTimeout: Task<Void, Never>?
    private var poll: Task<Void, Never>?
    private var lastRequestAt: TimeInterval?
    /// One queued (guaranteed-delivery) ask per stale episode — `transferUserInfo`
    /// piles up while the phone app isn't running, and a backlog of asks would
    /// all be delivered at once the moment it launches.
    private var queuedRequest = false

    private var now: TimeInterval { Date().timeIntervalSince1970 }

    /// #472b: `OfflineQueue` (an actor with no view-tree access) needs a way
    /// to ask for a fresh relay when a drain discovers the token it holds is
    /// stale. There is deliberately no `AuthManager.shared` — SwiftUI owns
    /// the one instance as `@State` on the app root — so this is a weak
    /// back-reference, set once below, rather than a second ownership path.
    /// `nonisolated(unsafe)` matches this file's existing pattern for a
    /// simple pointer set once at startup and only ever read through an
    /// `await`ed call into `@MainActor` isolation (see
    /// `AuthManagerRelayRequester`).
    nonisolated(unsafe) static weak var current: AuthManager?

    override init() {
        super.init()
        Self.current = self
        // Nothing on the watch may hold a rotating credential — including one
        // left behind in the Keychain by a build that predates #265.
        WatchSessionStore.shared.purgeLegacySupabaseKeychain()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        Task { @MainActor in bootstrap() }
    }

    deinit {
        poll?.cancel()
        syncTimeout?.cancel()
    }

    @MainActor
    func bootstrap() {
        if WCSession.isSupported() {
            // `receivedApplicationContext` is read synchronously here rather
            // than waiting for the delegate callback: it is persisted, so a
            // cold launch may already be holding a payload that will never be
            // re-delivered. It may equally be hours old, which `decode`
            // refuses on freshness grounds.
            let context = WCSession.default.receivedApplicationContext
            // An empty dict means "nothing synced yet", not a sign-out — only
            // an explicit event may end the fallback chain.
            if !context.isEmpty { apply(context) }
        }
        refreshState()
        startPolling()
    }

    /// Recomputes `state` from the stored session against the clock. Called
    /// after every relay, on foreground, and from the poll — an access token
    /// goes stale by the passage of time alone, with no event to react to.
    @MainActor
    func refreshState() {
        let previous = state
        state = SessionRelay.state(for: WatchSessionStore.shared.current, now: now)
        if state != previous {
            Self.log.info("auth state \(String(describing: previous)) → \(String(describing: self.state))")
        }
        if needsToken { requestSessionFromPhone() }
    }

    /// True when the watch cannot make an authenticated request right now:
    /// signed out entirely, or signed in with an expired token.
    var needsToken: Bool {
        switch state {
        case .signedOut: return true
        case let .signedIn(_, tokenFresh): return !tokenFresh
        }
    }

    /// Ask the paired iPhone to relay a fresh access token. The phone's
    /// supabase-js is the sole refresher, so this is the watch's only recovery
    /// path. Reachable → immediate message; otherwise queue it so it lands
    /// when the phone app next runs.
    @MainActor
    func requestSessionFromPhone(force: Bool = false) {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.activationState == .activated else { return }
        guard force || SessionRelay.shouldRequestRelay(now: now, lastRequestAt: lastRequestAt)
        else { return }
        lastRequestAt = now
        syncing = true
        // Stamped with this install's build + queue depth (#228, #21) — the
        // account sheet on the phone reads whatever last arrived.
        let msg = WatchBuild.stamp(["kind": "requestSession"])
        if s.isReachable {
            s.sendMessage(msg, replyHandler: nil) { [weak self] error in
                Self.log.error("requestSession send failed: \(error.localizedDescription)")
                Task { @MainActor in self?.queueRequest(msg) }
            }
        } else {
            queueRequest(msg)
        }
        // Stop claiming we're mid-sign-in if the phone never answers.
        syncTimeout?.cancel()
        syncTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.syncing = false }
        }
    }

    @MainActor
    private func queueRequest(_ msg: [String: Any]) {
        guard !queuedRequest else { return }
        queuedRequest = true
        WCSession.default.transferUserInfo(msg)
    }

    /// Applies a relay payload from the phone. Every outcome is recorded:
    /// silence about a refusal is what left users with a watch that offered a
    /// login form and no explanation (#266).
    @MainActor
    private func apply(_ context: [String: Any]) {
        let outcome = SessionRelay.decode(context, now: now)
        switch outcome {
        case let .signedIn(session):
            lastRelayAt = Date()
            lastRejection = nil
            queuedRequest = false
            WatchSessionStore.shared.store(session)
            syncTimeout?.cancel()
            syncing = false
            state = SessionRelay.state(for: session, now: now)
            Self.log.info("relay accepted (relayId \(session.relayId ?? "none"))")
            // A stale-token pass may still be suspended in either queue. A
            // coalesced request guarantees a fresh-token follow-up pass.
            Task {
                async let workouts: Void = OfflineQueue.shared.drain()
                async let sessions: Void = PendingSessionQueue.shared.drain()
                _ = await (workouts, sessions)
                await WatchBuild.refreshAndReportQueueStatus()
            }
        case .signedOut:
            lastRelayAt = Date()
            lastRejection = nil
            queuedRequest = false
            signOutLocally()
            Self.log.info("relay: phone signed out")
        case let .rejected(reason):
            // `notARelay` is not an auth payload at all — some other
            // application context. Recording it would only add noise.
            guard reason != .notARelay else { return }
            lastRelayAt = Date()
            lastRejection = reason
            syncing = false
            syncTimeout?.cancel()
            Self.log.error("relay rejected: \(reason.rawValue)")
        }
    }

    /// Clears this watch's copy of the session. Local only — the watch has no
    /// business ending the phone's session, and the old implementation called
    /// supabase-swift's globally-scoped `signOut`, which revoked every session
    /// the account had, phone included.
    @MainActor
    func signOutLocally() {
        WatchSessionStore.shared.clear()
        state = .signedOut
        syncing = false
        syncTimeout?.cancel()
    }

    /// Slow poll, only while the watch needs a token. watchOS suspends the app
    /// (and this task with it) when it isn't on screen, so this costs nothing
    /// in the background; its job is the case where the user is *looking* at
    /// the watch, the phone is in a pocket nearby, and nothing else would fire
    /// an event to retry on.
    private func startPolling() {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.needsToken else { return }
                    self.refreshState()
                }
            }
        }
    }
}

extension AuthManager: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            if self.needsToken { self.requestSessionFromPhone() }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.apply(applicationContext) }
    }

    /// Guaranteed-delivery variant. The phone answers a `requestSession` this
    /// way (#266): `updateApplicationContext` keeps only the latest payload and
    /// is the suspected reason a pull went undelivered, whereas a queued
    /// `transferUserInfo` is always delivered exactly once.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in self.apply(userInfo) }
    }

    /// The phone became reachable — if we still need a token this is the
    /// moment to (re)ask; an earlier attempt would have failed while it slept.
    func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in
            if self.needsToken { self.requestSessionFromPhone() }
        }
    }
}
