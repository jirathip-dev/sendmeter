import Foundation
import HealthKit
import SendLogHealthCore
import struct SendLogWatchCore.AccessTokenClaims
import struct SendLogWatchCore.ReadinessSnapshot
import struct SendLogWatchCore.ReadinessRefreshRequest
import struct SendLogWatchCore.ReadinessRefreshResult
import struct SendLogWatchCore.ReadinessRefreshCoalescer
import struct SendLogWatchCore.ReadinessTaskGate
import struct SendLogWatchCore.ReadinessAccountEpoch
import struct SendLogWatchCore.ReadinessSessionIdentity
import enum SendLogWatchCore.ReadinessRefreshDeliveryGate
import enum SendLogWatchCore.ReadinessRefreshReason
import enum SendLogWatchCore.ReadinessRefreshStatus
import enum SendLogWatchCore.ReadinessFreshness
import enum SendLogWatchCore.ReadinessRefreshRetryPolicy
import SendLogAuthBridge

/// Snake_case rows matching PostgREST (mirror the watch's Models.swift so the
/// health_metrics upsert shape is identical). user_id is omitted — the DB
/// defaults it to auth.uid().
private struct HealthMetricsUpsert: Codable {
    var date: String
    var hrvSdnnMs: Double?
    var restingHr: Double?
    var sleepHours: Double?
    var sleepDeepHours: Double?
    var sleepRemHours: Double?
    var bodyMassKg: Double?
    var respRateBpm: Double?
    // Optional (not just "nullable in the DB"): when ReadinessWritePolicy
    // withholds today's score, these three are left OUT of the upsert
    // payload entirely (Codable's synthesized encodeIfPresent for Optional
    // properties omits nil keys rather than sending `null`), so Postgres'
    // ON CONFLICT DO UPDATE only touches the biometric columns above and
    // leaves the existing readiness/zone/computed_at untouched.
    var readiness: Int?
    var zone: String?
    var computedAt: Date?

    enum CodingKeys: String, CodingKey {
        case date, readiness, zone
        case hrvSdnnMs = "hrv_sdnn_ms"
        case restingHr = "resting_hr"
        case sleepHours = "sleep_hours"
        case sleepDeepHours = "sleep_deep_hours"
        case sleepRemHours = "sleep_rem_hours"
        case bodyMassKg = "body_mass_kg"
        case respRateBpm = "resp_rate_bpm"
        case computedAt = "computed_at"
    }
}

private struct SessionLoadRow: Codable {
    var date: String
    var load: Int?
}

/// Just enough of today's existing row to decide whether an automatic sync
/// may overwrite its readiness — see `ReadinessWritePolicy`. Deliberately
/// decodes `date` as a String (the DB `date` column, not a `timestamptz`)
/// rather than `computed_at` as a `Date` — a `timestamptz` decode mismatch
/// here must not be able to break this lookup (see the fail-open handling
/// in `syncNow`), and the policy only needs presence + the row's own date
/// for its self-defense check, not a timestamp.
private struct ExistingReadinessRow: Codable {
    var date: String
    var readiness: Int?
    var zone: String?
}

/// #487 (F4, review finding 1): thrown when `clearAndResync` writes zero rows
/// after already hard-deleting every existing one. HealthKit does not throw
/// on denied READ authorization — `authorizationStatus(for:)` only reflects
/// share/write authorization; for read-only types (everything this app
/// requests) it is documented to stay `.notDetermined` regardless of what the
/// user chose, specifically so an app can't infer denial from behavior. That
/// makes "zero rows back" genuinely ambiguous between "access denied" and
/// "no HealthKit data in this window" — this type does not (cannot, via
/// public API) tell those apart. What it does do is stop the dangerous
/// silent case: before this, an empty rebuild after a destructive delete
/// returned normally and `resyncHealthHistory()` reported `{ok: true}`. Now
/// it throws, `Plugin.swift` rejects the call, and `resyncHealthHistory()`
/// reports `{ok: false}` — the safe-direction trade is a false "failed" in
/// the rare true-no-data case, never a false "succeeded" after data loss.
struct HealthResyncFoundNoDataError: Error, LocalizedError {
    var errorDescription: String? {
        "Resync found no Health data to rebuild from — Health access may be denied, or your history is genuinely empty for this window."
    }
}

/// A short-lived bearer token can expire while a watch is asleep. The native
/// iPhone path requests a fresh access-token relay from the WebView owner and
/// retries once; if the WebView is suspended, the watch receives this stable
/// category rather than a raw Supabase response or credential.
struct HealthAuthRequiredError: Error, LocalizedError {
    var errorDescription: String? {
        "The phone needs to be opened to refresh its Health session."
    }
}

private struct HealthSyncUnavailableError: Error, LocalizedError {
    var errorDescription: String? {
        "The native readiness service is unavailable."
    }
}

