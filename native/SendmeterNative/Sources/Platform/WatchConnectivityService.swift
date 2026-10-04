import Auth
import Foundation
import SendLogWatchCore
import SendmeterCore
import WatchConnectivity

public struct WatchLiveForce: Equatable, Sendable {
    public let runID: UUID?
    public let sequence: Int?
    public let accountUserID: UUID?
    public let status: String
    public let kilograms: Double?
    public let peakKilograms: Double?
    public let elapsedMilliseconds: Double?
    public let sessionCount: Int?
    public let tag: String?
    public let side: TindeqSide
    public let updatedAt: Date
    public let spark: [TindeqSample]
}

@MainActor
public final class WatchConnectivityService: NSObject, ObservableObject {
    @Published public private(set) var activated = false
    @Published public private(set) var paired = false
    @Published public private(set) var appInstalled = false
    @Published public private(set) var reachable = false
    @Published public private(set) var watchVersion: String?
    @Published public private(set) var watchBuild: String?
    @Published public private(set) var pendingSyncCount: Int?
    @Published public private(set) var unscopedSyncCount: Int?
    @Published public private(set) var quarantinedSyncCount: Int?
    @Published public private(set) var quarantinedStuckSyncCount: Int?
    @Published public private(set) var liveForce: WatchLiveForce?
    @Published public private(set) var pendingCompletions: [WatchWorkoutCompletion] = []

    public var onSessionRequested: (() async -> Void)?
    /// Returns true only after the phone has durably adopted the completion in
    /// its account-scoped cache. A false result leaves the persisted inbox row
    /// for the next auth or foreground retry attempt.
    public var onWorkoutCompletion: ((WatchWorkoutCompletion) async -> Bool)?
    /// Mirror producer (#626): the raw `liveWorkout` beat. AppModel owns the
    /// mirror cursor and reduces WC beats through the same run/sequence state
    /// machine as realtime rows, so the service stays a dumb transport.
    public var onLiveWorkoutMessage: (([String: Any]) -> Void)?
    /// One watch-originated readiness request, executed on the phone (#913).
    /// AppModel owns the single-flight HealthKit pipeline; the service owns
    /// the transport and the typed answer.
    public var onReadinessRefresh: ((ReadinessRefreshRequest) async -> ReadinessRefreshOutcome)?

    private let session: WCSession?
    /// The last merged latest-state context this bridge would transmit. The
    /// auth relay and the readiness result are merged by the shared
    /// `ReadinessApplicationContext` rules, never one replacing the other.
    private var outgoingContext: [String: Any] = [:]
    private var applicationContext = ReadinessApplicationContext()
    /// Request identity, duplicate coalescing, and the account fence for
    /// watch-originated readiness asks (#913). Built on first use because it
    /// is created through `self` on the main actor.
    private lazy var readinessRequests = ReadinessWatchBridge()
    private let completionStoreKey = "sendmeter.native.workout-completions"
    private let completionStoreLimit = 8
    private var completionInbox = WatchCompletionInbox()
    /// The transport inbox is process-wide, but its visible slice is not. A
    /// stamped completion may wait through sign-out and be adopted when that
    /// same account returns; an unstamped legacy completion is retained only
    /// as bounded quarantine and is never exposed to an account.
    private var activeAccountUserID: UUID?

    public override init() {
        if WCSession.isSupported() {
            self.session = WCSession.default
        } else {
            self.session = nil
        }
        super.init()
        completionInbox = WatchCompletionInbox(
            limit: completionStoreLimit,
            values: loadStoredCompletions()
        )
        refreshPendingCompletions()
        session?.delegate = self
        session?.activate()
        refreshPairingState()
    }

    /// Switch the account-visible transport slice. This does not delete the
    /// durable inbox: valid stamped completions stay available to their owner
    /// after a normal sign-out/re-sign-in, while another account sees none.
    /// Live force and queue telemetry are transient and must not cross this
    /// boundary, so they are cleared before the next owner's messages arrive.
    public func setAccountScope(_ accountUserID: UUID?) {
        let changed = activeAccountUserID != accountUserID
        activeAccountUserID = accountUserID
        // Readiness flights and their replay cache are account-scoped too: an
        // answer produced for the previous owner is never replayed to the
        // replacement account (#913).
        readinessRequests.setAccountScope(accountUserID)
        if changed {
            clearAccountTransientState()
        } else {
            refreshPendingCompletions()
        }
    }

