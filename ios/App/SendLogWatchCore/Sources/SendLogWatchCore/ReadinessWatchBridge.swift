import Foundation

// MARK: - Issue #913 — the phone side of a watch-originated readiness refresh

/// The typed answer one phone-side readiness pass produced, before the
/// request's identity and timestamps are attached.
///
/// The phone's transport (WatchConnectivity) owns dictionaries, not policy:
/// this value is what an executor — `AppModel`'s single-flight HealthKit
/// pipeline — returns, and `ReadinessWatchBridge` turns it into the
/// `ReadinessRefreshResult` the watch's `ReadinessManager` renders. Every
/// non-success case is deliberately typed and user-facing: the pre-#913 phone
/// answered with an empty dictionary, which left the watch with no state, no
/// message, and no way to tell "done" from "broken".
public struct ReadinessRefreshOutcome: Equatable, Sendable {
    public let status: ReadinessRefreshStatus
    public let freshness: ReadinessFreshness
    public let snapshot: ReadinessSnapshot?
    public let errorCode: String?
    public let errorMessage: String?

    public init(
        status: ReadinessRefreshStatus,
        freshness: ReadinessFreshness,
        snapshot: ReadinessSnapshot? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) {
        self.status = status
        self.freshness = freshness
        self.snapshot = snapshot
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }

    /// The pass ran. `freshness` is the pass's own verdict — `.fresh` when it
    /// wrote a new score, `.cached` when it deliberately kept the existing one
    /// (#109 freeze, no prior scored reading, or a joined flight). A nil
    /// snapshot is honest: the phone has nothing to show and the watch keeps
    /// whatever it already displays.
    public static func success(
        freshness: ReadinessFreshness,
        snapshot: ReadinessSnapshot?
    ) -> Self {
        Self(
            status: .success,
            freshness: freshness,
            snapshot: snapshot
        )
    }

    /// The phone holds no usable session for this request — signed out, or a
    /// watch stamp that does not match the phone's current account. The watch
    /// cannot fix this from its wrist, so the copy names the phone action.
    public static func authRequired() -> Self {
        Self(
            status: .authRequired,
            freshness: .offline,
            errorCode: "auth-required",
            errorMessage: ReadinessRefreshCopy.authRequired
        )
    }

    /// Apple Health was never authorized on the phone (or its automatic
    /// readiness pass is otherwise unavailable): the same actionable outcome
    /// as `authRequired`, with a distinct diagnostic code.
    public static func healthUnavailable() -> Self {
        Self(
            status: .authRequired,
            freshness: .offline,
            errorCode: "health-required",
            errorMessage: ReadinessRefreshCopy.authRequired
        )
    }

    public static func cancelled() -> Self {
        Self(
            status: .cancelled,
            freshness: .offline,
            errorCode: "cancelled",
            errorMessage: ReadinessRefreshCopy.cancelled
        )
    }

    public static func failed() -> Self {
        Self(
            status: .failed,
            freshness: .offline,
            errorCode: "sync-failed",
            errorMessage: ReadinessRefreshCopy.failed
        )
    }

    /// This phone build has no readiness executor installed at all.
    public static func unsupported() -> Self {
        Self(
            status: .unsupported,
            freshness: .unknown,
            errorCode: "unsupported",
            errorMessage: ReadinessRefreshCopy.unsupported
        )
    }
}

/// The copy the watch renders verbatim for a phone-produced outcome
/// (`ReadinessManager`'s documented contract). Kept next to the outcomes that
/// use it so the phone can never leak `error.localizedDescription` into
/// readiness errors.
public enum ReadinessRefreshCopy {
    public static let authRequired = "Open Sendmeter on your iPhone to refresh Health."
    public static let cancelled = "The readiness refresh was cancelled."
    public static let failed = "The iPhone could not refresh readiness."
    public static let unsupported = "This iPhone cannot refresh readiness yet."
}