private struct HealthSyncOutcome: Sendable {
    let snapshot: ReadinessSnapshot
    let freshness: ReadinessFreshness
}

/// Immutable credentials for one native readiness flight. Supabase's client
/// is created from this bearer at each query boundary; it never consults the
/// mutable Keychain store while an old request is in flight. The identity is
/// kept separately from the bearer so a same-user token refresh can preserve
/// account-scoped coalescing while a real account transition invalidates it.
private struct HealthSessionBinding: Sendable, Equatable {
    let identity: ReadinessSessionIdentity
    let accessToken: String

    var accountIdentity: ReadinessSessionIdentity {
        ReadinessSessionIdentity(
            accountEpoch: identity.accountEpoch,
            tokenGeneration: 0,
            userId: identity.userId
        )
    }
}

private struct RequestTaskEntry {
    let identity: ReadinessSessionIdentity
    let task: Task<ReadinessRefreshResult, Never>
}

private struct RequestResultEntry {
    let identity: ReadinessSessionIdentity
    let result: ReadinessRefreshResult
}

/// Orchestrates iPhone-side readiness: read HealthKit → ACWR from the user's
/// sessions → RecoveryEngine → upsert health_metrics. The iPhone is the sole
/// writer (the watch only reads the score back for display), so there's no
/// two-writer coordination to worry about.
final class HealthSyncManager {
    static let shared = HealthSyncManager()

    private let reader = HealthKitReader()
    private let tunables = RecoveryTunables.default
    private var observerStarted = false

    // These locks protect only coordination metadata. HealthKit and
    // PostgREST work remain outside the locks, and the flight state is marked
    // before the first await so foreground/background/watch storms cannot
    // start parallel writers.
    private let flightLock = NSLock()
    private var flightState = ReadinessRefreshCoalescer()
    private var flightOwner = ReadinessTaskGate()
    private var inFlight: Task<HealthSyncOutcome, Error>?
    private var activeFlightBinding: HealthSessionBinding?
    private var queuedFlightBinding: HealthSessionBinding?

    private let requestLock = NSLock()
    private var requestTasks: [String: RequestTaskEntry] = [:]
    private var requestResults: [String: RequestResultEntry] = [:]
    private var resultHandler: ((ReadinessRefreshResult) -> Void)?
    private let latestResultKey = "sendmeter.health.latestReadinessResult"
    private let latestResultUserKey = "sendmeter.health.latestReadinessUser"
    private let sessionLock = NSLock()
    private var accountEpoch = ReadinessAccountEpoch()
    /// Token rotations for the same subject keep `accountEpoch` stable. The
    /// generation still makes a request's captured bearer auditable without
    /// treating an ordinary refresh as a new account.
    private var sessionTokenGeneration: UInt64 = 0

    private init() {
        // A background HealthKit wake can construct this singleton before the
        // WebView has rehydrated. Restore the account epoch from the native
        // access-token subject first, so a cold readiness result cannot be
        // published as an unscoped/signed-out account. A durable signed-out
        // marker wins over a stale Keychain token and clears it before any
        // request can capture credentials.
        if HealthSessionStore.shared.isSignedOut {
            HealthSessionStore.shared.clear()
        } else if let persisted = HealthSessionStore.shared.accessToken,
                  let userId = AccessTokenClaims(jwt: persisted)?.userId {
            _ = accountEpoch.restoreSession(userId: userId)
            sessionTokenGeneration = 1
        } else if HealthSessionStore.shared.accessToken != nil {
            HealthSessionStore.shared.clear()
        }
        // Results persisted by older builds had no account stamp. Do not
        // expose such an unscoped snapshot after a cold account transition.
        let persistedUser = UserDefaults.standard.string(forKey: latestResultUserKey)
        if persistedUser == nil || persistedUser != accountEpoch.currentUserId?.uuidString {
            UserDefaults.standard.removeObject(forKey: latestResultKey)
            UserDefaults.standard.removeObject(forKey: latestResultUserKey)
        }
    }

    func requestAuthorization() async throws {
        try await reader.requestAuthorization()
    }

    /// Stores the relayed access token (#265). Purely local — no network call
    /// at all, where `auth.setSession` used to spend a `GET /user` on every
    /// relay (and refresh outright if the token it was handed had expired).
    func setSession(accessToken: String) {
        // A rotated access token for the same JWT subject is not an account
        // transition. A different/unknown subject starts a new epoch and
        // evicts all old request/result state before IDs can be reused.
        let userId = AccessTokenClaims(jwt: accessToken)?.userId
        sessionLock.lock()
        let change = accountEpoch.setSession(userId: userId)
        if HealthSessionStore.shared.accessToken != accessToken {
            sessionTokenGeneration &+= 1
        }
        if change == .accountChanged {
            // Keep the epoch transition, old-flight invalidation, and bearer
            // replacement in one critical section. A replacement request
            // cannot observe the new account while an old flight still owns
            // the coalescer.
            invalidateFlight()
            clearRequestState()
        }
        HealthSessionStore.shared.store(accessToken)
        sessionLock.unlock()
        if change == .accountChanged {
            UserDefaults.standard.removeObject(forKey: latestResultKey)
            UserDefaults.standard.removeObject(forKey: latestResultUserKey)
        }
    }