    /// Clear transient transport state when the AppModel advances its epoch,
    /// including a same-user rebootstrap. Durable owner-stamped completions
    /// remain in the inbox and are merely re-filtered.
    public func clearAccountTransientState() {
        liveForce = nil
        pendingSyncCount = nil
        unscopedSyncCount = nil
        quarantinedSyncCount = nil
        quarantinedStuckSyncCount = nil
        refreshPendingCompletions()
    }

    public func relaySession(_ authSession: Auth.Session?, guaranteed: Bool = false) {
        if let authSession {
            transmit(
                applicationContext.update([
                    "event": "signedIn",
                    "accessToken": authSession.accessToken,
                    "expiresAt": authSession.expiresAt,
                    "userId": authSession.user.id.uuidString,
                    "ack_capable": true,
                    "refreshToken": SessionRelay.legacyRefreshTokenSentinel
                ]),
                guaranteed: guaranteed
            )
        } else {
            transmit(
                applicationContext.update(["event": "signedOut"]),
                guaranteed: guaranteed
            )
        }
    }

    /// Pushes the phone's authoritative readiness as a typed
    /// `ReadinessRefreshResult` (#913).
    ///
    /// The pre-#913 push was a flat dictionary (`kind` + `date` + optional
    /// `computed_at`/`readiness`/`zone`) with no `requestId`, `status`, or
    /// account stamp, so the watch's result decoder rejected every one of
    /// them. A push has no watch request behind it, so the publication
    /// synthesizes the request identity and stamps the account that owns it.
    /// `freshness` is the recompute pass's own verdict: `.fresh` when it wrote
    /// a new score, `.cached` when it kept the existing one.
    public func publishReadiness(
        _ metric: HealthMetric,
        freshness: ReadinessFreshness
    ) {
        guard let activeAccountUserID else { return }
        publishReadiness(
            ReadinessPhonePublication.result(
                date: metric.date,
                readiness: metric.readiness,
                zone: metric.zone,
                computedAt: metric.computedAt.map(\.timeIntervalSince1970),
                freshness: freshness,
                accountUserId: activeAccountUserID
            )
        )
    }

    /// Stores one typed result as the latest-state application context (and,
    /// for a reachable ask, the caller has already answered the direct reply):
    /// a watch that was unreachable or cold when the phone produced the result
    /// still receives it on its next activation.
    private func publishReadiness(_ result: ReadinessRefreshResult) {
        transmit(applicationContext.update(result.message()), guaranteed: false)
    }

    /// Returns a snapshot without acknowledging anything. The caller must
    /// explicitly acknowledge each item after durable local adoption.
    public func storedCompletions() -> [WatchWorkoutCompletion] {
        completionInbox.values(for: activeAccountUserID)
    }

    @discardableResult
    public func acknowledgeStoredCompletion(_ completion: WatchWorkoutCompletion) -> Bool {
        guard let activeAccountUserID,
              completionInbox.acknowledge(
                  completion,
                  accountUserID: activeAccountUserID
              ) else { return false }
        refreshPendingCompletions()
        persistCompletions()
        return true
    }

    /// Destructive account deletion only. Normal sign-out deliberately leaves
    /// the owner's stamped completions in the durable inbox for re-sign-in;
    /// deletion removes exactly this owner's rows and leaves every other owner
    /// (and ownerless legacy quarantine) untouched.
    @discardableResult
    public func discardStoredCompletions(for accountUserID: UUID) -> Int {
        let removed = completionInbox.discard(accountUserID: accountUserID)
        guard removed > 0 else { return 0 }
        refreshPendingCompletions()
        persistCompletions()
        return removed
    }

    private func refreshPendingCompletions() {
        pendingCompletions = completionInbox.values(for: activeAccountUserID)
    }

    public func refreshPairingState() {
        guard let session else {
            activated = false
            paired = false
            appInstalled = false
            reachable = false
            return
        }
        activated = session.activationState == .activated
        paired = session.isPaired
        appInstalled = session.isWatchAppInstalled
        reachable = session.isReachable
    }

    /// The merged latest-state context this bridge would transmit. Internal so
    /// app-target tests can assert what the phone publishes: a simulator
    /// cannot pair a watch, so `updateApplicationContext` has no observable
    /// effect there.
    var pendingApplicationContext: [String: Any] { outgoingContext }