/// The phone-side owner of watch-originated readiness requests (#913).
///
/// The transport stays a dumb transport (matching the live-workout mirror
/// rule): it hands each `readinessRefresh` dictionary plus the watch's owner
/// stamp to this bridge, and the bridge owns request identity, duplicate
/// coalescing, the account fence, and the typed answer the watch renders. The
/// actual HealthKit + Supabase pass stays injected as `perform`, so the
/// phone's existing single-flight pipeline remains the only writer and this
/// type is testable on the host without WatchConnectivity.
@MainActor
public final class ReadinessWatchBridge {
    public typealias Performer = @MainActor (ReadinessRefreshRequest) async -> ReadinessRefreshOutcome

    /// How many answered requests stay replayable. The watch can send the same
    /// request twice — a reachable `sendMessage` plus the guaranteed
    /// `transferUserInfo` fallback, or a retry after its own timeout — and a
    /// replay must be answered without a second HealthKit pass.
    public static let completedRequestLimit = 32

    private var epoch = ReadinessAccountEpoch()
    private var inFlight: [String: Task<ReadinessRefreshResult, Never>] = [:]
    private var completed: [String: ReadinessRefreshResult] = [:]
    private var completedOrder: [String] = []

    public init() {}

    /// The account whose requests may run. Results and flights are
    /// account-scoped: a sign-out or an account switch discards the previous
    /// owner's answers, so a late duplicate can never be replayed to — or
    /// executed for — the replacement account.
    public func setAccountScope(_ accountUserId: UUID?) {
        let previousEpoch = epoch.currentEpoch
        if let accountUserId {
            epoch.setSession(userId: accountUserId)
        } else {
            epoch.clearSession()
        }
        guard epoch.currentEpoch != previousEpoch else { return }
        completed.removeAll()
        completedOrder.removeAll()
    }

    /// Answers one raw watch→phone dictionary.
    ///
    /// `nil` means "not a readiness request": another kind, or a message
    /// carrying no usable request identity. The transport keeps routing those
    /// itself — this bridge never invents a request ID, because the watch
    /// matches a result to its in-flight request by that ID alone.
    public func handle(
        _ message: [String: Any],
        accountStamp: UUID?,
        perform: @escaping Performer
    ) async -> ReadinessRefreshResult? {
        guard message["kind"] as? String == ReadinessRefreshRequest.kind,
              let request = ReadinessRefreshRequest(message: message)
        else { return nil }

        let receivedAt = Date().timeIntervalSince1970
        // Signed out: no pass runs and no cached score may answer. The watch
        // still gets a typed, actionable result instead of an empty ack; an
        // unstamped answer is accepted there only for the exact request it
        // names, which is precisely this reply.
        guard let currentAccountUserId = epoch.currentUserId, !epoch.isSignedOut else {
            return ReadinessRefreshResult(
                request: request,
                startedAt: receivedAt,
                status: .authRequired,
                freshness: .offline,
                errorCode: "auth-required",
                errorMessage: ReadinessRefreshCopy.authRequired
            )
        }
        // The watch stamps its owner on every message. A request owned by
        // another account is never executed under this one, and an unstamped
        // legacy request has no ownership proof at all.
        guard accountStamp == currentAccountUserId else {
            return ReadinessRefreshResult(
                request: request,
                startedAt: receivedAt,
                status: .authRequired,
                freshness: .offline,
                accountUserId: currentAccountUserId,
                errorCode: "auth-required",
                errorMessage: ReadinessRefreshCopy.authRequired
            )
        }

        if let answered = completed[request.requestId] { return answered }
        // A duplicate that arrives while the first ask is still running joins
        // that flight: one pass, one result, one timestamp.
        if let flight = inFlight[request.requestId] { return await flight.value }

        let capturedEpoch = epoch.currentEpoch
        let flight = Task { @MainActor [weak self] in
            guard let self else {
                return ReadinessRefreshResult(
                    request: request,
                    startedAt: receivedAt,
                    status: .failed,
                    freshness: .offline,
                    accountUserId: currentAccountUserId,
                    errorCode: "sync-failed",
                    errorMessage: ReadinessRefreshCopy.failed
                )
            }
            return await self.run(
                request,
                startedAt: receivedAt,
                capturedEpoch: capturedEpoch,
                perform: perform
            )
        }
        inFlight[request.requestId] = flight
        return await flight.value
    }