    /// Forgets this client's stored token — called when the phone signs out,
    /// so a later background HealthKit wake can't keep writing as that user.
    /// Local only: the WebView's own signOut has already revoked the session
    /// server-side, and this client has no session of its own to end.
    func clearSession() {
        sessionLock.lock()
        accountEpoch.clearSession()
        sessionTokenGeneration &+= 1
        invalidateFlight()
        clearRequestState()
        HealthSessionStore.shared.clear()
        sessionLock.unlock()
        UserDefaults.standard.removeObject(forKey: latestResultKey)
        UserDefaults.standard.removeObject(forKey: latestResultUserKey)
    }

    /// Installs the request side of the narrow auth-bridge seam. This is
    /// called by the plugin during native load, so delivery never depends on
    /// a JavaScript listener or a live WebView.
    func installReadinessBridge() {
        SendLogReadinessBridge.registerRequestHandler { [weak self] request, replyHandler in
            Task { [weak self] in
                guard let self else { return }
                let requestBinding = self.captureSessionBinding()
                let result = await self.handleWatchRequest(
                    request,
                    binding: requestBinding
                )
                // The account-binding check and both direct/context
                // publications are one session-locked decision. A
                // clear/new-account call that wins first suppresses the old
                // snapshot entirely; it is not safe to send a terminal
                // success reply from the old account.
                self.deliverWatchResult(
                    result,
                    binding: requestBinding,
                    replyHandler: replyHandler
                )
            }
        }
    }

    /// The phone UI uses this event to re-read its normal repository-backed
    /// dashboard. The result itself is intentionally compact and is also
    /// persisted so a UI opened after a background wake can inspect it.
    func setReadinessResultHandler(_ handler: @escaping (ReadinessRefreshResult) -> Void) {
        requestLock.lock()
        resultHandler = handler
        requestLock.unlock()
    }

    func latestReadinessResult() -> ReadinessRefreshResult? {
        // Read the in-memory and durable copies under the same session lock
        // that account transitions use. A phone UI re-opening during a
        // sign-out/account switch must not observe the previous account's
        // compact result between clearing the request cache and removing its
        // persisted envelope.
        sessionLock.lock()
        guard let currentUser = accountEpoch.currentUserId?.uuidString,
              !accountEpoch.isSignedOut else {
            sessionLock.unlock()
            return nil
        }
        requestLock.lock()
        if let latest = requestResults.values.max(by: {
            $0.result.completedAt < $1.result.completedAt
        }) {
            requestLock.unlock()
            sessionLock.unlock()
            return latest.result
        }
        requestLock.unlock()
        guard UserDefaults.standard.string(forKey: latestResultUserKey) == currentUser else {
            sessionLock.unlock()
            return nil
        }
        guard let data = UserDefaults.standard.data(forKey: latestResultKey) else {
            sessionLock.unlock()
            return nil
        }
        let result = try? JSONDecoder().decode(ReadinessRefreshResult.self, from: data)
        sessionLock.unlock()
        return result
    }

    /// Read HealthKit, upsert today's biometrics, and — subject to
    /// `ReadinessWritePolicy` — (re)compute and upsert readiness/zone.
    ///
    /// `trigger` is required, not defaulted: `.manual` (an explicit
    /// user-refresh gesture — the app has none yet, reserved for a future
    /// pull-to-refresh) is always authoritative; `.automatic` (every
    /// existing call site today — cold-launch and foreground re-syncs are
    /// both app-driven, not user-initiated) defers to the policy. #109:
    /// an automatic sync can fire repeatedly through the day (background
    /// delivery, plus every app foreground), and several inputs — resting
    /// HR especially — aren't guaranteed finalized in the morning, so once
    /// today has a readiness, an automatic sync after noon leaves it alone.
    ///
    /// The biometric columns (hrv/rhr/sleep/resp/mass) are NOT gated by the
    /// policy and are always re-read + re-upserted on every call, locked or
    /// not — a metric HealthKit only finishes writing mid-afternoon (sleep
    /// stages are a common case) must still land in the row for that day.
    /// Readiness is the frozen morning score; the biometric columns stay
    /// current through the day.
    func syncNow(trigger: SyncTrigger) async throws -> ReadinessSnapshot {
        let outcome = try await syncOutcomeNow(trigger: trigger)
        return outcome.snapshot
    }