    /// Applies one logical update to the merged context and sends the result.
    /// An empty payload means this bridge knows neither an account nor a
    /// result yet; sending it would replace a previously persisted context
    /// with nothing.
    private func transmit(_ payload: [String: Any], guaranteed: Bool) {
        outgoingContext = payload
        guard !payload.isEmpty else { return }
        transmitContext(guaranteed: guaranteed)
    }

    private func transmitContext(guaranteed: Bool) {
        guard let session, session.activationState == .activated else { return }
        var payload = outgoingContext
        payload["relayId"] = UUID().uuidString
        payload["relayedAt"] = Date().timeIntervalSince1970
        do {
            try session.updateApplicationContext(payload)
        } catch {
            // #992: a failed watch transmit used to be a silent `try?`. Watch
            // delivery is device-only (a simulator cannot pair a watch), so a
            // persisted `.notice` line is the only trace a device transcript
            // can carry; the relay is best-effort and never surfaced.
            PersistedFailureLog.emit(
                PersistedFailureLog.line(
                    channel: .syncReplayFailure,
                    operation: "watch-transmit",
                    error: error,
                    surfaced: false
                )
            )
        }
        if guaranteed { session.transferUserInfo(payload) }
    }

    /// One watch→phone dictionary, dispatched by its `kind`. Internal rather
    /// than private so app-target tests can drive the real dispatch path; the
    /// WatchConnectivity delegate callbacks are its only production callers.
    func handle(
        _ message: [String: Any],
        replyHandler: (([String: Any]) -> Void)?
    ) {
        recordWatchMetadata(message)
        guard let kind = message["kind"] as? String else {
            replyHandler?([:])
            return
        }
        switch kind {
        case "requestSession":
            Task {
                await onSessionRequested?()
                replyHandler?([:])
            }
        case "liveWorkout":
            onLiveWorkoutMessage?(message)
            replyHandler?([:])
        case "liveForce":
            // Unlike a completion, a live force beat has no durable retry
            // value. An owner is therefore mandatory at this boundary; an
            // unstamped pre-#530 beat is rejected rather than being rendered
            // under whichever account happens to be active now.
            if let activeAccountUserID,
               let parsed = parseLiveForce(message),
               parsed.accountUserID == activeAccountUserID {
                liveForce = parsed
            }
            replyHandler?([:])
        case "workoutCompleted":
            guard let completion = parseCompletion(message) else {
                replyHandler?([:])
                return
            }
            if completionInbox.retain(completion) {
                refreshPendingCompletions()
                persistCompletions()
            }
            // A stamped completion is parked for its owner even when another
            // account is active. Legacy payloads have no ownership proof and
            // stay quarantined in the bounded inbox without an adoption task.
            guard let activeAccountUserID,
                  completion.accountUserID == activeAccountUserID else {
                replyHandler?([:])
                return
            }
            Task {
                let adopted = await onWorkoutCompletion?(completion) ?? false
                if adopted {
                    acknowledgeStoredCompletion(completion)
                }
                replyHandler?([:])
            }
        case "queueStatus":
            // The whole payload is the build/queue telemetry, which
            // `recordWatchMetadata` already captured from the raw message;
            // the watch sends with no reply handler, so an empty ack is the
            // full response.
            replyHandler?([:])
        case ReadinessRefreshRequest.kind:
            // #913: a watch-originated readiness ask (immediate `sendMessage`
            // or the queued `transferUserInfo` fallback — both land here).
            // The bridge owns request identity, duplicate coalescing, and the
            // account fence; the answer is a typed result, never an empty ack.
            let accountStamp = WatchMetadata.parse(message).accountUserID
            Task { @MainActor in
                let result = await readinessRequests.handle(
                    message,
                    accountStamp: accountStamp,
                    perform: { request in
                        guard let handler = self.onReadinessRefresh else {
                            return .unsupported()
                        }
                        return await handler(request)
                    }
                )
                guard let result else {
                    // Not a usable request (no request identity): the watch
                    // would have no in-flight ask to match any answer to.
                    replyHandler?([:])
                    return
                }
                // A reachable ask is answered directly here; the typed result
                // is also the latest application context, so a cold or
                // unreachable watch recovers it on its next activation.
                replyHandler?(result.message())
                publishReadiness(result)
            }
        default:
            replyHandler?([:])
        }
    }

