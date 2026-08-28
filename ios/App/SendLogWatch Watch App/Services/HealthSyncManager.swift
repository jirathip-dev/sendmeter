import Foundation
import Observation
import OSLog
import SendLogHealthCore
import SendLogWatchCore
import UserNotifications
import WatchKit

/// Issue #802 — watch-only readiness: the watch reads its OWN HealthKit,
/// computes readiness on the wrist with the same `RecoveryEngine` the phone
/// uses, reconciles against the server window with the shared precedence
/// rule (Guy's locked choice), upserts directly to Supabase — no iPhone in
/// the loop — and runs the #801-style morning refresh with a non-silent
/// wake-up surface (complication + local notification).
///
/// Runtime HealthKit delivery/sync is device-verified later; this manager's
/// logic is pinned by the `SendLogWatchCore` pure layer + host tests.
@Observable
@MainActor
final class HealthSyncManager {
    nonisolated(unsafe) static weak var current: HealthSyncManager?

    private static let log = Logger(
        subsystem: "com.jirathip.sendlog.watchkitapp",
        category: "health"
    )

    private let healthKit = WatchHealthKitService()
    private let morningPolicy = WatchHealthMorningRefreshPolicy()
    private var coalescer = ReadinessRefreshCoalescer()
    private var passTask: Task<Void, Never>?
    private var lastHealthRefreshStartedAt: TimeInterval?
    private var hasRequestedNotifications = false
    private var authorizationAcknowledged = false
    private var hasScheduledAmbientRefresh = false

    init() {
        Self.current = self
        // #802 AC3: an overnight HealthKit write is the wake-up trigger for
        // the morning refresh — when the watch's store delivers new data,
        // run a pass without the user opening the app (background delivery
        // + observer queries; runtime delivery is device-only to verify).
        healthKit.onBackgroundUpdate = { @MainActor in
            HealthSyncManager.current?.trigger(reason: .foreground)
        }
    }

    // MARK: Public surface

    /// Fired on launch and foreground (and by the HealthKit observer /
    /// WKApplicationRefreshBackgroundTask wake-up). Coalesced: a second
    /// trigger during a pass queues at most one follow-up.
    func trigger(reason: ReadinessRefreshReason) {
        Task { @MainActor in
            await healthKit.ensureBackgroundObserversRegistered()
            scheduleAmbientRefreshIfNeeded()
        }
        switch coalescer.request(reason: reason) {
        case .start:
            startPass(reason: reason)
        case .queued:
            break
        }
    }

    /// Account fence: a signed-out watch must not read or write health data.
    func signedOut() {
        passTask?.cancel()
        passTask = nil
        coalescer.cancel()
        clearMorningProgress(for: WatchSessionStore.shared.userId)
    }

    // MARK: Pass execution