    private func syncOutcomeNow(
        trigger: SyncTrigger,
        requestedBinding: HealthSessionBinding? = nil
    ) async throws -> HealthSyncOutcome {
        let reason: ReadinessRefreshReason = trigger == .manual ? .statusRefresh : .foreground
        let task: Task<HealthSyncOutcome, Error>

        // Session transitions use the same lock order (session → flight), so
        // a request can never capture a bearer and then join a flight that a
        // real account transition is in the process of invalidating.
        sessionLock.lock()
        guard let binding = requestedBinding ?? captureSessionBindingLocked(),
              let current = accountEpoch.identity(tokenGeneration: sessionTokenGeneration),
              !accountEpoch.isSignedOut,
              !HealthSessionStore.shared.isSignedOut,
              current.accountEpoch == binding.identity.accountEpoch,
              current.userId == binding.identity.userId else {
            sessionLock.unlock()
            throw HealthAuthRequiredError()
        }
        flightLock.lock()
        switch flightState.request(reason: reason) {
        case .start:
            let owner = flightOwner.begin()
            activeFlightBinding = binding
            queuedFlightBinding = nil
            // Set `inFlight` before creating the task's first await. A second
            // foreground callback therefore joins this exact task instead of
            // launching another HealthKit read/upsert pair.
            let newTask = Task { [weak self] in
                guard let self else { throw HealthSyncUnavailableError() }
                return try await self.runFlight(
                    trigger: trigger,
                    owner: owner,
                    binding: binding
                )
            }
            inFlight = newTask
            task = newTask
        case .queued:
            // `flightState` cannot queue without an owner task, but keep the
            // fallback explicit so an unexpected teardown fails safely rather
            // than force-unwrapping an optional from a background callback.
            guard let existing = inFlight,
                  let activeBinding = activeFlightBinding else {
                flightOwner.invalidate()
                flightState.cancel()
                activeFlightBinding = nil
                flightLock.unlock()
                sessionLock.unlock()
                throw HealthSyncUnavailableError()
            }
            if activeBinding.accountIdentity == binding.accountIdentity {
                // Same-account token rotations are coalesced into the one
                // authorized follow-up, but the follow-up carries the new
                // request's immutable bearer. The old pass never consults the
                // mutable Keychain store and the new request never executes
                // under an old account/client binding.
                if activeBinding.identity != binding.identity {
                    queuedFlightBinding = binding
                }
                task = existing
            } else {
                // Defensive recovery for a transition that raced an older
                // task's cancellation observation. Never let a new account
                // join that stale flight; replace its coalescer owner first.
                existing.cancel()
                flightOwner.invalidate()
                flightState.cancel()
                activeFlightBinding = nil
                queuedFlightBinding = nil
                guard flightState.request(reason: reason) == .start else {
                    flightLock.unlock()
                    sessionLock.unlock()
                    throw HealthSyncUnavailableError()
                }
                let owner = flightOwner.begin()
                activeFlightBinding = binding
                let newTask = Task { [weak self] in
                    guard let self else { throw HealthSyncUnavailableError() }
                    return try await self.runFlight(
                        trigger: trigger,
                        owner: owner,
                        binding: binding
                    )
                }
                inFlight = newTask
                task = newTask
            }
        }
        flightLock.unlock()
        sessionLock.unlock()

        let outcome = try await task.value
        return outcome
    }

    /// One coalesced flight may contain at most one follow-up pass. Auth
    /// expiry gets one fresh-token relay/retry inside that flight; it never
    /// hands a refresh token to the native side.
    private func runFlight(
        trigger: SyncTrigger,
        owner: ReadinessTaskGate.Token,
        binding initialBinding: HealthSessionBinding
    ) async throws -> HealthSyncOutcome {
        var lastOutcome: HealthSyncOutcome?
        var lastError: Error?
        var authRelayAttempted = false
        var nextTrigger = trigger
        var binding = initialBinding

        while true {
            if Task.isCancelled || !isCurrentFlight(owner) {
                abandonFlight(owner)
                throw CancellationError()
            }
            do {
                lastOutcome = try await performPass(
                    trigger: nextTrigger,
                    binding: binding
                )
                lastError = nil
            } catch {
                if error is CancellationError || Task.isCancelled || !isCurrentFlight(owner) {
                    abandonFlight(owner)
                    throw CancellationError()
                }
                if ReadinessRefreshRetryPolicy.shouldRelayAuth(
                    errorDescription: String(describing: error),
                    alreadyRetried: authRelayAttempted
                ) {
                    authRelayAttempted = true
                    do {
                        try await waitForFreshAccessToken(previous: binding)
                        guard let refreshed = captureSessionBinding(),
                              refreshed.identity.accountEpoch == binding.identity.accountEpoch,
                              refreshed.identity.userId == binding.identity.userId
                        else {
                            throw CancellationError()
                        }
                        binding = refreshed
                        lastOutcome = try await performPass(
                            trigger: nextTrigger,
                            binding: binding
                        )
                        lastError = nil
                    } catch {
                        lastOutcome = nil
                        lastError = error
                    }
                } else {
                    lastOutcome = nil
                    lastError = error
                }
            }

            if Task.isCancelled || !isCurrentFlight(owner) {
                abandonFlight(owner)
                throw CancellationError()
            }

            flightLock.lock()
            guard flightOwner.isCurrent(owner) else {
                flightLock.unlock()
                throw CancellationError()
            }
            let completion = flightState.complete()
            switch completion {
            case .idle:
                inFlight = nil
                activeFlightBinding = nil
                queuedFlightBinding = nil
                flightOwner.invalidate()
                flightLock.unlock()
                if let lastOutcome { return lastOutcome }
                throw lastError ?? HealthSyncUnavailableError()
            case let .rerun(reason):
                // `complete()` keeps the coalescer running for this already
                // authorized follow-up. Do not call request() here: that
                // would re-queue a reason and make every completion rerun.
                // Preserve the stronger/manual trigger selected by the
                // coalescer for the next pass.
                nextTrigger = reason == .statusRefresh ? .manual : .automatic
                if let queued = queuedFlightBinding {
                    binding = queued
                    activeFlightBinding = queued
                    queuedFlightBinding = nil
                }
                flightLock.unlock()
            }
        }
    }

