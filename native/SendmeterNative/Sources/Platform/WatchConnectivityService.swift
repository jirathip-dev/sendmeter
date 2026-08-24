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
    @Published public private(set) var quarantinedSyncCount: Int?
    @Published public private(set) var quarantinedStuckSyncCount: Int?
    @Published public private(set) var liveForce: WatchLiveForce?
    @Published public private(set) var pendingCompletions: [WatchWorkoutCompletion] = []

    public var onSessionRequested: (() async -> Void)?
    /// Returns true only after the phone has durably adopted the completion in
    /// its account-scoped cache. A false result leaves the persisted inbox row
    /// for the next auth/foreground attempt.
    public var onWorkoutCompletion: ((WatchWorkoutCompletion) async -> Bool)?
    /// Mirror producer (#626): the raw `liveWorkout` beat. AppModel owns the
    /// mirror cursor and reduces WC beats through the same run/sequence state
    /// machine as realtime rows, so the service stays a dumb transport.
    public var onLiveWorkoutMessage: (([String: Any]) -> Void)?

    private let session: WCSession?
    private var outgoingContext: [String: Any] = [:]
    private let completionStoreKey = "sendmeter.native.workout-completions"
    private let completionStoreLimit = 8
    private var completionInbox = WatchCompletionInbox()

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
        pendingCompletions = completionInbox.values
        session?.delegate = self
        session?.activate()
        refreshPairingState()
    }

    public func relaySession(_ authSession: Auth.Session?, guaranteed: Bool = false) {
        if let authSession {
            outgoingContext.merge([
                "event": "signedIn",
                "accessToken": authSession.accessToken,
                "expiresAt": authSession.expiresAt,
                "userId": authSession.user.id.uuidString,
                "ack_capable": true,
                "refreshToken": SessionRelay.legacyRefreshTokenSentinel
            ]) { _, new in new }
        } else {
            outgoingContext = ["event": "signedOut"]
        }
        transmitContext(guaranteed: guaranteed)
    }

    public func publishReadiness(_ metric: HealthMetric) {
        var result: [String: Any] = [
            "kind": "readinessResult",
            "date": metric.date
        ]
        // computed_at omitted when a kept score carries no fresh timestamp
        // (#661) — the watch's ReadinessSnapshot.computedAt is optional and
        // tolerates absence.
        if let computedAt = metric.computedAt {
            result["computed_at"] = computedAt.timeIntervalSince1970
        }
        if let readiness = metric.readiness { result["readiness"] = readiness }
        if let zone = metric.zone { result["zone"] = zone }
        outgoingContext.merge(result) { _, new in new }
        transmitContext(guaranteed: false)
    }

    /// Returns a snapshot without acknowledging anything. The caller must
    /// explicitly acknowledge each item after durable local adoption.
    public func storedCompletions() -> [WatchWorkoutCompletion] {
        completionInbox.values
    }

    @discardableResult
    public func acknowledgeStoredCompletion(_ completion: WatchWorkoutCompletion) -> Bool {
        guard completionInbox.acknowledge(completion) else { return false }
        pendingCompletions = completionInbox.values
        persistCompletions()
        return true
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

    private func transmitContext(guaranteed: Bool) {
        guard let session, session.activationState == .activated else { return }
        var payload = outgoingContext
        payload["relayId"] = UUID().uuidString
        payload["relayedAt"] = Date().timeIntervalSince1970
        try? session.updateApplicationContext(payload)
        if guaranteed { session.transferUserInfo(payload) }
    }

    private func handle(
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
            liveForce = parseLiveForce(message)
            replyHandler?([:])
        case "workoutCompleted":
            guard let completion = parseCompletion(message) else {
                replyHandler?([:])
                return
            }
            if completionInbox.retain(completion) {
                pendingCompletions = completionInbox.values
                persistCompletions()
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
        default:
            replyHandler?([:])
        }
    }

    private func recordWatchMetadata(_ message: [String: Any]) {
        let metadata = WatchMetadata.parse(message)
        if let version = metadata.version { watchVersion = version }
        if let build = metadata.build { watchBuild = build }
        if let pendingSync = metadata.pendingSync { pendingSyncCount = pendingSync }
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
        if let data = try? encoder.encode(pendingCompletions) {
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