    private func startPass(reason: ReadinessRefreshReason) {
        passTask?.cancel()
        passTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if await self.performAutomaticPass() {
                if self.coalescer.isRunning {
                    switch self.coalescer.complete() {
                    case .idle:
                        break
                    case let .rerun(queuedReason):
                        self.startPass(reason: queuedReason)
                    }
                }
            } else {
                self.coalescer.cancel()
            }
        }
    }

    /// One full pass: morning window handling → compute → reconcile →
    /// direct upserts. Returns false when the pass was cancelled/aborted.
    private func performAutomaticPass() async -> Bool {
        guard let userID = WatchSessionStore.shared.userId else { return false }
        let now = Date()
        var calendar = Calendar.gregorianLocal
        calendar.timeZone = .current

        // ---- Morning refresh window (#801 semantics, priority over the
        // ordinary refresh path) ----
        let progressKey = "sendmeter.watch.health-morning-progress.\(userID.uuidString)"
        let startKey = "sendmeter.watch.health-morning-started.\(userID.uuidString)"
        if let progress = loadMorningProgress(key: progressKey, for: userID) {
            let progressIsValid = progress.accountUserID == userID
                && morningPolicy.isCurrentLocalDay(progress, at: now, calendar: calendar)
                && progress.nextPass >= 0
                && progress.nextPass < morningPolicy.passCount
            if progressIsValid, let pass = morningPolicy.duePass(for: progress, at: now) {
                let observation = await computeAndUpsert(
                    userID: userID,
                    now: now
                )
                guard let observation else { return false }
                return finishMorningPass(
                    key: progressKey,
                    startKey: startKey,
                    progress: progress,
                    pass: pass,
                    observation: observation
                )
            }
            if !progressIsValid {
                clearMorningProgress(key: progressKey)
            }
        }
        if morningPolicy.isMorning(at: now, calendar: calendar),
           morningPolicy.shouldStart(
               at: now,
               lastStartedAt: UserDefaults.standard.object(forKey: startKey) as? Date,
               calendar: calendar
           ) {
            var progress = WatchHealthMorningProgress(
                accountUserID: userID,
                startedAt: now,
                timeZoneIdentifier: calendar.timeZone.identifier
            )
            persistMorningProgress(progress, key: progressKey, startKey: startKey)
            let observation = await computeAndUpsert(
                userID: userID,
                now: now
            )
            guard let observation else { return false }
            return finishMorningPass(
                key: progressKey,
                startKey: startKey,
                progress: progress,
                pass: 0,
                observation: observation
            )
        }
        _ = await computeAndUpsert(
            userID: userID,
            now: now
        )
        return true
    }

    /// Advances the durable morning state after one pass.
    private func finishMorningPass(
        key: String,
        startKey: String,
        progress: WatchHealthMorningProgress,
        pass: Int,
        observation: WatchHealthSyncObservation
    ) -> Bool {
        var progress = progress
        progress.add(observation: observation)
        progress.nextPass = pass + 1
        if progress.nextPass < morningPolicy.passCount {
            // The next pass is claimed by the next supported event after
            // its deterministic delay — no detached timer on watchOS.
            persistMorningProgress(progress, key: key, startKey: startKey)
            return true
        }
        clearMorningProgress(key: key)
        return true
    }

    /// The one read/compute/reconcile/write path. Returns the observation,
    /// or nil when the pass was cancelled or no signed-in account is active.
    private func computeAndUpsert(
        userID: UUID,
        now: Date
    ) async -> WatchHealthSyncObservation? {
        guard !Task.isCancelled else { return nil }
        let timeZone = TimeZone.current
        var calendar = Calendar.gregorianLocal
        calendar.timeZone = timeZone
        lastHealthRefreshStartedAt = ProcessInfo.processInfo.systemUptime

        do {
            guard !Task.isCancelled,
                  WatchSessionStore.shared.userId == userID else { return nil }
            do { try await healthKit.requestAuthorization() }
            catch { /* authorization may already be decided; continue */ }

            // 1. Server window FIRST — precedence and insert-if-missing need
            //    the current rows before any write decision.
            let rows = try await Repo.fetchHealthMetrics()
            guard !Task.isCancelled,
                  WatchSessionStore.shared.userId == userID else { return nil }
            let today = now.dateString(in: calendar)
            let existingDates = Set(rows.map(\.date))
            let existingToday = rows.first(where: { $0.date == today })?.metric

            // 2. HealthKit read + same RecoveryEngine compute, plus the
            //    server-authoritative per-date ACWR (#661 F2 — an ACWR fetch
            //    failure fails the whole pass rather than scoring with a
            //    missing load penalty).
            let maps = try await healthKit.readDailyMaps(now: now, timeZone: timeZone)
            let sessionRows = try await Repo.fetchSessionLoads(sinceDays: 90)
            let acwrByDate = WatchHealthCompute.acwrByDate(
                rows: sessionRows,
                now: now,
                timeZone: timeZone
            )
            guard !Task.isCancelled else { return nil }
            let freshMetrics = try WatchHealthCompute.metrics(
                hrv: maps.hrv,
                restingHR: maps.restingHR,
                respiratoryRate: maps.respiratoryRate,
                sleep: maps.sleep,
                bodyMass: maps.bodyMass,
                acwrByDate: acwrByDate,
                now: now,
                timeZone: timeZone
            )

            // 3. Precedence-aware reconcile (#802 AC4 + #801 idempotency).
            //    The #109 afternoon freeze: automatic watch passes may not
            //    overwrite a scored reading once today has passed noon —
            //    the biometrics still merge, the score stays.
            let overwrite = ReadinessWritePolicy.shouldOverwriteReadiness(
                existingReadiness: existingToday?.readiness,
                existingRowDate: existingToday?.date,
                now: now,
                trigger: .automatic,
                calendar: calendar
            )
            let plan = WatchHealthReconcile.plan(
                freshMetrics: freshMetrics,
                existingToday: existingToday,
                existingDates: existingDates,
                today: today,
                now: now,
                timeZone: timeZone,
                allowReadinessOverwrite: overwrite
            )

            // 4. Direct watch→Supabase writes (no phone round-trip). The
            //    SERVER owns the precedence decision now (#802 AC4): one
            //    transaction decides against the live row and returns the
            //    canonical winner. A `retained` decision means the date is
            //    owned by a fresh non-empty row — nothing was written.
            var canonicalToday: HealthPrecedenceRpcResult?
            for upsert in plan.upserts {
                let outcome = try await Repo.upsertHealthMetricWithPrecedence(
                    upsert,
                    userID: userID,
                    writer: .watch,
                    timeZone: timeZone
                )
                guard !Task.isCancelled,
                      WatchSessionStore.shared.userId == userID else { return nil }
                if outcome.decision == "retained" {
                    Self.log.info(
                        "health precedence: retained existing row for \(outcome.date ?? upsert.date)"
                    )
                }
                if upsert.date == today {
                    canonicalToday = outcome
                }
            }

            // 5. Surface: complications/widget + the watch readiness display.
            if let metric = plan.todayMetric {
                // When the RPC retained the row, the canonical row is the
                // honest display (its score is the winner's).
                if let canonical = canonicalToday, canonical.decision == "retained" {
                    ReadinessManager.current?.applyOnWatchResult(
                        readiness: canonical.readiness,
                        zone: canonical.zone,
                        date: canonical.date ?? metric.date
                    )
                } else {
                    ReadinessManager.current?.applyOnWatchResult(
                        readiness: metric.readiness,
                        zone: metric.zone,
                        date: metric.date
                    )
                }
            }
            let observation = WatchHealthSyncObservation.successful(
                reconciledCount: plan.reconciledCount,
                sourceDataCount: plan.sourceDataDates.count
            )
            await maybeNotifyMorningScore(observation: observation, metric: plan.todayMetric, userID: userID, today: today)
            return observation
        } catch is CancellationError {
            return nil
        } catch {
            Self.log.error("health sync pass failed: \(String(describing: error))")
            return .failed
        }
    }

    // MARK: Morning notification (non-silent wake-up surface)

    /// One local notification per account per day when the morning refresh
    /// produced a scored readiness reading (never re-notifies). The marker
    /// is persisted ONLY after the notification is actually added: a denied
    /// or failed authorization leaves the day unmarked so the next trigger
    /// retries.
    private func maybeNotifyMorningScore(
        observation: WatchHealthSyncObservation,
        metric: WatchHealthMetric?,
        userID: UUID,
        today: String
    ) async {
        guard observation.hasSourceData,
              let metric, metric.date == today,
              let readiness = metric.readiness
        else { return }
        let notifiedKey = "sendmeter.watch.health-morning-notified.\(userID.uuidString).\(today)"
        guard UserDefaults.standard.object(forKey: notifiedKey) == nil else { return }

        if !hasRequestedNotifications {
            hasRequestedNotifications = true
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])) ?? false
            authorizationAcknowledged = granted
        }
        // Not authorized: NO marker — the next supported trigger retries
        // (the score still surfaces through the complication/widget).
        guard authorizationAcknowledged else { return }

        let content = UNMutableNotificationContent()
        content.title = "Readiness \(readiness)"
        content.body = "Your morning readiness is ready — \(metric.zone ?? "maintain") zone"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "sendmeter.morning.\(userID.uuidString).\(today)",
            content: content,
            trigger: nil // deliver immediately
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            // Persist ONLY after the add succeeded — a failure leaves the
            // day retriable.
            UserDefaults.standard.set(true, forKey: notifiedKey)
        } catch {
            Self.log.error("morning notification delivery failed: \(String(describing: error))")
        }
    }

    /// Best-effort WKApplicationRefreshBackgroundTask into the morning
    /// window (#802 AC3): the system wakes the app around 05:00 local even
    /// if no HealthKit observer fired, so an on-wrist overnight dataset is
    /// picked up without the user opening the app. watchOS picks the exact
    /// delivery time; this only states the preferred window start.
    private func scheduleAmbientRefreshIfNeeded() {
        guard WatchSessionStore.shared.userId != nil else { return }
        // Never re-schedule more than once a process: the OS's latest
        // schedule replaces any previous one, and re-requesting on every
        // foreground would just churn.
        guard !hasScheduledAmbientRefresh else { return }
        hasScheduledAmbientRefresh = true
        let calendar = Calendar.gregorianLocal
        let now = Date()
        let todayFive = calendar.date(bySettingHour: 5, minute: 0, second: 0, of: now)
        let preferred: Date
        if let todayFive, todayFive > now {
            preferred = todayFive
        } else {
            // Past this morning's 05:00 → next morning.
            let nextDay = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            preferred = calendar.date(bySettingHour: 5, minute: 0, second: 0, of: nextDay) ?? now
        }
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: preferred,
            userInfo: nil
        ) { _ in }
    }

    // MARK: Morning progress persistence

    private func loadMorningProgress(key: String, for userID: UUID) -> WatchHealthMorningProgress? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        guard let progress = try? JSONDecoder().decode(
            WatchHealthMorningProgress.self,
            from: data
        ), progress.accountUserID == userID else {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        return progress
    }

    private func persistMorningProgress(
        _ progress: WatchHealthMorningProgress,
        key: String,
        startKey: String
    ) {
        if let data = try? JSONEncoder().encode(progress) {
            UserDefaults.standard.set(data, forKey: key)
        }
        UserDefaults.standard.set(progress.startedAt, forKey: startKey)
    }

    private func clearMorningProgress(for userID: UUID?) {
        guard let userID else { return }
        let key = "sendmeter.watch.health-morning-progress.\(userID.uuidString)"
        clearMorningProgress(key: key)
    }

    private func clearMorningProgress(key: String) {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