    private func performPass(
        trigger: SyncTrigger,
        binding: HealthSessionBinding
    ) async throws -> HealthSyncOutcome {
        let today = Date().localDateString
        guard isCurrentAccount(binding) else { throw CancellationError() }

        // Fail OPEN: a network blip or a decode mismatch here must not
        // silently turn the whole sync into a no-op. Unknown state defaults
        // to "not yet locked", matching pre-#109 (always-overwrite) behavior.
        let existingRows: [ExistingReadinessRow] = (try? await HealthConfig
            .from("health_metrics", accessToken: binding.accessToken)
            .select("date, readiness, zone")
            .eq("date", value: today)
            .execute()
            .value) ?? []
        guard isCurrentAccount(binding) else { throw CancellationError() }
        let existing = existingRows.first
        let allowReadinessOverwrite = ReadinessWritePolicy.shouldOverwriteReadiness(
            existingReadiness: existing?.readiness,
            existingRowDate: existing?.date,
            now: Date(),
            trigger: trigger
        )

        let inputs = try await reader.readToday()
        guard isCurrentAccount(binding) else { throw CancellationError() }

        var row = HealthMetricsUpsert(
            date: today,
            hrvSdnnMs: inputs.hrvSDNNms,
            restingHr: inputs.restingHR,
            sleepHours: inputs.sleepHours,
            sleepDeepHours: inputs.sleepDeepHours,
            sleepRemHours: inputs.sleepRemHours,
            bodyMassKg: inputs.bodyMassKg,
            respRateBpm: inputs.respRateBpm,
            readiness: nil,
            zone: nil,
            computedAt: nil
        )
        if allowReadinessOverwrite {
            let acwr = try? await computeAcwr(binding: binding)
            guard isCurrentAccount(binding) else { throw CancellationError() }
            let result = RecoveryEngine.compute(inputs: inputs, acwr: acwr, t: tunables)
            row.readiness = result.score
            row.zone = result.zone?.rawValue
            row.computedAt = Date()
        }

        guard isCurrentAccount(binding) else { throw CancellationError() }

        try await HealthConfig
            .from("health_metrics", accessToken: binding.accessToken)
            .upsert(row, onConflict: "user_id,date")
            .execute()

        guard isCurrentAccount(binding) else { throw CancellationError() }

        let snapshot = ReadinessSnapshot(
            date: today,
            readiness: row.readiness ?? existing?.readiness,
            zone: row.zone ?? existing?.zone,
            computedAt: row.computedAt?.timeIntervalSince1970
        )
        return HealthSyncOutcome(
            snapshot: snapshot,
            freshness: allowReadinessOverwrite ? .fresh : .cached
        )
    }

    private func waitForFreshAccessToken(previous: HealthSessionBinding) async throws {
        SendLogReadinessBridge.requestFreshSession()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            guard isCurrentAccount(previous) else { throw CancellationError() }
            if let current = captureSessionBinding(),
               current.accessToken != previous.accessToken,
               current.identity.userId == previous.identity.userId {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw HealthAuthRequiredError()
    }

    private func captureSessionBinding() -> HealthSessionBinding? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        captureSessionBindingLocked()
    }

    private func captureSessionBindingLocked() -> HealthSessionBinding? {
        guard !HealthSessionStore.shared.isSignedOut,
              let accessToken = HealthSessionStore.shared.accessToken,
              let identity = accountEpoch.identity(tokenGeneration: sessionTokenGeneration)
        else { return nil }
        return HealthSessionBinding(identity: identity, accessToken: accessToken)
    }

