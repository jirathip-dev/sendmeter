import Foundation
import HealthKit
import Supabase
import SendLogHealthCore
import struct SendLogWatchCore.AccessTokenClaims
import struct SendLogWatchCore.ReadinessSnapshot
import struct SendLogWatchCore.ReadinessRefreshRequest
import struct SendLogWatchCore.ReadinessRefreshResult
import struct SendLogWatchCore.ReadinessRefreshCoalescer
import struct SendLogWatchCore.ReadinessTaskGate
import struct SendLogWatchCore.ReadinessAccountEpoch
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

private struct RequestTaskEntry {
    let epoch: UInt64
    let task: Task<ReadinessRefreshResult, Never>
}

private struct RequestResultEntry {
    let epoch: UInt64
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

    private let requestLock = NSLock()
    private var requestTasks: [String: RequestTaskEntry] = [:]
    private var requestResults: [String: RequestResultEntry] = [:]
    private var resultHandler: ((ReadinessRefreshResult) -> Void)?
    private let latestResultKey = "sendmeter.health.latestReadinessResult"
    private let sessionLock = NSLock()
    private var accountEpoch = ReadinessAccountEpoch()

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
        // Keep the epoch transition and bearer replacement in the same
        // critical section. A request that observes the new epoch therefore
        // cannot still pick up the previous account's token.
        HealthSessionStore.shared.store(accessToken)
        sessionLock.unlock()
        if change == .accountChanged {
            invalidateFlight()
            clearRequestState()
            UserDefaults.standard.removeObject(forKey: latestResultKey)
        }
    }

    /// Forgets this client's stored token — called when the phone signs out,
    /// so a later background HealthKit wake can't keep writing as that user.
    /// Local only: the WebView's own signOut has already revoked the session
    /// server-side, and this client has no session of its own to end.
    func clearSession() {
        sessionLock.lock()
        accountEpoch.clearSession()
        sessionLock.unlock()
        HealthSessionStore.shared.clear()
        invalidateFlight()
        clearRequestState()
        UserDefaults.standard.removeObject(forKey: latestResultKey)
    }

    /// Installs the request side of the narrow auth-bridge seam. This is
    /// called by the plugin during native load, so delivery never depends on
    /// a JavaScript listener or a live WebView.
    func installReadinessBridge() {
        SendLogReadinessBridge.registerRequestHandler { [weak self] request, replyHandler in
            Task { [weak self] in
                guard let self else { return }
                let requestEpoch = self.accountEpochValue()
                let result = await self.handleWatchRequest(
                    request,
                    accountEpoch: requestEpoch
                )
                // The epoch check and both direct/context publications are
                // one session-locked decision. A clear/new-account call that
                // wins first suppresses the old snapshot entirely; it is not
                // safe to send a terminal success reply from the old account.
                self.deliverWatchResult(
                    result,
                    accountEpoch: requestEpoch,
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
        requestLock.lock()
        if let latest = requestResults.values.max(by: {
            $0.result.completedAt < $1.result.completedAt
        }) {
            requestLock.unlock()
            return latest.result
        }
        requestLock.unlock()
        guard let data = UserDefaults.standard.data(forKey: latestResultKey) else {
            return nil
        }
        return try? JSONDecoder().decode(ReadinessRefreshResult.self, from: data)
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

    private func syncOutcomeNow(trigger: SyncTrigger) async throws -> HealthSyncOutcome {
        let reason: ReadinessRefreshReason = trigger == .manual ? .statusRefresh : .foreground
        let task: Task<HealthSyncOutcome, Error>

        flightLock.lock()
        switch flightState.request(reason: reason) {
        case .start:
            let owner = flightOwner.begin()
            // Set `inFlight` before creating the task's first await. A second
            // foreground callback therefore joins this exact task instead of
            // launching another HealthKit read/upsert pair.
            let newTask = Task { [weak self] in
                guard let self else { throw HealthSyncUnavailableError() }
                return try await self.runFlight(trigger: trigger, owner: owner)
            }
            inFlight = newTask
            task = newTask
        case .queued:
            // `flightState` cannot queue without an owner task, but keep the
            // fallback explicit so an unexpected teardown fails safely rather
            // than force-unwrapping an optional from a background callback.
            guard let existing = inFlight else {
                flightOwner.invalidate()
                flightState.cancel()
                flightLock.unlock()
                throw HealthSyncUnavailableError()
            }
            task = existing
        }
        flightLock.unlock()

        let outcome = try await task.value
        return outcome
    }

    /// One coalesced flight may contain at most one follow-up pass. Auth
    /// expiry gets one fresh-token relay/retry inside that flight; it never
    /// hands a refresh token to the native side.
    private func runFlight(
        trigger: SyncTrigger,
        owner: ReadinessTaskGate.Token
    ) async throws -> HealthSyncOutcome {
        var lastOutcome: HealthSyncOutcome?
        var lastError: Error?
        var authRelayAttempted = false
        var nextTrigger = trigger

        while true {
            if Task.isCancelled || !isCurrentFlight(owner) {
                abandonFlight(owner)
                throw CancellationError()
            }
            do {
                lastOutcome = try await performPass(trigger: nextTrigger)
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
                        try await waitForFreshAccessToken()
                        lastOutcome = try await performPass(trigger: nextTrigger)
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
                flightLock.unlock()
            }
        }
    }

    private func performPass(trigger: SyncTrigger) async throws -> HealthSyncOutcome {
        let today = Date().localDateString
        sessionLock.lock()
        let epoch = accountEpoch.currentEpoch
        sessionLock.unlock()
        guard HealthSessionStore.shared.accessToken != nil else {
            throw HealthAuthRequiredError()
        }

        // Fail OPEN: a network blip or a decode mismatch here must not
        // silently turn the whole sync into a no-op. Unknown state defaults
        // to "not yet locked", matching pre-#109 (always-overwrite) behavior.
        let existingRows: [ExistingReadinessRow] = (try? await HealthConfig
            .from("health_metrics")
            .select("date, readiness, zone")
            .eq("date", value: today)
            .execute()
            .value) ?? []
        let existing = existingRows.first
        let allowReadinessOverwrite = ReadinessWritePolicy.shouldOverwriteReadiness(
            existingReadiness: existing?.readiness,
            existingRowDate: existing?.date,
            now: Date(),
            trigger: trigger
        )

        let inputs = try await reader.readToday()

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
            let acwr = try? await computeAcwr()
            let result = RecoveryEngine.compute(inputs: inputs, acwr: acwr, t: tunables)
            row.readiness = result.score
            row.zone = result.zone?.rawValue
            row.computedAt = Date()
        }

        sessionLock.lock()
        let stillCurrentBeforeWrite = accountEpoch.owns(epoch)
        sessionLock.unlock()
        guard stillCurrentBeforeWrite, HealthSessionStore.shared.accessToken != nil else {
            throw CancellationError()
        }

        try await HealthConfig
            .from("health_metrics")
            .upsert(row, onConflict: "user_id,date")
            .execute()

        sessionLock.lock()
        let stillCurrentGeneration = accountEpoch.owns(epoch)
        sessionLock.unlock()
        guard stillCurrentGeneration, HealthSessionStore.shared.accessToken != nil else {
            throw CancellationError()
        }

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

    private func waitForFreshAccessToken() async throws {
        let previous = HealthSessionStore.shared.accessToken
        SendLogReadinessBridge.requestFreshSession()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let token = HealthSessionStore.shared.accessToken,
               !token.isEmpty,
               previous == nil || token != previous {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw HealthAuthRequiredError()
    }

    private func accountEpochValue() -> UInt64 {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return accountEpoch.currentEpoch
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
        flightLock.unlock()
    }

    private func invalidateFlight() {
        flightLock.lock()
        inFlight?.cancel()
        inFlight = nil
        flightOwner.invalidate()
        flightState.cancel()
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
        accountEpoch requestEpoch: UInt64
    ) async -> ReadinessRefreshResult {
        requestLock.lock()
        if let cached = requestResults[request.requestId], cached.epoch == requestEpoch {
            requestLock.unlock()
            return cached.result
        }
        if let cached = requestResults[request.requestId] {
            requestResults.removeValue(forKey: request.requestId)
        }
        if let entry = requestTasks[request.requestId], entry.epoch == requestEpoch {
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
                accountEpoch: requestEpoch
            )
        }
        requestTasks[request.requestId] = RequestTaskEntry(
            epoch: requestEpoch,
            task: task
        )
        requestLock.unlock()

        let result = await task.value
        sessionLock.lock()
        guard accountEpoch.owns(requestEpoch) else {
            sessionLock.unlock()
            return result
        }
        requestLock.lock()
        if requestTasks[request.requestId]?.epoch == requestEpoch {
            requestTasks.removeValue(forKey: request.requestId)
        }
        requestResults[request.requestId] = RequestResultEntry(
            epoch: requestEpoch,
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
        accountEpoch requestEpoch: UInt64,
        replyHandler: (([String: Any]) -> Void)?
    ) {
        sessionLock.lock()
        guard ReadinessRefreshDeliveryGate.allows(
            capturedEpoch: requestEpoch,
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
        accountEpoch requestEpoch: UInt64
    ) async -> ReadinessRefreshResult {
        let startedAt = Date().timeIntervalSince1970
        do {
            // A request task can be scheduled after clearSession() has
            // cancelled the old task, before Swift observes cancellation.
            // Do not let that stale request join or create a flight for the
            // replacement account; its terminal result will be suppressed by
            // the delivery gate as well.
            guard isAccountEpochCurrent(requestEpoch) else {
                throw CancellationError()
            }
            let outcome = try await syncOutcomeNow(trigger: .automatic)
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

    private func isAccountEpochCurrent(_ capturedEpoch: UInt64) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return accountEpoch.owns(capturedEpoch)
    }

    /// Hard-delete the user's health rows (RLS scopes to auth.uid()), then
    /// rebuild the whole recent history from HealthKit — not just today — so a
    /// clear recovers the full readiness trend, not a single day. Days with no
    /// health signal are skipped rather than written as empty rows. Explicit
    /// user action (the "Clear & resync" setting) — always authoritative,
    /// doesn't consult `ReadinessWritePolicy`.
    func clearAndResync(historyDays: Int = 90) async throws {
        try await HealthConfig
            .from("health_metrics")
            .delete()
            .gte("date", value: "2000-01-01")
            .execute()

        let history = try await reader.readHistory(days: historyDays)
        let acwrByDate = (try? await acwrSeries(days: historyDays)) ?? [:]

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
        try await HealthConfig
            .from("health_metrics")
            .upsert(rows, onConflict: "user_id,date")
            .execute()
    }

    /// ACWR as-of each of the trailing `days`, keyed by that day's date string.
    /// One session-loads fetch spanning the whole window feeds a per-day EWMA,
    /// so a backfilled history row gets the load ratio it would have had that
    /// day (not today's) — the load penalty then reflects the real timeline.
    private func acwrSeries(days: Int) async throws -> [String: Double] {
        // #487 (F1): exclude soft-deleted sessions — without this the load
        // penalty from training the user deleted (History's soft-delete,
        // `deleted_at`) kept depressing readiness for the rest of the 28-day
        // ACWR window. The web's equivalent query (src/lib/repo/sessions.ts
        // fetchSessions) has always filtered this; native didn't, so the two
        // surfaces disagreed about what counts.
        let rows: [SessionLoadRow] = try await HealthConfig
            .from("sessions")
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

    private func computeAcwr() async throws -> Double? {
        // #487 (F1): same soft-delete exclusion as acwrSeries above.
        let rows: [SessionLoadRow] = try await HealthConfig
            .from("sessions")
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