    private func recordWatchMetadata(_ message: [String: Any]) {
        let metadata = WatchMetadata.parse(message)
        if let version = metadata.version { watchVersion = version }
        if let build = metadata.build { watchBuild = build }
        // Queue depth is account data despite being observability metadata.
        // Only a stamped queue report for the active account may update the
        // badge; older unstamped reports are ignored rather than attributed
        // to a newly signed-in user.
        guard let activeAccountUserID,
              metadata.accountUserID == activeAccountUserID else {
            return
        }
        if let pendingSync = metadata.pendingSync { pendingSyncCount = pendingSync }
        if let unscopedSync = metadata.unscopedSync { unscopedSyncCount = unscopedSync }
        if let quarantinedSync = metadata.quarantinedSync { quarantinedSyncCount = quarantinedSync }
        if let quarantinedStuckSync = metadata.quarantinedStuckSync {
            quarantinedStuckSyncCount = quarantinedStuckSync
        }
    }

    private func parseLiveForce(_ message: [String: Any]) -> WatchLiveForce? {
        guard let status = message["status"] as? String,
              let updated = number(message["updated_at"]) else { return nil }
        let spark = (message["spark"] as? [[Any]] ?? []).compactMap { pair -> TindeqSample? in
            guard pair.count >= 2,
                  let t = number(pair[0]),
                  let kg = number(pair[1]) else { return nil }
            return TindeqSample(milliseconds: t, kilograms: kg)
        }
        return WatchLiveForce(
            runID: uuid(message["run_id"]),
            sequence: number(message["sequence"]).map(Int.init),
            accountUserID: uuid(message["account_user_id"]),
            status: status,
            kilograms: number(message["kg"]),
            peakKilograms: number(message["peak_kg"]),
            elapsedMilliseconds: number(message["elapsed_ms"]),
            sessionCount: number(message["session_count"]).map(Int.init),
            tag: message["tag"] as? String,
            side: TindeqSide(rawValue: message["side"] as? String ?? "") ?? .unspecified,
            updatedAt: Date(timeIntervalSince1970: updated),
            spark: spark
        )
    }

    private func parseCompletion(_ message: [String: Any]) -> WatchWorkoutCompletion? {
        guard let sessionID = uuid(message["session_id"]),
              let workoutID = uuid(message["workout_id"]) else { return nil }
        return WatchWorkoutCompletion(
            sessionID: sessionID,
            workoutID: workoutID,
            runID: uuid(message["run_id"]),
            sequence: number(message["sequence"]).map(Int.init),
            accountUserID: uuid(message["account_user_id"]),
            startedAt: number(message["started_at"]).map(Date.init(timeIntervalSince1970:)),
            endedAt: number(message["ended_at"]).map(Date.init(timeIntervalSince1970:)),
            attemptCount: number(message["attempt_count"]).map(Int.init) ?? 0,
            durationMinutes: number(message["duration_min"]).map(Int.init) ?? 1,
            rpe: number(message["rpe"]) ?? 6,
            phase: PhaseID(rawValue: message["phase"] as? String ?? "") ?? .capacity,
            type: message["type"] as? String ?? "auto",
            typeLabel: message["type_label"] as? String ?? "Apple Watch",
            note: message["note"] as? String ?? "",
            rpeConfirmed: bool(message["rpe_confirmed"]) ?? false,
            receivedAt: Date()
        )
    }

    private func persistCompletions() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(completionInbox.values) {
            UserDefaults.standard.set(data, forKey: completionStoreKey)
        }
    }

    private func loadStoredCompletions() -> [WatchWorkoutCompletion] {
        guard let data = UserDefaults.standard.data(forKey: completionStoreKey) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([WatchWorkoutCompletion].self, from: data)) ?? []
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private func uuid(_ value: Any?) -> UUID? {
        if let value = value as? UUID { return value }
        if let value = value as? String { return UUID(uuidString: value) }
        return nil
    }
}

extension WatchConnectivityService: WCSessionDelegate {
    nonisolated public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            refreshPairingState()
            if activationState == .activated { transmitContext(guaranteed: false) }
        }
    }

    nonisolated public func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated public func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in refreshPairingState() }
    }

    nonisolated public func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in refreshPairingState() }
    }

    nonisolated public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in handle(message, replyHandler: nil) }
    }

    nonisolated public func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in handle(message, replyHandler: replyHandler) }
    }

    nonisolated public func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        Task { @MainActor in handle(userInfo, replyHandler: nil) }
    }
}
