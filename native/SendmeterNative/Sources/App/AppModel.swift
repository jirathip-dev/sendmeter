import Auth
import Combine
import Foundation
import SendmeterCore
import SwiftUI

public typealias AuthSession = Auth.Session

public enum AppBootState: Equatable {
    case loading
    case signedOut
    case signedIn
}

public enum AppTab: Hashable {
    case dashboard
    case workout
    case force
    case history
    case settings
}

private enum PendingWrite: Codable, Sendable {
    case session(SessionQueuePayload)
    case recording(NewTindeqRecording)
    case workout(WorkoutDraft)
}

private struct SessionQueuePayload: Codable, Sendable {
    let id: UUID
    let draft: SessionDraft
}

@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var bootState: AppBootState = .loading
    @Published public private(set) var authSession: AuthSession?
    @Published public private(set) var sessions: [SendmeterCore.Session] = []
    @Published public private(set) var deletedSessions: [SendmeterCore.Session] = []
    @Published public private(set) var deletedRecordings: [TindeqRecording] = []
    @Published public private(set) var healthMetrics: [HealthMetric] = []
    @Published public private(set) var phasePeriods: [PhasePeriod] = []
    @Published public private(set) var settings = UserSettings(
        currentPhase: .capacity,
        phaseStartDate: LocalDateSupport.string(from: Date())
    )
    @Published public private(set) var recordings: [TindeqRecording] = []
    @Published public private(set) var presets: [TindeqPreset] = []
    @Published public private(set) var routines: [RoutinePreset] = []
    @Published public private(set) var workouts: [WorkoutListItem] = []
    @Published public private(set) var liveWorkout: LiveWorkout?
    @Published public private(set) var liveWorkoutSyncState: LiveWorkoutSyncState = .unknown
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var queuedWriteCount = 0
    @Published public private(set) var queueBreadcrumbs: [QueueBreadcrumb] = []
    @Published public var errorMessage: String?
    @Published public var toastMessage: String?
    @Published public var passwordRecovery = false
    @Published public var selectedTab: AppTab = .dashboard

    public let auth: AuthService
    public let repository: SendmeterRepository
    public let tindeq: TindeqBluetooth
    public let health: HealthKitService
    public let watch: WatchConnectivityService
    public let realtime: RealtimeService

    private let queue: DurableQueue<PendingWrite>?
    private var authObservationTask: Task<Void, Never>?
    private var pendingSessions: [UUID: SendmeterCore.Session] = [:]
    private var pendingRecordings: [UUID: TindeqRecording] = [:]
    private var nestedCancellables = Set<AnyCancellable>()
    private var didBootstrapUserID: UUID?

    /// Live workout mirror cursor (two producers: WC beat + realtime row,
    /// one merge discipline — see LiveWorkoutMirror).
    private var liveWorkoutMirror = LiveWorkoutMirrorState.empty
    private var liveMirrorTicker: Task<Void, Never>?
    /// Realtime list reconciliation: pending slices + the scheduled flush.
    private let reconcileCoalescer = RealtimeRefreshCoalescer()
    private var reconcileFlushTask: Task<Void, Never>?

    public init(
        auth: AuthService? = nil,
        repository: SendmeterRepository = SendmeterRepository(),
        tindeq: TindeqBluetooth? = nil,
        health: HealthKitService? = nil,
        watch: WatchConnectivityService? = nil,
        realtime: RealtimeService? = nil
    ) {
        self.auth = auth ?? AuthService()
        self.repository = repository
        self.tindeq = tindeq ?? TindeqBluetooth()
        self.health = health ?? HealthKitService()
        self.watch = watch ?? WatchConnectivityService()
        self.realtime = realtime ?? RealtimeService()

        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("SendmeterNative", isDirectory: true)
        if let support {
            self.queue = try? DurableQueue(
                directoryURL: support,
                filename: "pending-writes.json",
                breadcrumbLimit: 10
            )
        } else {
            self.queue = nil
        }

        let watch = self.watch
        let realtime = self.realtime
        let tindeq = self.tindeq
        let auth = self.auth

        watch.onSessionRequested = { [weak self] in
            await self?.relayValidSessionToWatch(guaranteed: true)
        }
        watch.onWorkoutCompletion = { [weak self] completion in
            await self?.acceptWatchCompletion(completion)
        }
        watch.onLiveWorkoutMessage = { [weak self] message in
            self?.acceptLiveWorkoutMessage(message)
        }
        realtime.onLiveWorkoutRow = { [weak self] record in
            self?.acceptLiveWorkoutRow(record)
        }
        realtime.onListEvent = { [weak self] table in
            self?.acceptRealtimeListEvent(table)
        }

        tindeq.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &nestedCancellables)
        watch.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &nestedCancellables)

        authObservationTask = Task { [weak self] in
            guard let self else { return }
            for await (event, session) in auth.client.auth.authStateChanges {
                await self.handleAuthEvent(event, session: session)
            }
        }
    }

    deinit {
        authObservationTask?.cancel()
        liveMirrorTicker?.cancel()
        reconcileFlushTask?.cancel()
    }

    public var currentUserID: UUID? { authSession?.user.id }
    public var currentUserEmail: String? { authSession?.user.email }
    public var currentPhase: PhaseDefinition { PhaseCatalog.definition(for: settings.currentPhase) }
    public var acwr: ACWRData { TrainingMetrics.computeACWR(sessions: sessions) }
    public var readiness: HealthMetric? { healthMetrics.first }
    public var weeklyLoads: [WeeklyLoad] { TrainingMetrics.weeklyLoads(sessions: sessions) }
    public var recentSessions: [SendmeterCore.Session] { Array(sessions.prefix(8)) }

    // MARK: Auth

    public func signIn(email: String, password: String) async {
        await perform { _ = try await self.auth.signIn(email: email, password: password) }
    }

    public func signUp(email: String, password: String) async {
        await perform {
            let session = try await self.auth.signUp(email: email, password: password)
            if session == nil { self.toastMessage = "Check your email to confirm your account." }
        }
    }

    public func sendMagicLink(email: String) async {
        await perform {
            try await self.auth.sendMagicLink(email: email)
            self.toastMessage = "Magic link sent."
        }
    }

    public func signInWithPasskey() async {
        await perform { try await self.auth.signInWithPasskey() }
    }

    public func registerPasskey() async {
        await perform {
            try await self.auth.registerPasskey()
            self.toastMessage = "Passkey registered."
        }
    }

    public func signOut() async {
        await perform {
            try await self.auth.signOut()
            self.watch.relaySession(nil)
        }
    }

    public func updatePassword(_ password: String) async {
        await perform {
            try await self.auth.updatePassword(password)
            self.passwordRecovery = false
            self.toastMessage = "Password updated."
        }
    }

    public func handleDeepLink(_ url: URL) async {
        await perform { try await self.auth.handleDeepLink(url) }
    }

    public func becameActive() async {
        guard authSession != nil else { return }
        await relayValidSessionToWatch(guaranteed: false)
        await drainQueue()
        await refreshAll(showSpinner: false)
        // Foreground reconciliation for the live mirror: a dropped realtime
        // socket degrades to this refetch (the row is the authoritative
        // server state), and the mirror cursor rejects anything older.
        await refreshLiveWorkoutRow()
        if UserDefaults.standard.bool(forKey: "sendmeter.native.health-authorized") {
            await syncHealth(requestAuthorization: false)
        }
    }

    private func handleAuthEvent(_ event: AuthChangeEvent, session: AuthSession?) async {
        switch event {
        case .initialSession, .signedIn, .tokenRefreshed, .userUpdated, .mfaChallengeVerified:
            guard let session else {
                authSession = nil
                bootState = .signedOut
                await tearDownRealtime()
                return
            }
            let changedUser = authSession?.user.id != session.user.id
            authSession = session
            bootState = .signedIn
            watch.relaySession(session)
            if changedUser || didBootstrapUserID != session.user.id {
                clearLoadedData()
                await refreshAll(showSpinner: true)
                didBootstrapUserID = session.user.id
                await acceptStoredWatchCompletions()
                await drainQueue()
                // The subscribe is AWAITED on purpose (#626 review): this
                // serializes it with auth events, so a sign-out / user switch
                // can never overlap an in-flight join — the stale-channel
                // takeover race is structurally impossible. Realtime is still
                // best-effort: a degraded socket can delay the auth loop by
                // up to its join timeout (~10s, once at bootstrap) and a
                // failed join is silent.
                await realtime.subscribe(userID: session.user.id)
                await refreshLiveWorkoutRow()
                restartLiveMirrorTickerIfNeeded()
            }
        case .passwordRecovery:
            authSession = session
            passwordRecovery = true
            bootState = session == nil ? .signedOut : .signedIn
        case .signedOut, .userDeleted:
            watch.relaySession(nil)
            authSession = nil
            didBootstrapUserID = nil
            clearLoadedData()
            bootState = .signedOut
            await tearDownRealtime()
        }
    }

    private func relayValidSessionToWatch(guaranteed: Bool) async {
        do {
            let valid = try await auth.client.auth.session
            authSession = valid
            watch.relaySession(valid, guaranteed: guaranteed)
        } catch {
            watch.relaySession(nil, guaranteed: guaranteed)
        }
    }

    // MARK: Loading

    public func refreshAll(showSpinner: Bool = true) async {
        guard let userID = currentUserID else { return }
        if showSpinner { isRefreshing = true }
        defer { if showSpinner { isRefreshing = false } }
        do {
            let today = LocalDateSupport.string(from: Date())
            async let remoteSessions = repository.fetchSessions(accountUserID: userID)
            async let remoteSettings = repository.fetchSettings(userID: userID, today: today)
            async let remotePeriods = repository.fetchPhasePeriods()
            async let remoteHealth = repository.fetchHealthMetrics()
            async let remoteRecordings = repository.fetchRecordings()
            async let remotePresets = repository.fetchPresets()
            async let remoteRoutines = repository.fetchRoutinePresets()
            async let remoteWorkouts = repository.fetchWorkouts()

            let fetchedSessions = try await remoteSessions
            let fetchedRecordings = try await remoteRecordings
            settings = try await remoteSettings
            phasePeriods = try await remotePeriods
            healthMetrics = try await remoteHealth
            presets = try await remotePresets
            routines = try await remoteRoutines
            workouts = try await remoteWorkouts
            await restorePendingWrites(
                userID: userID,
                remoteSessionIDs: Set(fetchedSessions.map(\.id)),
                remoteRecordingIDs: Set(fetchedRecordings.map(\.id))
            )
            mergeSessions(remote: fetchedSessions)
            mergeRecordings(remote: fetchedRecordings)
            await refreshQueueCount()
        } catch {
            surface(error)
        }
    }

    public func refreshTrash() async {
        guard let userID = currentUserID else { return }
        do {
            async let sessionTrash = repository.fetchDeletedSessions(accountUserID: userID)
            async let recordingTrash = repository.fetchDeletedRecordings()
            deletedSessions = try await sessionTrash
            deletedRecordings = try await recordingTrash
        } catch {
            surface(error)
        }
    }

    // MARK: Sessions

    public func logSession(_ draft: SessionDraft) async {
        guard let userID = currentUserID else { return }
        let id = UUID()
        let pending = pendingSession(
            id: id,
            draft: draft,
            accountUserID: userID
        )
        pendingSessions[id] = pending
        mergeSessions(remote: sessions.filter { !$0.pending })
        let item = DurableQueueItem(
            id: id,
            accountUserID: userID,
            payload: PendingWrite.session(SessionQueuePayload(id: id, draft: draft))
        )
        if !(await enqueueAndUpload(item)) {
            pendingSessions.removeValue(forKey: id)
            mergeSessions(remote: sessions.filter { !$0.pending })
        }
    }

    public func updateSession(_ session: SendmeterCore.Session) async {
        await perform {
            let saved = try await self.repository.updateSession(session)
            self.replaceSession(saved)
            self.toastMessage = "Session updated."
        }
    }

    public func deleteSession(_ session: SendmeterCore.Session) async {
        await perform {
            try await self.repository.softDeleteSession(id: session.id)
            self.sessions.removeAll { $0.id == session.id }
            self.toastMessage = "Session moved to Trash."
        }
    }

    public func restoreSession(_ session: SendmeterCore.Session) async {
        await perform {
            try await self.repository.restoreSession(id: session.id)
            self.deletedSessions.removeAll { $0.id == session.id }
            await self.refreshAll(showSpinner: false)
        }
    }

    public func purgeSession(_ session: SendmeterCore.Session) async {
        await perform {
            try await self.repository.purgeSession(id: session.id)
            self.deletedSessions.removeAll { $0.id == session.id }
        }
    }

    // MARK: Phase

    public func switchPhase(to phase: PhaseID) async {
        guard let userID = currentUserID else { return }
        await perform {
            let result = try await self.repository.switchPhase(
                to: phase,
                currentPeriods: self.phasePeriods,
                today: LocalDateSupport.string(from: Date()),
                userID: userID
            )
            self.phasePeriods = result.periods
            self.settings = result.settings
            self.toastMessage = "Training Block changed to \(PhaseCatalog.definition(for: phase).name)."
        }
    }

    // MARK: Workout

    public func saveWorkout(_ draft: WorkoutDraft) async {
        guard let userID = currentUserID, draft.accountUserID == userID else { return }
        let pending = pendingSession(from: draft)
        pendingSessions[pending.id] = pending
        mergeSessions(remote: sessions.filter { !$0.pending })
        let item = DurableQueueItem(
            id: draft.sessionID,
            accountUserID: userID,
            payload: PendingWrite.workout(draft)
        )
        if !(await enqueueAndUpload(item)) {
            pendingSessions.removeValue(forKey: draft.sessionID)
            mergeSessions(remote: sessions.filter { !$0.pending })
        }
    }

    // MARK: Force

    public func resolveForceTargetPlan(
        preset: TindeqPreset,
        tag: String,
        startingSide: TindeqSide,
        fallbackSide: TindeqSide
    ) async -> ForceTargetPlan {
        let sides: [TindeqSide]
        if preset.alternateSides {
            sides = startingSide == .right ? [.right, .left] : [.left, .right]
        } else {
            sides = [fallbackSide]
        }

        var targets: [ForceTargetKey: ForceTargetBand] = [:]
        let needsCurve = preset.targetFromCurve
            || (preset.targetPercentage != nil && preset.percentageBasis == .criticalForce)

        for targetSide in sides {
            let references = await forceReferences(
                tag: tag,
                side: targetSide,
                needsCurve: needsCurve
            )
            for setNumber in 1...max(1, preset.sets) {
                guard let band = ForceCurveEngine.targetBand(
                    preset: preset,
                    references: references,
                    setNumber: setNumber
                ) else { continue }
                targets[ForceTargetKey(setNumber: setNumber, side: targetSide)] = band
            }
        }
        return ForceTargetPlan(targets: targets)
    }

    public func saveForceSummary(
        _ summary: ForceSummary,
        tag: String,
        side: TindeqSide,
        zone: RecordedZone?,
        preset: TindeqPreset? = nil,
        targetBand: ForceTargetBand? = nil,
        protocolRunID: UUID? = nil,
        setNumber: Int? = nil,
        repetitionNumber: Int? = nil,
        partial: Bool = false
    ) async -> Bool {
        guard let userID = currentUserID else { return false }

        let resolvedSet = max(1, setNumber ?? 1)
        let resolvedTargetBand = targetBand ?? preset.flatMap {
            ForceCurveEngine.targetBand(
                preset: $0,
                references: .empty,
                setNumber: resolvedSet
            )
        }
        let protocolMode = preset?.protocolMode ?? .hold
        let plannedDuration: Int? = preset.map {
            if $0.protocolMode == .reverseAction {
                return ReverseActionEngine.plannedDurationMilliseconds(preset: $0)
            }
            return $0.holdSeconds(forSet: resolvedSet) * 1_000
        }

        var averageKilograms: Double? = summary.averageKilograms
        var actualDuration = summary.durationMilliseconds
        var cadenceMarkers: [CadenceMarker]?
        var setMetrics: ReverseActionMetrics?
        var completedRepetitions: Int?
        var completionStatus: String?
        var persistedRepetitionNumber = repetitionNumber

        if let preset, preset.protocolMode == .reverseAction {
            let completion = ReverseActionEngine.completion(
                preset: preset,
                actualDurationMilliseconds: summary.durationMilliseconds
            )
            actualDuration = completion.actual
            cadenceMarkers = completion.markers
            completedRepetitions = completion.completedRepetitions
            completionStatus = partial ? "partial" : completion.status
            // Reverse Action stores one continuous row per set. Repetitions
            // are represented by cadence markers and completed_reps.
            persistedRepetitionNumber = nil
        }

        let persistedSamples: [TindeqSample]
        if protocolRunID != nil, plannedDuration != nil {
            persistedSamples = summary.samples.filter {
                $0.milliseconds <= Double(max(1, actualDuration))
            }
        } else {
            persistedSamples = summary.samples
        }
        let persistedPeak = persistedSamples.map(\.kilograms).max() ?? summary.peakKilograms
        if protocolMode == .reverseAction {
            setMetrics = ReverseActionEngine.metrics(
                samples: persistedSamples,
                targetBand: resolvedTargetBand,
                plannedDurationMilliseconds: plannedDuration ?? actualDuration
            )
            averageKilograms = setMetrics?.meanKilograms ?? averageKilograms
        } else if !persistedSamples.isEmpty {
            averageKilograms = persistedSamples.map(\.kilograms).reduce(0, +) / Double(persistedSamples.count)
        }

        let recording = NewTindeqRecording(
            accountUserID: userID,
            durationMilliseconds: max(1, actualDuration),
            peakKilograms: persistedPeak,
            averageKilograms: averageKilograms,
            note: "",
            tag: String(tag.prefix(120)),
            side: side,
            groupID: nil,
            protocolRunID: protocolRunID,
            setNumber: setNumber,
            zone: zone,
            samples: persistedSamples,
            plannedDurationMilliseconds: plannedDuration,
            actualDurationMilliseconds: max(1, actualDuration),
            repetitionNumber: persistedRepetitionNumber,
            protocolMode: protocolMode,
            targetKilograms: resolvedTargetBand?.kilograms,
            targetLowKilograms: resolvedTargetBand?.lowKilograms,
            targetHighKilograms: resolvedTargetBand?.highKilograms,
            cadenceOutSeconds: protocolMode == .reverseAction ? preset?.cadenceOutSeconds : nil,
            cadenceReturnSeconds: protocolMode == .reverseAction ? preset?.cadenceReturnSeconds : nil,
            cadenceMarkers: cadenceMarkers,
            setMetrics: setMetrics,
            setupNote: preset?.setupNote ?? "",
            capacityEvidence: preset?.capacityEvidence,
            completedRepetitions: completedRepetitions,
            completionStatus: completionStatus
        )
        let optimistic = pendingRecording(from: recording)
        pendingRecordings[optimistic.id] = optimistic
        mergeRecordings(remote: recordings.filter { pendingRecordings[$0.id] == nil })
        let item = DurableQueueItem(
            id: recording.id,
            accountUserID: userID,
            payload: PendingWrite.recording(recording)
        )
        let enqueued = await enqueueAndUpload(item)
        if !enqueued {
            pendingRecordings.removeValue(forKey: recording.id)
            mergeRecordings(remote: recordings.filter { pendingRecordings[$0.id] == nil })
        }
        return enqueued
    }

    private func forceReferences(
        tag: String,
        side: TindeqSide,
        needsCurve: Bool
    ) async -> ForceReferences {
        let normalizedTag = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedTag.isEmpty else { return .empty }

        let byTag = recordings.filter {
            $0.tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedTag
                && !pendingRecordings.keys.contains($0.id)
                && ($0.protocolMode != .reverseAction || $0.capacityEvidence == true)
        }
        let exactSide = byTag.filter { side == .unspecified || $0.side == side }
        let metadata: [TindeqRecording]
        if exactSide.isEmpty, side != .unspecified {
            metadata = byTag.filter { $0.side == .unspecified }
        } else {
            metadata = exactSide
        }

        let personalRecord = metadata.compactMap(\.peakKilograms).filter { $0 > 0 }.max()
        guard needsCurve else {
            return ForceReferences(
                personalRecordKilograms: personalRecord,
                criticalForceKilograms: nil,
                impulseAboveCriticalForceKilogramSeconds: nil,
                maximumForceKilograms: personalRecord,
                capabilityFit: nil
            )
        }

        let candidates = ForceCurveEngine.pickCurveRecordings(metadata)
        let repository = self.repository
        let sampleSets = await withTaskGroup(of: [TindeqSample]?.self) { group in
            for candidate in candidates {
                group.addTask {
                    let samples = try? await repository.fetchRecordingSamples(id: candidate.id)
                    return (samples?.isEmpty == false) ? samples : nil
                }
            }
            var values: [[TindeqSample]] = []
            for await result in group {
                if let result { values.append(result) }
            }
            return values
        }

        return await Task.detached(priority: .userInitiated) {
            ForceCurveEngine.references(metadata: metadata, sampleSets: sampleSets)
        }.value
    }

    public func updateRecording(_ recording: TindeqRecording) async {
        await perform {
            let saved = try await self.repository.updateRecordingMeta(
                id: recording.id,
                tag: recording.tag,
                side: recording.side,
                note: recording.note
            )
            self.replaceRecording(saved)
        }
    }

    public func deleteRecording(_ recording: TindeqRecording) async {
        await perform {
            try await self.repository.softDeleteRecording(id: recording.id)
            self.recordings.removeAll { $0.id == recording.id }
        }
    }

    public func restoreRecording(_ recording: TindeqRecording) async {
        await perform {
            try await self.repository.restoreRecording(id: recording.id)
            self.deletedRecordings.removeAll { $0.id == recording.id }
            await self.refreshAll(showSpinner: false)
        }
    }

    public func purgeRecording(_ recording: TindeqRecording) async {
        await perform {
            try await self.repository.purgeRecording(id: recording.id)
            self.deletedRecordings.removeAll { $0.id == recording.id }
        }
    }

    public func linkRecordings(_ recordings: [TindeqRecording], to session: SendmeterCore.Session) async {
        let unlinked = recordings.filter { $0.groupID == nil }
        guard !unlinked.isEmpty else { return }
        await perform {
            try await self.repository.linkRecordingsToSession(
                sessionID: session.id,
                recordingIDs: unlinked.map(\.id)
            )
            for recording in unlinked {
                if let index = self.recordings.firstIndex(where: { $0.id == recording.id }) {
                    self.recordings[index].groupID = session.id
                }
            }
            self.toastMessage = "Force recordings linked."
        }
    }

    public func savePreset(_ preset: TindeqPreset, isNew: Bool) async {
        await perform {
            let saved = try await (isNew
                ? self.repository.insertPreset(preset)
                : self.repository.updatePreset(preset))
            self.presets.removeAll { $0.id == saved.id }
            self.presets.insert(saved, at: 0)
        }
    }

    public func deletePreset(_ preset: TindeqPreset) async {
        await perform {
            try await self.repository.deletePreset(id: preset.id)
            self.presets.removeAll { $0.id == preset.id }
        }
    }

    // MARK: Routines

    public func saveRoutine(_ routine: RoutinePreset, isNew: Bool) async {
        await perform {
            let saved = try await (isNew
                ? self.repository.insertRoutine(routine)
                : self.repository.updateRoutine(routine))
            self.routines.removeAll { $0.id == saved.id }
            self.routines.insert(saved, at: 0)
        }
    }

    public func deleteRoutine(_ routine: RoutinePreset) async {
        await perform {
            try await self.repository.deleteRoutine(id: routine.id)
            self.routines.removeAll { $0.id == routine.id }
        }
    }

    // MARK: Health and account

    public func syncHealth(requestAuthorization: Bool) async {
        guard let userID = currentUserID else { return }
        await perform {
            if requestAuthorization {
                try await self.health.requestAuthorization()
                UserDefaults.standard.set(true, forKey: "sendmeter.native.health-authorized")
            }
            let metric = try await self.health.computeTodayMetric(acwr: self.acwr.ratio)
            try await self.repository.upsertHealthMetric(metric, userID: userID)
            self.healthMetrics.removeAll { $0.date == metric.date }
            self.healthMetrics.insert(metric, at: 0)
            self.watch.publishReadiness(metric)
            self.toastMessage = "Apple Health synced."
        }
    }

    public func deleteAccount() async {
        guard let userID = currentUserID else { return }
        await perform {
            try await self.repository.deleteAccount()
            try await self.queue?.discardAll(accountUserID: userID, reason: "account-deleted")
            try await self.auth.signOut()
        }
    }

    // MARK: Offline queue

    public func drainQueue() async {
        guard let userID = currentUserID, let queue else { return }
        let due = await queue.items(for: userID, dueAt: Date())
        for item in due {
            await upload(item)
        }
        await refreshQueueCount()
    }

    public func retryAllQueuedWrites() async {
        guard let userID = currentUserID, let queue else { return }
        let pending = await queue.items(for: userID)
        for item in pending {
            await upload(item)
        }
        await refreshQueueCount()
    }

    @discardableResult
    private func enqueueAndUpload(_ item: DurableQueueItem<PendingWrite>) async -> Bool {
        guard let queue else {
            surface(NSError(
                domain: "SendmeterNative",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "On-device queue is unavailable."]
            ))
            return false
        }
        do {
            try await queue.enqueue(item)
            await refreshQueueCount()
            Task { [weak self] in
                await self?.upload(item)
            }
            return true
        } catch {
            surface(error)
            return false
        }
    }

    private func upload(_ item: DurableQueueItem<PendingWrite>) async {
        guard let queue, currentUserID == item.accountUserID else { return }
        do {
            switch item.payload {
            case let .session(payload):
                let saved = try await repository.insertSession(payload.draft, id: payload.id)
                pendingSessions.removeValue(forKey: payload.id)
                replaceSession(saved)
            case let .recording(recording):
                let saved = try await repository.insertRecording(recording)
                pendingRecordings.removeValue(forKey: recording.id)
                replaceRecording(saved)
            case let .workout(draft):
                let saved = try await repository.insertPhoneWorkout(draft)
                pendingSessions.removeValue(forKey: draft.sessionID)
                replaceSession(saved)
            }
            try await queue.remove(
                id: item.id,
                accountUserID: item.accountUserID,
                reason: "uploaded"
            )
            toastMessage = "Saved"
        } catch {
            do {
                try await queue.markFailure(
                    id: item.id,
                    accountUserID: item.accountUserID,
                    error: error.localizedDescription
                )
            } catch {
                surface(error)
            }
        }
        await refreshQueueCount()
    }

    private func refreshQueueCount() async {
        guard let userID = currentUserID, let queue else {
            queuedWriteCount = 0
            queueBreadcrumbs = []
            return
        }
        queuedWriteCount = await queue.count(for: userID)
        queueBreadcrumbs = await queue.breadcrumbs(for: userID)
    }

    // MARK: Watch completions

    private func acceptStoredWatchCompletions() async {
        for completion in watch.drainStoredCompletions() {
            await acceptWatchCompletion(completion)
        }
    }

    private func acceptWatchCompletion(_ completion: WatchWorkoutCompletion) async {
        guard let userID = currentUserID else { return }
        if let owner = completion.accountUserID, owner != userID { return }
        let pending = completion.pendingSession()
        guard !sessions.contains(where: { $0.id == pending.id && !$0.pending }) else { return }
        pendingSessions[pending.id] = pending
        mergeSessions(remote: sessions.filter { !$0.pending })
        do {
            let refreshed = try await repository.fetchSessions(accountUserID: userID)
            mergeSessions(remote: refreshed)
        } catch {
            // The watch queue is the durable source until its upload lands.
            // Keep the visible pending item rather than treating network delay
            // as a failed workout.
        }
    }

    // MARK: Live workout mirror (#626)

    /// WC beat → mirror cursor (fast path). The parse lives in Core
    /// (`liveWorkoutFromWCMessage`), so the transport stays dumb and the
    /// merge discipline is unit-tested.
    private func acceptLiveWorkoutMessage(_ message: [String: Any]) {
        guard let userID = currentUserID else { return }
        let nowMs = Date().timeIntervalSince1970 * 1_000
        guard let incoming = liveWorkoutFromWCMessage(
            message: message,
            previous: liveWorkoutMirror.row
        ) else { return }
        // #530-style ownership: a beat stamped with another account is
        // rejected; an un-stamped beat (pre-#530 watch build) is trusted —
        // the mirror resets to .empty on every account change, so there is
        // no stale cross-account state for it to pollute (#626 review).
        guard liveWorkoutOwnedBy(incoming, userID: userID, trustsUnstamped: true) else { return }
        acceptLiveWorkout(incoming, source: .watchDirect, nowMs: nowMs)
    }

    /// Realtime row → mirror cursor (fallback/authoritative reconciliation).
    /// Rows always carry `user_id`; a row owned by any other account is
    /// dropped before it can reduce into the mirror (#626 review).
    private func acceptLiveWorkoutRow(_ record: [String: Any]) {
        guard let userID = currentUserID else { return }
        let nowMs = Date().timeIntervalSince1970 * 1_000
        guard let incoming = liveWorkoutFromRow(record: record),
              liveWorkoutOwnedBy(incoming, userID: userID, trustsUnstamped: false)
        else { return }
        acceptLiveWorkout(incoming, source: .serverFallback, nowMs: nowMs)
    }

    private func acceptLiveWorkout(
        _ incoming: LiveWorkout,
        source: LiveWorkoutMirrorSource,
        nowMs: TimeInterval
    ) {
        let result = reduceLiveWorkoutMirror(
            state: liveWorkoutMirror,
            incoming: incoming,
            source: source,
            nowMs: nowMs
        )
        guard result.accepted else { return }
        liveWorkoutMirror = result.state
        publishLiveMirror(atMs: nowMs)
        restartLiveMirrorTickerIfNeeded()
    }

    private func publishLiveMirror(atMs: TimeInterval) {
        liveWorkout = visibleLiveWorkoutRow(liveWorkoutMirror, nowMs: atMs)
        liveWorkoutSyncState = SendmeterCore.liveWorkoutSyncState(for: liveWorkoutMirror, nowMs: atMs)
    }

    /// Authoritative initial/foreground row fetch, fed into the mirror as
    /// `server-fallback`. A dropped realtime connection degrades to WC beats
    /// + this refetch; the run/sequence cursor rejects anything older.
    /// Ownership is double-checked here even though RLS already scopes the
    /// query to the session user (#626 review).
    private func refreshLiveWorkoutRow() async {
        guard let userID = currentUserID else { return }
        do {
            if let row = try await repository.fetchLiveWorkout(),
               liveWorkoutOwnedBy(row, userID: userID, trustsUnstamped: false) {
                acceptLiveWorkout(
                    row,
                    source: .serverFallback,
                    nowMs: Date().timeIntervalSince1970 * 1_000
                )
            }
        } catch {
            // Silent degradation: the mirror keeps whatever it last accepted.
        }
    }

    /// Local staleness tick (5s, same cadence as the web's hook): re-derives
    /// the visible row and honest sync state without any network.
    private func restartLiveMirrorTickerIfNeeded() {
        guard authSession != nil else {
            liveMirrorTicker?.cancel()
            liveMirrorTicker = nil
            return
        }
        guard liveMirrorTicker == nil else { return }
        liveMirrorTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled, self.authSession != nil else { return }
                self.publishLiveMirror(atMs: Date().timeIntervalSince1970 * 1_000)
            }
        }
    }

    // MARK: Realtime list reconciliation (#626)

    /// A watched table changed on the server: map it to its data slice and
    /// schedule a coalesced targeted refresh (trailing-edge debounce, ~400ms).
    /// Never a full refetch and never a second polling loop.
    private func acceptRealtimeListEvent(_ table: RealtimeTable) {
        guard authSession != nil else { return }
        // Unknown tables never reach here (RealtimeTable is the allow-list);
        // `reconcileSlice(for:)` maps each watched table to its data slice.
        reconcileCoalescer.record(
            reconcileSlice(for: table),
            atMs: Date().timeIntervalSince1970 * 1_000
        )
        scheduleReconcileFlush()
    }

    private func scheduleReconcileFlush() {
        guard reconcileFlushTask == nil else { return }
        reconcileFlushTask = Task { [weak self] in
            guard let self else { return }
            await self.waitForReconcileWindow()
            await self.flushRealtimeRefreshes()
        }
    }

    private func waitForReconcileWindow() async {
        while !Task.isCancelled {
            let atMs = Date().timeIntervalSince1970 * 1_000
            let remainingMs = reconcileCoalescer.remainingMs(atMs: atMs)
            if remainingMs <= 0 { return }
            try? await Task.sleep(nanoseconds: UInt64(remainingMs * 1_000_000))
        }
    }

    private func flushRealtimeRefreshes() async {
        reconcileFlushTask = nil
        let atMs = Date().timeIntervalSince1970 * 1_000
        if let slices = reconcileCoalescer.takeReadySlices(atMs: atMs), !slices.isEmpty {
            await refreshReconcileSlices(slices)
        }
        // The window may have re-opened while we were fetching (a burst kept
        // extending) — chain another flush instead of dropping the tail.
        if reconcileCoalescer.isWaiting {
            scheduleReconcileFlush()
        }
    }

    private func refreshReconcileSlices(_ slices: Set<ReconcileSlice>) async {
        guard let userID = currentUserID else { return }
        do {
            if slices.contains(.sessions) {
                mergeSessions(remote: try await repository.fetchSessions(accountUserID: userID))
            }
            if slices.contains(.recordings) {
                mergeRecordings(remote: try await repository.fetchRecordings())
            }
            if slices.contains(.workouts) {
                workouts = try await repository.fetchWorkouts()
            }
            if slices.contains(.health) {
                healthMetrics = try await repository.fetchHealthMetrics()
            }
        } catch {
            // Silent degradation, same as the web: a failed reconcile leaves
            // the list stale until the next event or pull-to-refresh.
        }
    }

    private func tearDownRealtime() async {
        liveMirrorTicker?.cancel()
        liveMirrorTicker = nil
        liveWorkoutMirror = .empty
        liveWorkout = nil
        liveWorkoutSyncState = .unknown
        reconcileFlushTask?.cancel()
        reconcileFlushTask = nil
        reconcileCoalescer.reset()
        await realtime.unsubscribe()
    }

    // MARK: Helpers

    private func restorePendingWrites(
        userID: UUID,
        remoteSessionIDs: Set<UUID>,
        remoteRecordingIDs: Set<UUID>
    ) async {
        guard let queue else { return }
        let queued = await queue.items(for: userID)
        for item in queued {
            switch item.payload {
            case let .session(payload):
                guard !remoteSessionIDs.contains(payload.id) else { continue }
                pendingSessions[payload.id] = pendingSession(
                    id: payload.id,
                    draft: payload.draft,
                    accountUserID: userID
                )
            case let .workout(draft):
                guard !remoteSessionIDs.contains(draft.sessionID) else { continue }
                pendingSessions[draft.sessionID] = pendingSession(from: draft)
            case let .recording(recording):
                guard !remoteRecordingIDs.contains(recording.id) else { continue }
                pendingRecordings[recording.id] = pendingRecording(from: recording)
            }
        }
    }

    private func pendingSession(
        id: UUID,
        draft: SessionDraft,
        accountUserID: UUID
    ) -> SendmeterCore.Session {
        SendmeterCore.Session(
            id: id,
            date: draft.date,
            type: draft.type,
            typeLabel: draft.typeLabel,
            durationMinutes: draft.durationMinutes,
            rpe: draft.rpe,
            note: draft.note,
            phase: draft.phase,
            pending: true,
            accountUserID: accountUserID
        )
    }

    private func pendingSession(from draft: WorkoutDraft) -> SendmeterCore.Session {
        let endedAt = draft.endedAt ?? Date()
        let count = draft.attempts.count
        return SendmeterCore.Session(
            id: draft.sessionID,
            date: LocalDateSupport.string(from: endedAt),
            type: draft.type,
            typeLabel: draft.typeLabel,
            durationMinutes: max(1, Int(ceil(endedAt.timeIntervalSince(draft.startedAt) / 60))),
            rpe: draft.rpe,
            rpeConfirmed: true,
            note: "\(count) boulder\(count == 1 ? "" : "s")",
            phase: draft.phase,
            workoutSource: .phone,
            pending: true,
            accountUserID: draft.accountUserID
        )
    }

    private func pendingRecording(from recording: NewTindeqRecording) -> TindeqRecording {
        TindeqRecording(
            id: recording.id,
            recordedAt: recording.recordedAt,
            durationMilliseconds: recording.durationMilliseconds,
            peakKilograms: recording.peakKilograms,
            averageKilograms: recording.averageKilograms,
            sampleCount: recording.samples.count,
            note: recording.note,
            tag: recording.tag,
            side: recording.side,
            groupID: recording.groupID,
            protocolRunID: recording.protocolRunID,
            setNumber: recording.setNumber,
            zone: recording.zone,
            source: recording.source,
            externalLoadKilograms: recording.externalLoadKilograms,
            outcome: recording.outcome,
            plannedDurationMilliseconds: recording.plannedDurationMilliseconds,
            actualDurationMilliseconds: recording.actualDurationMilliseconds,
            repetitionNumber: recording.repetitionNumber,
            protocolMode: recording.protocolMode,
            targetKilograms: recording.targetKilograms,
            targetLowKilograms: recording.targetLowKilograms,
            targetHighKilograms: recording.targetHighKilograms,
            cadenceOutSeconds: recording.cadenceOutSeconds,
            cadenceReturnSeconds: recording.cadenceReturnSeconds,
            cadenceMarkers: recording.cadenceMarkers,
            setMetrics: recording.setMetrics,
            setupNote: recording.setupNote,
            capacityEvidence: recording.capacityEvidence,
            completedRepetitions: recording.completedRepetitions,
            completionStatus: recording.completionStatus
        )
    }

    private func mergeRecordings(remote: [TindeqRecording]) {
        let remoteIDs = Set(remote.map(\.id))
        for id in remoteIDs { pendingRecordings.removeValue(forKey: id) }
        recordings = (remote + pendingRecordings.values.filter { !remoteIDs.contains($0.id) })
            .sorted { $0.recordedAt > $1.recordedAt }
    }

    private func mergeSessions(remote: [SendmeterCore.Session]) {
        let remoteIDs = Set(remote.map(\.id))
        for id in remoteIDs { pendingSessions.removeValue(forKey: id) }
        sessions = (remote + pendingSessions.values.filter { !remoteIDs.contains($0.id) })
            .sorted {
                if $0.date != $1.date { return $0.date > $1.date }
                return $0.id.uuidString > $1.id.uuidString
            }
    }

    private func replaceSession(_ session: SendmeterCore.Session) {
        pendingSessions.removeValue(forKey: session.id)
        sessions.removeAll { $0.id == session.id }
        sessions.append(session)
        sessions.sort {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString > $1.id.uuidString
        }
    }

    private func replaceRecording(_ recording: TindeqRecording) {
        recordings.removeAll { $0.id == recording.id }
        recordings.append(recording)
        recordings.sort { $0.recordedAt > $1.recordedAt }
    }

    private func clearLoadedData() {
        sessions = []
        deletedSessions = []
        deletedRecordings = []
        healthMetrics = []
        phasePeriods = []
        recordings = []
        presets = []
        routines = []
        workouts = []
        pendingSessions = [:]
        pendingRecordings = [:]
        queuedWriteCount = 0
        queueBreadcrumbs = []
    }

    private func perform(_ operation: @escaping () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            surface(error)
        }
    }

    private func surface(_ error: Error) {
        errorMessage = error.localizedDescription
    }
}