    /// Account ownership intentionally ignores token generation. A same-user
    /// access-token rotation may finish a flight that already captured the old
    /// bearer, but the bearer is immutable and still scoped to this subject.
    /// A different subject or sign-out advances the account epoch and rejects
    /// every old pass before its next network boundary.
    private func isCurrentAccount(_ binding: HealthSessionBinding) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard let current = accountEpoch.identity(tokenGeneration: sessionTokenGeneration)
        else { return false }
        return current.accountEpoch == binding.identity.accountEpoch
            && current.userId == binding.identity.userId
            && !HealthSessionStore.shared.isSignedOut
    }

    private func isCurrentFlight(_ owner: ReadinessTaskGate.Token) -> Bool {
        flightLock.lock()
        defer { flightLock.unlock() }
        return flightOwner.isCurrent(owner)
    }

    /// Only the owner that is still current may clear the coalescer/task.
    /// An older cancelled task must not erase a replacement flight installed
    /// after `clearSession()` released the lock.
    private func abandonFlight(_ owner: ReadinessTaskGate.Token) {
        flightLock.lock()
        guard flightOwner.isCurrent(owner) else {
            flightLock.unlock()
            return
        }
        flightOwner.invalidate()
        flightState.cancel()
        inFlight = nil
        activeFlightBinding = nil
        queuedFlightBinding = nil
        flightLock.unlock()
    }

    private func invalidateFlight() {
        flightLock.lock()
        inFlight?.cancel()
        inFlight = nil
        flightOwner.invalidate()
        flightState.cancel()
        activeFlightBinding = nil
        queuedFlightBinding = nil
        flightLock.unlock()
    }

    private func clearRequestState() {
        requestLock.lock()
        requestTasks.values.forEach { $0.task.cancel() }
        requestTasks.removeAll()
        requestResults.removeAll()
        requestLock.unlock()
    }

    private func handleWatchRequest(
        _ request: ReadinessRefreshRequest,
        binding: HealthSessionBinding?
    ) async -> ReadinessRefreshResult {
        let requestIdentity = binding?.accountIdentity
        requestLock.lock()
        if let cached = requestResults[request.requestId],
           sameAccount(cached.identity, requestIdentity) {
            requestLock.unlock()
            return cached.result
        }
        if let cached = requestResults[request.requestId] {
            requestResults.removeValue(forKey: request.requestId)
        }
        if let entry = requestTasks[request.requestId],
           sameAccount(entry.identity, requestIdentity) {
            requestLock.unlock()
            return await entry.task.value
        }
        if let stale = requestTasks.removeValue(forKey: request.requestId) {
            stale.task.cancel()
        }

        let task = Task { [weak self] in
            guard let self else {
                let now = Date().timeIntervalSince1970
                return ReadinessRefreshResult(
                    request: request,
                    startedAt: now,
                    completedAt: now,
                    status: .failed,
                    freshness: .offline,
                    errorCode: "unavailable",
                    errorMessage: "The phone readiness service is unavailable."
                )
            }
            return await self.performWatchRequest(
                request,
                binding: binding
            )
        }
        requestTasks[request.requestId] = RequestTaskEntry(
            identity: requestIdentity ?? ReadinessSessionIdentity(
                accountEpoch: 0,
                tokenGeneration: 0,
                userId: nil
            ),
            task: task
        )
        requestLock.unlock()

        let result = await task.value
        // This first check deliberately happens before taking sessionLock.
        // `ownsAccount` acquires that lock; calling it from a locked section
        // would deadlock because NSLock is not re-entrant.
        guard ownsAccount(requestIdentity) else { return result }
        sessionLock.lock()
        guard ownsAccountLocked(requestIdentity) else {
            sessionLock.unlock()
            return result
        }
        requestLock.lock()
        if requestTasks[request.requestId]?.identity == requestIdentity {
            requestTasks.removeValue(forKey: request.requestId)
        }
        requestResults[request.requestId] = RequestResultEntry(
            identity: requestIdentity ?? ReadinessSessionIdentity(
                accountEpoch: 0,
                tokenGeneration: 0,
                userId: nil
            ),
            result: result
        )
        if requestResults.count > 32,
           let oldest = requestResults.min(by: {
               $0.value.result.completedAt < $1.value.result.completedAt
           })?.key {
            requestResults.removeValue(forKey: oldest)
        }
        let handler = resultHandler
        requestLock.unlock()

        if let data = try? JSONEncoder().encode(result) {
            UserDefaults.standard.set(data, forKey: latestResultKey)
            if let userId = requestIdentity?.userId?.uuidString {
                UserDefaults.standard.set(userId, forKey: latestResultUserKey)
            } else {
                UserDefaults.standard.removeObject(forKey: latestResultUserKey)
            }
        }
        handler?(result)
        sessionLock.unlock()
        return result
    }

    /// Direct reply and application-context publication share one final
    /// account-epoch gate. A same-user token refresh keeps the epoch and may
    /// publish; sign-out/account-switch suppresses the old snapshot entirely.
    private func deliverWatchResult(
        _ result: ReadinessRefreshResult,
        binding: HealthSessionBinding?,
        replyHandler: (([String: Any]) -> Void)?
    ) {
        sessionLock.lock()
        guard let binding,
              ReadinessRefreshDeliveryGate.allows(
                  capturedEpoch: binding.identity.accountEpoch,
                  currentEpoch: accountEpoch.currentEpoch,
                  isSignedOut: accountEpoch.isSignedOut
              ) else {
            sessionLock.unlock()
            return
        }
        replyHandler?(result.message())
        SendLogReadinessBridge.publish(result, immediate: replyHandler != nil)
        sessionLock.unlock()
    }

    private func performWatchRequest(
        _ request: ReadinessRefreshRequest,
        binding: HealthSessionBinding?
    ) async -> ReadinessRefreshResult {
        let startedAt = Date().timeIntervalSince1970
        do {
            // A request task can be scheduled after clearSession() has
            // cancelled the old task, before Swift observes cancellation.
            // Do not let that stale request join or create a flight for the
            // replacement account; its terminal result will be suppressed by
            // the delivery gate as well.
            guard let binding,
                  ownsAccount(binding.identity) else {
                throw CancellationError()
            }
            let outcome = try await syncOutcomeNow(
                trigger: .automatic,
                requestedBinding: binding
            )
            return ReadinessRefreshResult(
                request: request,
                startedAt: startedAt,
                status: .success,
                freshness: outcome.freshness,
                snapshot: outcome.snapshot
            )
        } catch is CancellationError {
            return ReadinessRefreshResult(
                request: request,
                startedAt: startedAt,
                status: .cancelled,
                freshness: .offline,
                errorCode: "cancelled",
                errorMessage: "The readiness refresh was cancelled."
            )
        } catch is HealthAuthRequiredError {
            return ReadinessRefreshResult(
                request: request,
                startedAt: startedAt,
                status: .authRequired,
                freshness: .offline,
                errorCode: "auth-required",
                errorMessage: "Open Sendmeter on your iPhone to refresh Health."
            )
        } catch {
            return ReadinessRefreshResult(
                request: request,
                startedAt: startedAt,
                status: .failed,
                freshness: .offline,
                errorCode: "sync-failed",
                errorMessage: "The iPhone could not refresh readiness."
            )
        }
    }

    /// Caller must hold `sessionLock`. Keeping this separate from the locking
    /// wrapper makes lock ownership visible at the call site and prevents the
    /// old nested ownership-check deadlock.
    private func ownsAccountLocked(_ captured: ReadinessSessionIdentity?) -> Bool {
        guard let captured else { return false }
        guard let current = accountEpoch.identity(tokenGeneration: sessionTokenGeneration)
        else { return false }
        return !accountEpoch.isSignedOut
            && current.accountEpoch == captured.accountEpoch
            && current.userId == captured.userId
    }

    private func ownsAccount(_ captured: ReadinessSessionIdentity?) -> Bool {
        guard captured != nil else { return false }
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return ownsAccountLocked(captured)
    }

    private func sameAccount(
        _ lhs: ReadinessSessionIdentity,
        _ rhs: ReadinessSessionIdentity?
    ) -> Bool {
        guard let rhs else { return false }
        return lhs.accountEpoch == rhs.accountEpoch && lhs.userId == rhs.userId
    }

    /// Hard-delete the user's health rows (RLS scopes to auth.uid()), then
    /// rebuild the whole recent history from HealthKit — not just today — so a
    /// clear recovers the full readiness trend, not a single day. Days with no
    /// health signal are skipped rather than written as empty rows. Explicit
    /// user action (the "Clear & resync" setting) — always authoritative,
    /// doesn't consult `ReadinessWritePolicy`.
    func clearAndResync(historyDays: Int = 90) async throws {
        guard let binding = captureSessionBinding() else {
            throw HealthAuthRequiredError()
        }
        try await HealthConfig
            .from("health_metrics", accessToken: binding.accessToken)
            .delete()
            .gte("date", value: "2000-01-01")
            .execute()
        guard isCurrentAccount(binding) else { throw CancellationError() }

        let history = try await reader.readHistory(days: historyDays)
        guard isCurrentAccount(binding) else { throw CancellationError() }
        let acwrByDate = (try? await acwrSeries(days: historyDays, binding: binding)) ?? [:]

        var rows: [HealthMetricsUpsert] = []
        for day in history {
            let i = day.inputs
            guard i.hrvSDNNms != nil || i.restingHR != nil || i.sleepHours != nil
            else { continue }
            let result = RecoveryEngine.compute(
                inputs: i, acwr: acwrByDate[day.date], t: tunables
            )
            rows.append(HealthMetricsUpsert(
                date: day.date,
                hrvSdnnMs: i.hrvSDNNms,
                restingHr: i.restingHR,
                sleepHours: i.sleepHours,
                sleepDeepHours: i.sleepDeepHours,
                sleepRemHours: i.sleepRemHours,
                bodyMassKg: i.bodyMassKg,
                respRateBpm: i.respRateBpm,
                readiness: result.score,
                zone: result.zone?.rawValue,
                computedAt: Date()
            ))
        }
        // #487 (F4, review finding 1): a rebuild that writes nothing back
        // after the hard delete above must NOT resolve as success — see
        // HealthResyncFoundNoDataError's doc comment for why this can't be
        // narrowed further (denied vs. genuinely empty) via public API.
        guard !rows.isEmpty else { throw HealthResyncFoundNoDataError() }
        guard isCurrentAccount(binding) else { throw CancellationError() }
        try await HealthConfig
            .from("health_metrics", accessToken: binding.accessToken)
            .upsert(rows, onConflict: "user_id,date")
            .execute()
        guard isCurrentAccount(binding) else { throw CancellationError() }
    }

    /// ACWR as-of each of the trailing `days`, keyed by that day's date string.
    /// One session-loads fetch spanning the whole window feeds a per-day EWMA,
    /// so a backfilled history row gets the load ratio it would have had that
    /// day (not today's) — the load penalty then reflects the real timeline.
    private func acwrSeries(
        days: Int,
        binding: HealthSessionBinding
    ) async throws -> [String: Double] {
        // #487 (F1): exclude soft-deleted sessions — without this the load
        // penalty from training the user deleted (History's soft-delete,
        // `deleted_at`) kept depressing readiness for the rest of the 28-day
        // ACWR window. The web's equivalent query (src/lib/repo/sessions.ts
        // fetchSessions) has always filtered this; native didn't, so the two
        // surfaces disagreed about what counts.
        let rows: [SessionLoadRow] = try await HealthConfig
            .from("sessions", accessToken: binding.accessToken)
            .select("date, load")
            .gte("date", value: cutoffDateString(daysAgo: days + Acwr.lookbackDays))
            .is("deleted_at", value: nil)
            .execute()
            .value

        var loadByDate: [String: Int] = [:]
        for r in rows { loadByDate[r.date, default: 0] += (r.load ?? 0) }

        let cal = Calendar.gregorianLocal
        var result: [String: Double] = [:]
        for o in 0..<days {
            let endDay = cal.date(byAdding: .day, value: -o, to: Date())!
            var series: [Double] = []
            for i in stride(from: Acwr.lookbackDays - 1, through: 0, by: -1) {
                let d = cal.date(byAdding: .day, value: -i, to: endDay)!
                series.append(Double(loadByDate[d.localDateString] ?? 0))
            }
            if let ratio = Acwr.ratio(dailyLoads: series) {
                result[endDay.localDateString] = ratio
            }
        }
        return result
    }

    private func computeAcwr(binding: HealthSessionBinding) async throws -> Double? {
        // #487 (F1): same soft-delete exclusion as acwrSeries above.
        let rows: [SessionLoadRow] = try await HealthConfig
            .from("sessions", accessToken: binding.accessToken)
            .select("date, load")
            .gte("date", value: cutoffDateString(daysAgo: Acwr.lookbackDays))
            .is("deleted_at", value: nil)
            .execute()
            .value

        var loadByDate: [String: Int] = [:]
        for r in rows { loadByDate[r.date, default: 0] += (r.load ?? 0) }

        let cal = Calendar.gregorianLocal
        var dailyLoads: [Double] = []
        for i in stride(from: Acwr.lookbackDays - 1, through: 0, by: -1) {
            let day = cal.date(byAdding: .day, value: -i, to: Date())!
            dailyLoads.append(Double(loadByDate[day.localDateString] ?? 0))
        }
        return Acwr.ratio(dailyLoads: dailyLoads)
    }

    private func cutoffDateString(daysAgo: Int) -> String {
        let cutoff = Calendar.gregorianLocal.date(byAdding: .day, value: -daysAgo, to: Date())!
        return cutoff.localDateString
    }

    // MARK: Background delivery

    /// Register an HKObserverQuery + background delivery so new wearable data
    /// wakes the app and triggers a sync automatically. Idempotent.
    func startBackgroundSync() {
        guard !observerStarted, HKHealthStore.isHealthDataAvailable() else { return }
        observerStarted = true
        let store = reader.healthStore

        let query = HKObserverQuery(
            sampleType: HealthKitReader.observedType, predicate: nil
        ) { [weak self] _, completion, _ in
            Task {
                // #109: this fires on every HealthKit background wake, not
                // on user action — always .automatic, so ReadinessWritePolicy
                // gets a say before today's row is touched.
                try? await self?.syncNow(trigger: .automatic)
                completion()
            }
        }
        store.execute(query)
        store.enableBackgroundDelivery(
            for: HealthKitReader.observedType, frequency: .daily
        ) { _, _ in }
    }
}