    /// Runs one pass and records its typed answer. Kept separate from `handle`
    /// so the account fence and the replay cache are applied exactly once, by
    /// the flight that actually performed the work.
    private func run(
        _ request: ReadinessRefreshRequest,
        startedAt: TimeInterval,
        capturedEpoch: UInt64,
        perform: Performer
    ) async -> ReadinessRefreshResult {
        let outcome = await perform(request)
        let completedAt = Date().timeIntervalSince1970
        // The same epoch fence the watch applies to a late reply applies here:
        // a pass that crossed a sign-out or an account switch is not the new
        // account's answer. A fenced result is answered (the requester is
        // still waiting) but never remembered — a replay must not hand the
        // previous owner's answer to the replacement account.
        guard ReadinessRefreshDeliveryGate.allows(
            capturedEpoch: capturedEpoch,
            currentEpoch: epoch.currentEpoch,
            isSignedOut: epoch.isSignedOut
        ) else {
            let fenced = ReadinessRefreshResult(
                request: request,
                startedAt: startedAt,
                completedAt: completedAt,
                status: .cancelled,
                freshness: .offline,
                accountUserId: epoch.currentUserId,
                errorCode: "cancelled",
                errorMessage: ReadinessRefreshCopy.cancelled
            )
            inFlight[request.requestId] = nil
            return fenced
        }
        let result = ReadinessRefreshResult(
            request: request,
            startedAt: startedAt,
            completedAt: completedAt,
            status: outcome.status,
            freshness: outcome.freshness,
            snapshot: outcome.snapshot,
            accountUserId: epoch.currentUserId,
            errorCode: outcome.errorCode,
            errorMessage: outcome.errorMessage
        )
        inFlight[request.requestId] = nil
        remember(result)
        return result
    }

    private func remember(_ result: ReadinessRefreshResult) {
        if completed[result.requestId] == nil {
            completedOrder.append(result.requestId)
        }
        completed[result.requestId] = result
        while completedOrder.count > Self.completedRequestLimit {
            let evicted = completedOrder.removeFirst()
            completed[evicted] = nil
        }
    }
}

/// A phone-initiated readiness publication: the phone's own recompute pass
/// pushing its current reading, with no watch request behind it.
public enum ReadinessPhonePublication {
    /// Builds the typed result the phone publishes as latest application
    /// context after its own pass.
    ///
    /// The synthesized request identity is what makes the publication decode
    /// on the watch at all: the pre-#913 push was a flat dictionary with no
    /// `requestId`/`status`/account stamp, so every phone push was dropped by
    /// the watch's result decoder and by its account-scoped context merge.
    /// `reason` is `statusRefresh` because every phone push is an automatic
    /// sync, never a wearer-requested refresh.
    public static func result(
        date: String,
        readiness: Int?,
        zone: String?,
        computedAt: TimeInterval?,
        freshness: ReadinessFreshness,
        accountUserId: UUID,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> ReadinessRefreshResult {
        let request = ReadinessRefreshRequest(
            reason: .statusRefresh,
            sentAt: now,
            schemaVersion: ReadinessRefreshRequest.currentSchemaVersion
        )
        return ReadinessRefreshResult(
            request: request,
            startedAt: now,
            completedAt: now,
            status: .success,
            freshness: freshness,
            snapshot: ReadinessSnapshot(
                date: date,
                readiness: readiness,
                zone: zone,
                computedAt: computedAt
            ),
            accountUserId: accountUserId
        )
    }
}
