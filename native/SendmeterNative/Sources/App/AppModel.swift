@_spi(Experimental) import Auth
import Combine
import Foundation
import Observation
import SendLogHealthCore
import SendLogWatchCore
import SendmeterCore
import SendmeterWeather
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

public struct NativeAccountScope: Equatable, Sendable {
    public let userID: UUID?
    public let epoch: UInt64

    public init(userID: UUID?, epoch: UInt64) {
        self.userID = userID
        self.epoch = epoch
    }
}

private enum PendingWrite: Codable, Sendable {
    case session(SessionQueuePayload)
    case sessionDelete(SessionDeleteQueuePayload)
    case recording(NewTindeqRecording)
    case recordingEdit(RecordingEdit)
    case sessionRPEEdit(RecordingEdit)
    case recordingDelete(RecordingDeleteQueuePayload)
    case workout(WorkoutDraft)
}

/// #675: the Settings-facing summary of one quarantined write. A separate
/// public type on purpose: the queue payload (`PendingWrite`) is AppModel-
/// private, and the surface needs only a stable identity, a description, and
/// the rejection stamp — not the raw samples.
public struct QuarantinedWrite: Identifiable, Sendable {
    public let id: UUID
    public let accountUserID: UUID
    public let createdAt: Date
    public let kind: String
    public let attempts: Int
    public let rejection: QueueRejection
    public let lastError: String?
}

private extension DurableQueueItem where Payload == PendingWrite {
    func summary() -> QuarantinedWrite {
        let kind: String
        switch payload {
        case .session: kind = "Session"
        case .sessionDelete: kind = "Session deletion"
        case .recording: kind = "Force recording"
        case .recordingEdit: kind = "Force recording edit"
        case .sessionRPEEdit: kind = "Session RPE edit"
        case .recordingDelete: kind = "Force recording deletion"
        case .workout: kind = "Manual workout"
        }
        return QuarantinedWrite(
            id: id,
            accountUserID: accountUserID,
            createdAt: createdAt,
            kind: kind,
            attempts: attempts,
            rejection: quarantined ?? QueueRejection(
                kind: .permanent,
                code: nil,
                detail: lastError ?? ""
            ),
            lastError: lastError
        )
    }
}

private struct SessionQueuePayload: Codable, Sendable {
    let id: UUID
    let draft: SessionDraft
    /// False for a #627 W'-depletion prediction (or its fallback) that
    /// nobody reviewed — #114's column. Optional so pre-existing queue
    /// entries (which predate the field) decode as the human-confirmed
    /// default.
    let rpeConfirmed: Bool?
    /// Links the session back to its gauge-session recordings.
    let groupID: UUID?
}

private struct SessionDeleteQueuePayload: Codable, Sendable {
    let sessionID: UUID
}

/// Durable terminal delete intent. The pre-edit session value is carried in
/// the intent so a relaunch can compensate an RPE PATCH before the recording
/// delete is retried; no in-memory snapshot is required for correctness.
private struct RecordingDeleteQueuePayload: Codable, Sendable {
    let recordingID: UUID
    let operationID: UUID
    let sessionID: UUID?
    let previousSessionRPE: Double?
    let previousSessionRPEConfirmed: Bool?
    /// The ordering claim whose optimistic RPE is being compensated. Optional
    /// for queue files written before delete compensation was made durable.
    let compensationOrderingKey: UInt64?
    /// Persisted progress prevents a retry from repeating an already-applied
    /// compensation; a newer session claim can mark it superseded instead.
    let compensationState: RecordingDeleteCompensationState?
}

private struct LegacyRecordingEditMigrationFlight {
    let id: UUID
    let accountFetch: AccountScopedFetch
    let task: Task<[DurableQueueItem<PendingWrite>]?, Never>
}

/// The free-pull recording context the hands-free loop snapshots when a rep
/// stops: tag/side/zone/preset resolved on the Force tab at arm time.
public struct FreePullContext: Sendable, Equatable {
    public var tag: String
    public var side: TindeqSide
    public var zone: RecordedZone?
    public var preset: TindeqPreset?
    public var targetBand: ForceTargetBand?

    public init(
        tag: String = "",
        side: TindeqSide = .unspecified,
        zone: RecordedZone? = nil,
        preset: TindeqPreset? = nil,
        targetBand: ForceTargetBand? = nil
    ) {
        self.tag = tag
        self.side = side
        self.zone = zone
        self.preset = preset
        self.targetBand = targetBand
    }
}

private typealias TagCurveKey = TagCurveCacheKey

private struct CacheEntityIdentity: Hashable {
    let entityType: LocalCacheEntityType
    let entityID: String
}

@MainActor
@Observable
public final class AppModel {
    public private(set) var bootState: AppBootState = .loading
    public private(set) var authSession: AuthSession?
    public private(set) var sessions: [SendmeterCore.Session] = []
    /// True once the session list has been fetched at least once for the
    /// current account (even if it came back empty). Sessions have no disk
    /// cache — `refreshAll` fetches them over the network and `sessions` stays
    /// `[]` until that resolves — so `sessions.isEmpty` alone cannot tell "no
    /// history" from "not loaded yet". Consumers (the ACWR projection card)
    /// use this to avoid claiming a fresh user has no history on every cold
    /// launch or failed refresh (#652 F2).
    public private(set) var hasLoadedSessions = false
    public private(set) var deletedSessions: [SendmeterCore.Session] = []
    public private(set) var deletedRecordings: [TindeqRecording] = []
    public private(set) var healthMetrics: [HealthMetric] = []
    public private(set) var phasePeriods: [PhasePeriod] = []
    public private(set) var settings = UserSettings(
        currentPhase: .capacity,
        phaseStartDate: LocalDateSupport.string(from: Date())
    )
    /// The shared force-recording list. It is read by the Force tab, History,
    /// and Settings; a fresh account resets it via `resetAccountState()`. The
    /// force-scoped "has loaded" flag lives on `ForceModel` (see
    /// `ForceModel.hasLoadedRecordings`).
    public private(set) var recordings: [TindeqRecording] = []
    /// O(1) progress-input identity for the tiles, detail sheets, and selected
    /// Static curve. This is observed only at actual progress mutation
    /// boundaries; live Tindeq display frames do not advance it.
    public private(set) var presets: [TindeqPreset] = []
    public private(set) var routines: [RoutinePreset] = []
    public private(set) var workouts: [WorkoutListItem] = []
    public private(set) var liveWorkout: LiveWorkout?
    public private(set) var liveWorkoutSyncState: LiveWorkoutSyncState = .unknown
    /// #631: the per-user tag registry (SL-92) — rename/hide metadata. Tags
    /// themselves stay denormalized on recordings.
    public private(set) var tagMetadata: [TagMetadata] = []
    /// #720: the device-local side mode per exercise tag (web parity for the
    /// concept, deliberately NOT account-migrated). Keyed by the trimmed tag
    /// name; a tag with no entry reads as the default (`unilateral_or_bilateral`).
    public private(set) var tagSideModes: [String: ExerciseSideMode] = [:]
    /// #712: the passkeys registered for the signed-in user. Loaded on
    /// auth-ready and whenever Settings opens, and refreshed after a register
    /// or remove — so a registration shows up as a persistent list entry and
    /// count, not just a transient toast.
    // #712 @_spi(Experimental) PasskeyListItem cannot appear in a `public`
    // property declaration, so this stays internal (SettingsView is in the
    // same target and reads it via the internal getter).
    private(set) var passkeys: [PasskeyListItem] = []
    public private(set) var isRefreshing = false
    public private(set) var queuedWriteCount = 0
    /// Unconfirmed cache rows for direct writes that have no durable replay
    /// after process death (presets, routines, phase/settings, tag metadata).
    /// Kept separate from `queuedWriteCount` so Settings can label them as
    /// unsynced rather than as automatically retried queue work.
    public private(set) var pendingCacheWriteCount = 0
    public private(set) var queueBreadcrumbs: [QueueBreadcrumb] = []
    /// #675: entries the server has permanently rejected — retained on device,
    /// excluded from every automatic retry, and recoverable only by the
    /// explicit Retry/Discard actions in Settings. `nil` means the queue has
    /// not been read yet this session; `[]` means genuinely nothing
    /// quarantined. Never default to `[]` where the honest state is "not
    /// known" (#269 honest-states rule — unknown must not render as empty).
    public private(set) var quarantinedWrites: [QuarantinedWrite]?
    public var errorMessage: String?
    public private(set) var toast: AppToastState?
    /// Compatibility accessors keep existing call sites readable while the
    /// observed source of truth is one identity-bearing toast instance.
    /// Setting the action creates a fresh instance too, so a passive toast
    /// cannot keep its two-second task when it becomes actionable.
    public var toastMessage: String? {
        get { toast?.message }
        set {
            if let newValue {
                toast = AppToastState(message: newValue)
            } else {
                toast = nil
            }
        }
    }
    public var toastAction: AppToastAction? {
        get { toast?.action }
        set {
            guard let current = toast else { return }
            toast = AppToastState(message: current.message, action: newValue)
        }
    }

    public func dismissToast(id: UUID? = nil) {
        guard id == nil || toast?.id == id else { return }
        toast = nil
    }
    public var passwordRecovery = false
    public var selectedTab: AppTab = .dashboard
    /// The Force owner registers this while a guided run exists, including
    /// while its fullscreen is minimized. Auth teardown calls it before
    /// revoking the old bearer token so an active pull can be preserved under
    /// the old account scope.
    private var guidedProtocolTeardown: (@MainActor () async -> Void)?
    private var guidedProtocolTeardownOwnerID: UUID?
    /// #632: true while a user-initiated sign-out is in flight (drain + any
    /// remainder prompt + auth.signOut) — used to disable the Sign Out button
    /// so a double-tap can't run two drains against one queue.
    public private(set) var isSigningOut = false
    /// #632: non-nil while the sign-out remainder prompt is showing — the
    /// count the user is deciding about, presented by SettingsView as a
    /// confirmation dialog (Sign Out / Cancel) and resolved through
    /// `resolveSignOutRemainder`. The prompt appears ONLY when the pre-sign-
    /// out drain left something behind; a clean drain never asks.
    public private(set) var signOutRemainderCount: Int?
    private var signOutRemainderContinuation: CheckedContinuation<SignOutRemainderChoice, Never>?

    @ObservationIgnored public let auth: AuthService
    @ObservationIgnored public let repository: SendmeterRepository
    @ObservationIgnored public let tindeq: TindeqBluetooth
    @ObservationIgnored private let healthService: HealthKitService
    @ObservationIgnored private let watchService: WatchConnectivityService
    @ObservationIgnored public let realtime: RealtimeService
    /// #631: Send Conditions (SL-69) — Open-Meteo current weather + local
    /// climate, fetched + cached by the platform service.
    @ObservationIgnored private let weatherService: WeatherService
    /// #628: hands-free arming loop (load-triggered start/stop/save).
    @ObservationIgnored private let handsFreeService: HandsFreeForceController
    /// #628: lock-screen Live Activity mirror of the guided protocol.
    public let guidedActivity: GuidedProtocolActivityManager
    /// #627: in-flight rep saves the session-end snapshot waits for.
    public let gaugeSessionSaveGate: GaugeSessionSaveGate
    /// #628: refcounted screen keep-awake while connected/armed/measuring.
    public let keepAwake: KeepAwakeCoordinator
    /// #708: owns the Manual workout rest deadline outside the fullscreen
    /// presentation so minimize/background transitions cannot suspend it.
    public let manualWorkoutRest: ManualWorkoutRestScheduler
    /// #763: lock-screen Live Activity mirror of the Manual workout.
    public let manualWorkoutActivity: ManualWorkoutActivityManager
    /// #672: the Force tab's hot, feature-scoped observable state. Kept as a
    /// dedicated object (not an observed property on `AppModel`) so a force-stream
    /// publish no longer invalidates History/Dashboard/Settings bodies.
    public let forceModel: ForceModel

    /// The legacy platform services remain Combine-based because their
    /// deployment floors include iOS 16/macOS 13; the hands-free controller is
    /// kept as a Foundation/Core type for the same package-floor reason. These
    /// revisions are the Observation bridge: a view that reads `model.watch`,
    /// `model.health`, `model.weather`, or `model.handsFree` tracks only that
    /// service's token, not the entire AppModel.
    private var healthObservationRevision: UInt64 = 0
    private var watchObservationRevision: UInt64 = 0
    private var weatherObservationRevision: UInt64 = 0
    private var handsFreeObservationRevision: UInt64 = 0

    public var health: HealthKitService {
        let _ = healthObservationRevision
        return healthService
    }

    public var watch: WatchConnectivityService {
        let _ = watchObservationRevision
        return watchService
    }

    public var weather: WeatherService {
        let _ = weatherObservationRevision
        return weatherService
    }

    public var handsFree: HandsFreeForceController {
        let _ = handsFreeObservationRevision
        return handsFreeService
    }

    public private(set) var gaugeSessionTracker = GaugeSessionTracker()
    public var freePullContext = FreePullContext()

    /// #678: the full force context LOCKED when the current recording began —
    /// captured once by ForceView at a manual Start / hands-free Arm. The
    /// disconnect-salvage save writes the tag/side from this lock, so a
    /// recovered rep persists what the user actually set at recording start,
    /// never a fallback (web #298). Distinct from `freePullContext`, which
    /// keeps tracking the visible pickers; this one is frozen for the rep.
    public private(set) var forceRecordingLock: FreePullContext?

    /// #678: lock the force context at recording start. Called only by
    /// ForceView at the manual-Start / hands-free-Arm gesture — NOT from the
    /// `onChange` of the visible pickers — so it overwrites the previous rep's
    /// lock with this rep's, and a mid-recording tag/side nudge can never move
    /// the attribution of the in-flight rep (web #298).
    public func lockForceRecordingContext(_ context: FreePullContext) {
        forceRecordingLock = context
    }

    /// #678: release the lock once the recording it owned has ended (saved or
    /// reported lost). The next recording start locks a fresh context.
    public func clearForceRecordingLock() {
        forceRecordingLock = nil
    }

    /// #678: true from the moment the disconnect-salvage claims the
    /// interrupted buffer until its save settles, so a duplicate
    /// `.interrupted` emission (#656: a single Bluetooth-off delivers two
    /// `.interrupted` values) cannot queue a second salvage for the same rep.
    private var disconnectSalvageInFlight = false

    /// #656 (review F1): the one way a user asks to connect the Progressor.
    /// Marks the transport as user-initiated for THIS LAUNCH so the
    /// success/error haptics in the `$status` sink may fire — a cold launch
    /// with Bluetooth off has no user gesture behind it and must stay silent.
    public func requestConnect() {
        transportUserInitiated = true
        tindeq.connect()
    }

    private let queue: DurableQueue<PendingWrite>?
    private let cachedWorkspace: CachedWorkspace?
    /// Set when the local cache file opens or first reads. Kept separate from
    /// the queue's own diagnostics because a cache failure must degrade to the
    /// network-only path without looking like an auth failure.
    private var cacheOpenFailureReported = false
    /// These handles are lifecycle infrastructure, not observable app state.
    /// Task cancellation is a thread-safe, idempotent signal: deinit does not
    /// await the task or touch task-local state. Keep creation, replacement,
    /// and ordinary cancellation on MainActor; the narrow
    /// `nonisolated(unsafe)` annotation only lets the language-mandated
    /// nonisolated deinit send that final cancellation signal. Object lifetime
    /// prevents an instance method from racing deinit after the last strong
    /// owner is gone.
    @ObservationIgnored
    private nonisolated(unsafe) var authObservationTask: Task<Void, Never>?
    private var pendingSessions: [UUID: SendmeterCore.Session] = [:]
    private var pendingRecordings = PendingRecordingOverlay()
    /// Metadata edits are overlays until the narrow PATCH has landed. Keeping
    /// them separate from insert placeholders means a refresh/relaunch cannot
    /// replace a just-edited tag/side with an older server row.
    private var pendingRecordingEdits: [UUID: RecordingEdit] = [:]
    private var pendingSessionRPEEdits: [UUID: RecordingEdit] = [:]
    /// The server-valued session snapshot underneath an optimistic RPE edit.
    /// Delete uses it for both the immediate UI rollback and the compensating
    /// narrow PATCH after an already-started request has settled.
    private var pendingSessionRPEBases: [UUID: SendmeterCore.Session] = [:]
    /// Delete waits on every session-RPE request that claimed its lane before
    /// the tombstone/barrier. Continuations are resumed by the last claim's
    /// defer, so the delete never races the compensation PATCH.
    private var sessionRPEWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    /// Restore waits for an already-claimed delete upload to settle before
    /// sending the compensating backend request. New delete uploads observe
    /// the coordinator's restore gate and cannot start in the meantime.
    private var queueUploadWaiters: [QueueUploadKey: [CheckedContinuation<Void, Never>]] = [:]
    /// Legacy queue migration is single-flight per account. Without this, two
    /// re-entrant callers can each snapshot the same combined item and the
    /// older one can rewrite the stable session identity after the newer save.
    private var legacyMigrationFlights: [UUID: LegacyRecordingEditMigrationFlight] = [:]
    /// The session-RPE revision and delete tombstone live in one coordinator;
    /// this keeps every async response's decision tied to current, actor-free
    /// state on the main actor rather than to a stale task closure.
    private var recordingEditCoordinator = RecordingEditCoordinator()
    /// Routine Undo claims are keyed by both account and session. The matching
    /// delete intent is persisted in the same queue as inserts; keeping the
    /// claim before the first await lets an in-flight upload reconcile without
    /// resurrecting the exact row the user removed.
    private var routineUndo = RoutineUndoState()
    /// Uploads are single-flight per account/item. Queue reads are snapshots;
    /// this synchronous claim prevents an insert completion, a drain, and an
    /// Undo follow-up from all sending the same item concurrently. The claim
    /// token makes a late release from an older account task unable to remove
    /// a newer claim after an account switch.
    private var inFlightUploadClaims = QueueUploadClaimCoordinator()
    private var nestedCancellables = Set<AnyCancellable>()
    private var didBootstrapUserID: UUID?
    /// Increments whenever the loaded account state is reset. User IDs alone
    /// cannot reject a stale A completion after an A→B→A transition.
    public private(set) var accountEpoch: UInt64 = 0
    private var refreshingOwner: AccountScopedCompletion?
    private var recomputeGate = ReadinessRecomputeGate()
    /// #661: silent foreground/appear health sync. The policy is pure Core
    /// (`HealthRefreshPolicy`, unit-tested); `lastHealthRefreshStartedAt` is
    /// the monotonic system-uptime time the most recent actual refresh started
    /// (never wall-clock — an NTP step or manual clock change must not suppress
    /// every refresh for the skew, finding 7). The window mirrors the web's
    /// `FOREGROUND_SYNC_COALESCE_MS` (5s).
    private let healthRefreshPolicy = HealthRefreshPolicy(coalescingWindow: 5)
    private var lastHealthRefreshStartedAt: TimeInterval?
    /// #673: the gate that decides whether a scenePhase → `.active`
    /// transition runs the 9-table authoritative `refreshAll`. The policy is
    /// pure Core (`ForegroundRefreshPolicy`, unit-tested); the window is the
    /// no-change grace period — a foreground inside it with data loaded and
    /// realtime healthy issues 0 full-table fetches. `lastListRefreshAt` is
    /// MONOTONIC (`systemUptime`), never wall-clock, so an NTP step or manual
    /// clock change cannot make the delta negative and suppress every refresh.
    private let foregroundRefreshPolicy = ForegroundRefreshPolicy(staleAfter: 60)
    private var lastListRefreshAt: TimeInterval?
    /// #656: the previously observed transport status, so the connect
    /// success / drop error haptics fire once per transition (never when
    /// `stopMeasuring()` re-sets `.connected` after a rep).
    private var lastTransportStatus: TindeqBluetooth.Status?
    /// #656: the transport may only cue success/error once the user has
    /// initiated a connection THIS LAUNCH (review F1) — a cold launch with
    /// Bluetooth off must not buzz an unsolicited `.error` on the Dashboard,
    /// and the issue's own guard column ("only when presented by a tap")
    /// exists for exactly this class.
    private var transportUserInitiated = false
    /// #656: the last transport cue played, so one Bluetooth-off event — iOS
    /// delivers BOTH a `.poweredOff` `.interrupted` AND a `didDisconnect`
    /// `.interrupted` with a different message — collapses to one buzz
    /// (review F2, "one tick per gesture").
    private var lastTransportCue: HapticCue?

    /// Live workout mirror cursor (two producers: WC beat + realtime row,
    /// one merge discipline — see LiveWorkoutMirror).
    private var liveWorkoutMirror = LiveWorkoutMirrorState.empty
    @ObservationIgnored
    private nonisolated(unsafe) var liveMirrorTicker: Task<Void, Never>?
    /// Realtime list reconciliation: pending slices + the scheduled flush.
    private let reconcileCoalescer = RealtimeRefreshCoalescer()
    @ObservationIgnored
    private nonisolated(unsafe) var reconcileFlushTask: Task<Void, Never>?
    private var tagCurveCache: [TagCurveKey: TagForceCurve] = [:]
    private var tagCurveGenerations = TagCurveCacheGenerationIndex()
    private var tagCurveBandGenerations: [TagCurveKey: UInt64] = [:]
    private var keepAwakeRelease: (() -> Void)?
    private var tagCurveWarmTasks: [TagCurveKey: Task<Void, Never>] = [:]
    private var tagCurveWarmTaskGenerations: [TagCurveKey: UInt64] = [:]
    /// Samples for optimistic rows (and restored queue rows) are retained
    /// separately because TindeqRecording is metadata-only. This is what lets
    /// the point-estimate RPE fit include a just-saved rep before its network
    /// insert has reconciled.
    private var pendingCurveSamples: [UUID: [TindeqSample]] = [:]
    private var forceProgressInputRevision = ForceProgressInputRevision()

    private func publishForceProgressInputMutation(_ mutation: ForceProgressInputMutation) {
        let revision = forceProgressInputRevision.apply(mutation)
        forceModel.forceProgressRevision = revision
    }

    private func storePendingCurveSamples(_ samples: [TindeqSample], for id: UUID) {
        pendingCurveSamples[id] = samples
        publishForceProgressInputMutation(.localSamples)
    }

    private func removePendingCurveSamples(for id: UUID) {
        guard pendingCurveSamples.removeValue(forKey: id) != nil else { return }
        publishForceProgressInputMutation(.localSamples)
    }

    private func clearPendingCurveSamples() {
        guard !pendingCurveSamples.isEmpty else { return }
        pendingCurveSamples.removeAll()
        publishForceProgressInputMutation(.localSamples)
    }

    private func insertPendingRecording(_ recording: TindeqRecording, accountUserID: UUID) {
        let before = pendingRecordings.recordings(accountUserID: accountUserID)
        let beforeIDs = pendingRecordings.ids(accountUserID: accountUserID)
        pendingRecordings.insert(recording, accountUserID: accountUserID)
        let after = pendingRecordings.recordings(accountUserID: accountUserID)
        guard beforeIDs != pendingRecordings.ids(accountUserID: accountUserID)
            || ForceProgress.progressInputsChanged(before: before, after: after)
        else { return }
        publishForceProgressInputMutation(.pendingRecordings)
    }

    private func removePendingRecording(for id: UUID, accountUserID: UUID) {
        guard pendingRecordings.contains(id: id, accountUserID: accountUserID) else { return }
        pendingRecordings.removeValue(for: id, accountUserID: accountUserID)
        publishForceProgressInputMutation(.pendingRecordings)
    }

    private func removePendingRecordings(withIDs ids: Set<UUID>, accountUserID: UUID) {
        let before = pendingRecordings.ids(accountUserID: accountUserID)
        pendingRecordings.removeValues(withIDs: ids, accountUserID: accountUserID)
        guard before != pendingRecordings.ids(accountUserID: accountUserID) else { return }
        publishForceProgressInputMutation(.pendingRecordings)
    }

    public init(
        auth: AuthService? = nil,
        repository: SendmeterRepository? = nil,
        tindeq: TindeqBluetooth? = nil,
        health: HealthKitService? = nil,
        watch: WatchConnectivityService? = nil,
        realtime: RealtimeService? = nil,
        weather: WeatherService? = nil
    ) {
        // The services' initializers are MainActor-isolated; default-argument
        // expressions are nonisolated, so they must be constructed here in
        // the (MainActor) body instead of in the parameter list.
        self.auth = auth ?? AuthService()
        // #679: wire the repository's PostgREST transport through the single
        // session-freshness guard so EVERY token-bearing call goes through
        // `ensureFreshSession()` before it reads a bearer token. A caller that
        // injects a repository (tests / previews) keeps its own transport.
        if let repository {
            self.repository = repository
        } else {
            let authRef = self.auth
            self.repository = SendmeterRepository(
                transport: PostgRESTClient(
                    authClient: authRef.client.auth,
                    sessionProvider: { try await authRef.ensureFreshSession() }
                )
            )
        }
        self.tindeq = tindeq ?? TindeqBluetooth()
        self.healthService = health ?? HealthKitService()
        self.watchService = watch ?? WatchConnectivityService()
        self.realtime = realtime ?? RealtimeService()
        self.weatherService = weather ?? WeatherService()
        self.handsFreeService = HandsFreeForceController()
        self.guidedActivity = GuidedProtocolActivityManager()
        self.gaugeSessionSaveGate = GaugeSessionSaveGate()
        self.manualWorkoutRest = ManualWorkoutRestScheduler()
        self.manualWorkoutActivity = .shared
        self.forceModel = ForceModel()
        self.keepAwake = KeepAwakeCoordinator { active in
            await MainActor.run {
                UIApplication.shared.isIdleTimerDisabled = active
            }
        }

        // #720: device-local per-tag side modes (loaded once; unconfigured tags
        // read as the default via `sideMode(for:)`). Deliberately not fetched
        // from the account — the native app keeps them on-device.
        self.tagSideModes = TagSideModeStore.allStoredModes()

        // #747 review note: LocalCacheStore init opens GRDB and runs migrations
        // synchronously on the main actor during AppModel init. This is on the
        // launch path and is acceptable for slice 2, but should be profiled on
        // device and deferred off the main actor if cold-start cost matters.
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("SendmeterNative", isDirectory: true)
        if let support {
            do {
                try FileManager.default.createDirectory(
                    at: support,
                    withIntermediateDirectories: true
                )
                let store = try LocalCacheStore(
                    databaseURL: support.appendingPathComponent(
                        "local-cache.sqlite",
                        isDirectory: false
                    )
                )
                cachedWorkspace = CachedWorkspace(store: store)
            } catch {
                cachedWorkspace = nil
                cacheOpenFailureReported = true
                self.auth.recordAuthEvent(
                    .failure,
                    detail: "Local cache unavailable: \(error.localizedDescription)"
                )
            }
            self.queue = try? DurableQueue(
                directoryURL: support,
                filename: "pending-writes.json",
                breadcrumbLimit: 10
            )
        } else {
            cachedWorkspace = nil
            self.queue = nil
        }

        let watch = self.watchService
        let realtime = self.realtime
        let tindeq = self.tindeq
        let auth = self.auth
        let weather = self.weatherService
        let health = self.healthService

        watch.onSessionRequested = { [weak self] in
            await self?.relayValidSessionToWatch(guaranteed: true)
        }
        watch.onWorkoutCompletion = { [weak self] completion in
            await self?.acceptWatchCompletion(completion)
        }
        // A background HealthKit observer fire and foreground sync share the
        // same single-flight recompute path (see computeAndPublishReadiness).
        self.health.onBackgroundUpdate = { [weak self] in
            await self?.handleHealthBackgroundUpdate()
        }

        // Observer queries are per-process: a cold launch — including a
        // HealthKit background wake that relaunches the app — must
        // re-register before delivery can fire. Guarded by the same
        // health-authorized flag as becameActive's sync.
        if UserDefaults.standard.bool(forKey: "sendmeter.native.health-authorized") {
            Task { [weak self] in
                await self?.health.ensureBackgroundObserversRegistered()
            }
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

        // Hands-free arming loop wiring: the controller stays pure (Core);
        // the device + save hooks are AppModel's.
        handsFree.onArmStream = { [weak self] in self?.armHandsFreeStream() }
        handsFree.onDisarmStream = { [weak self] in self?.tindeq.disarmHandsFree() }
        handsFree.onBeginRecording = { [weak self] in _ = self?.tindeq.beginArmedRecording() }
        handsFree.onStopAndSave = { [weak self] in self?.completeHandsFreeRep() }
        handsFree.onAutoReArm = { [weak self] in self?.armHandsFreeStream() }
        handsFree.onStateChange = { [weak self] in
            self?.handsFreeObservationRevision &+= 1
        }
        tindeq.onWeightSample = { [weak self] sample in
            self?.handsFree.feed(
                atMs: Date().timeIntervalSince1970 * 1_000,
                kg: sample.kilograms
            )
        }

        watch.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.watchObservationRevision &+= 1
                }
            }
            .store(in: &nestedCancellables)
        weather.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.weatherObservationRevision &+= 1
                }
            }
            .store(in: &nestedCancellables)
        health.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.healthObservationRevision &+= 1
                }
            }
            .store(in: &nestedCancellables)

        // Observation replaces the old `$status` / `$handsFreeArmed` Combine
        // sinks. Transport transitions still enter the same salvage and
        // haptic path synchronously on MainActor; the hot sample properties do
        // not flow through AppModel at all.
        tindeq.onStatusChange = { [weak self] status in
            self?.handleTindeqStatusChange(status)
        }
        tindeq.onHandsFreeArmedChange = { [weak self] _ in
            self?.handsFreeObservationRevision &+= 1
            self?.updateKeepAwake()
        }

        authObservationTask = Task { [weak self] in
            guard let self else { return }
            for await (event, session) in auth.client.auth.authStateChanges {
                await self.handleAuthEvent(event, session: session)
            }
        }
    }

    /// The Observation equivalent of the former `$status` sink. Keeping this
    /// transition handler on AppModel preserves the existing transport
    /// haptics, disconnect-salvage claim, and keep-awake ordering while
    /// avoiding a Combine publisher on the 80 Hz force object.
    private func handleTindeqStatusChange(_ status: TindeqBluetooth.Status) {
        let previous = lastTransportStatus
        lastTransportStatus = status
        // #656 (review F1/F2): the transport cues success/error only when a
        // user gesture armed them this launch — `connect()` called from the
        // Force tab — and only once per logical event. A cold launch with
        // Bluetooth off is `.idle → .interrupted` with no user intent, and
        // must stay silent. A single Bluetooth-off delivers TWO different
        // `.interrupted` values back-to-back, so consecutive error statuses
        // collapse to one cue.
        let cue: HapticCue?
        switch (previous, status) {
        case (.connecting?, .connected), (.scanning?, .connected), (.idle?, .connected), (nil, .connected):
            cue = transportUserInitiated ? .success : nil
        case (_, .interrupted), (_, .unavailable):
            cue = transportUserInitiated ? .error : nil
        case (_, .idle):
            cue = transportUserInitiated && previous != nil
                && previous != .idle && previous != .unavailable
                ? .error : nil
        default:
            cue = nil
        }
        if let cue, cue != lastTransportCue {
            lastTransportCue = cue
            Haptics.shared.play(cue)
        } else if cue == nil {
            lastTransportCue = nil
        }
        if case .interrupted = status {
            handsFree.handleDisconnected()
            if !forceModel.guidedProtocolActive {
                let interrupted = tindeq.interruptedRecording
                if let interrupted, !disconnectSalvageInFlight {
                    // #678: capture the hands-free provenance BEFORE
                    // `clearInterruptedRecording()`/`handleDisconnected()` can
                    // reset it, so salvage can apply #682 Guard 1.
                    let wasHandsFree = tindeq.interruptedWasHandsFree
                    // Claim the interrupted buffer synchronously — before any
                    // await — so duplicate `.interrupted` emissions cannot
                    // queue a second salvage or race the recovery prompt.
                    disconnectSalvageInFlight = true
                    if ForceDisconnectSalvage.shouldSalvage(
                        wasIntentional: false,
                        wasMeasuring: true,
                        sampleCount: interrupted.samples.count
                    ) {
                        tindeq.clearInterruptedRecording()
                        Task { @MainActor in
                            await self.salvageInterruptedRecording(interrupted, wasHandsFree: wasHandsFree)
                            self.disconnectSalvageInFlight = false
                        }
                    } else {
                        // Too trivial to auto-salvage: leave the buffer in
                        // place for the Force tab's recovery prompt.
                        disconnectSalvageInFlight = false
                    }
                }
                Task { @MainActor in await self.endGaugeSession() }
            }
        }
        updateKeepAwake()
    }

    deinit {
        authObservationTask?.cancel()
        liveMirrorTicker?.cancel()
        reconcileFlushTask?.cancel()
    }

    public var currentUserID: UUID? { authSession?.user.id }
    public var currentUserEmail: String? { authSession?.user.email }
    /// #679/#757: recent on-device auth events (sign-in / refresh / sign-out /
    /// failure), oldest first, readable behind Settings' technical-details
    /// gate. The ring is bounded and best-effort persistent (see
    /// `AuthDiagnosticsStore`).
    public var authEventLog: [AuthEventEntry] { auth.diagnostics.history() }
    public var accountScope: NativeAccountScope {
        NativeAccountScope(userID: currentUserID, epoch: accountEpoch)
    }
    public var currentPhase: PhaseDefinition { PhaseCatalog.definition(for: settings.currentPhase) }
    public var acwr: ACWRData { TrainingMetrics.computeACWR(sessions: sessions) }
    public var readiness: HealthMetric? { healthMetrics.first }
    public var weeklyLoads: [WeeklyLoad] { TrainingMetrics.weeklyLoads(sessions: sessions) }
    public var recentSessions: [SendmeterCore.Session] { Array(sessions.prefix(8)) }

    // MARK: Tag registry (#631)

    /// The exercise-manager rows: distinct recording tags with rep counts,
    /// hidden flags from the registry.
    public var tagEntries: [TagEntry] {
        TagCatalog.entries(recordings: recordings, metadata: tagMetadata)
    }

    /// Names hidden from the Force-tab picker and History force-tag chips.
    public var hiddenTagNames: Set<String> {
        TagCatalog.hiddenNames(tagMetadata)
    }

    /// The pickable exercise names: distinct recording tags minus hidden.
    public var visibleTagNames: [String] {
        TagCatalog.visibleNames(tagEntries)
    }

    public func setTagHidden(name: String, hidden: Bool) async {
        guard let userID = currentUserID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        let previous = tagMetadata.first { $0.name == name }
        let optimistic = TagMetadata(name: name, hidden: hidden)
        if let index = tagMetadata.firstIndex(where: { $0.name == name }) {
            tagMetadata[index] = optimistic
        } else {
            tagMetadata.append(optimistic)
        }
        let optimisticRevision = cacheUpsertLocal(
            optimistic,
            accountUserID: userID,
            entityType: .tagMetadata,
            entityID: CacheEntityID.tagMetadata(optimistic)
        )
        do {
            try await repository.setTagHidden(name: name, hidden: hidden)
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            cacheConfirmServerUpsert(
                optimistic,
                accountUserID: userID,
                entityType: .tagMetadata,
                entityID: CacheEntityID.tagMetadata(optimistic),
                confirmingLocalRevision: optimisticRevision
            )
            toastMessage = hidden ? "Hid “\(name)”" : "Showing “\(name)”"
        } catch {
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            tagMetadata.removeAll { $0.name == name }
            if let previous {
                cacheConfirmServerUpsert(
                    previous,
                    accountUserID: userID,
                    entityType: .tagMetadata,
                    entityID: CacheEntityID.tagMetadata(previous),
                    confirmingLocalRevision: optimisticRevision
                )
                tagMetadata.append(previous)
            } else {
                cacheConfirmServerDelete(
                    accountUserID: userID,
                    entityType: .tagMetadata,
                    entityID: CacheEntityID.tagMetadata(optimistic),
                    confirmingLocalRevision: optimisticRevision
                )
            }
            surface(error)
        }
    }

    /// The side-applicability mode for a tag. A tag with no stored mode (or an
    /// unconfigured / legacy exercise) reads as the default —
    /// `unilateral_or_bilateral`.
    public func sideMode(for name: String) -> ExerciseSideMode {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return tagSideModes[trimmed] ?? ExerciseSideMode.defaultMode
    }

    /// Set a tag's side mode and persist it device-locally (#720). The choice
    /// is deliberately off the account — it is not upserted to `tindeq_tags`.
    public func setTagSideMode(name: String, mode: ExerciseSideMode) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tagSideModes[trimmed] = mode
        TagSideModeStore.store(mode, for: trimmed)
        toastMessage = "Set “\(trimmed)” to \(mode.displayName)"
    }

    /// Rename a tag EVERYWHERE — the DB repoints every recording carrying
    /// the old name; the recording list is refetched after (its tags are
    /// the source of truth for counts).
    public func renameTag(oldName: String, newName: String) async {
        guard let userID = currentUserID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        let old = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.isEmpty, !next.isEmpty else { return }
        let previousRecordings = recordings
        let previousMetadata = tagMetadata
        let merged = tagEntries.contains { $0.name == next }
        let nextMetadata = previousMetadata.first { $0.name == next }
            ?? TagMetadata(name: next, hidden: false)
        let optimisticRecordings = recordings.map { recording in
            var updated = recording
            if recording.tag == old {
                updated.tag = next
            }
            return updated
        }
        let optimisticMetadata = previousMetadata
            .filter { $0.name != old }
            .filter { $0.name != next } + [nextMetadata]
        var recordingRevisions: [UUID: Int] = [:]
        var metadataRevisions: [String: Int] = [:]
        var oldMetadataDeleteRevision: Int?
        recordings = optimisticRecordings
        tagMetadata = optimisticMetadata
        for recording in optimisticRecordings where recording.tag == next {
            if let revision = cacheUpsertLocal(
                recording,
                accountUserID: userID,
                entityType: .recordings,
                entityID: CacheEntityID.recording(recording)
            ) {
                recordingRevisions[recording.id] = revision
            }
        }
        for metadata in optimisticMetadata {
            if let revision = cacheUpsertLocal(
                metadata,
                accountUserID: userID,
                entityType: .tagMetadata,
                entityID: CacheEntityID.tagMetadata(metadata)
            ) {
                metadataRevisions[metadata.name] = revision
            }
        }
        if old != next {
            oldMetadataDeleteRevision = cacheMarkDeletedLocal(
                accountUserID: userID,
                entityType: .tagMetadata,
                entityID: old
            )
        }
        let previousSideMode = tagSideModes[old]
        if let mode = previousSideMode, old != next {
            if tagSideModes[next] == nil {
                tagSideModes[next] = mode
                TagSideModeStore.store(mode, for: next)
            }
            tagSideModes.removeValue(forKey: old)
            TagSideModeStore.remove(for: old)
        }
        do {
            try await repository.renameTag(oldName: old, newName: next)
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            // The server is authoritative, but confirming the optimistic copy
            // first lets the follow-up refresh adopt the returned state even if
            // the network drops before that fetch completes.
            for recording in optimisticRecordings where recording.tag == next {
                cacheConfirmServerUpsert(
                    recording,
                    accountUserID: userID,
                    entityType: .recordings,
                    entityID: CacheEntityID.recording(recording),
                    confirmingLocalRevision: recordingRevisions[recording.id]
                )
            }
            for metadata in optimisticMetadata {
                let revision = metadataRevisions[metadata.name]
                cacheConfirmServerUpsert(
                    metadata,
                    accountUserID: userID,
                    entityType: .tagMetadata,
                    entityID: CacheEntityID.tagMetadata(metadata),
                    confirmingLocalRevision: revision
                )
            }
            if old != next {
                cacheConfirmServerDelete(
                    accountUserID: userID,
                    entityType: .tagMetadata,
                    entityID: old,
                    confirmingLocalRevision: oldMetadataDeleteRevision
                )
            }
            // The rename RPC hard-deletes the stale registry row and does not
            // create the new one unless it already existed. Deltas cannot
            // observe that, so force a full tag reconcile before refreshing.
            if let cachedWorkspace {
                do {
                    try cachedWorkspace.resetCursor(
                        accountUserID: userID,
                        entityType: .tagMetadata
                    )
                } catch {
                    recordCacheFailure("cache cursor reset", error)
                }
            }
            await refreshAll(showSpinner: false)
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            toastMessage = merged
                ? "Merged into “\(next)”"
                : "Renamed to “\(next)”"
        } catch {
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            recordings = previousRecordings
            tagMetadata = previousMetadata
            for recording in previousRecordings where recordingRevisions[recording.id] != nil {
                cacheConfirmServerUpsert(
                    recording,
                    accountUserID: userID,
                    entityType: .recordings,
                    entityID: CacheEntityID.recording(recording),
                    confirmingLocalRevision: recordingRevisions[recording.id]
                )
            }
            for metadata in previousMetadata where metadataRevisions[metadata.name] != nil {
                cacheConfirmServerUpsert(
                    metadata,
                    accountUserID: userID,
                    entityType: .tagMetadata,
                    entityID: CacheEntityID.tagMetadata(metadata),
                    confirmingLocalRevision: metadataRevisions[metadata.name]
                )
            }
            if let oldMetadataDeleteRevision {
                if let oldMetadata = previousMetadata.first(where: { $0.name == old }) {
                    cacheConfirmServerUpsert(
                        oldMetadata,
                        accountUserID: userID,
                        entityType: .tagMetadata,
                        entityID: CacheEntityID.tagMetadata(oldMetadata),
                        confirmingLocalRevision: oldMetadataDeleteRevision
                    )
                } else {
                    cacheConfirmServerDelete(
                        accountUserID: userID,
                        entityType: .tagMetadata,
                        entityID: old,
                        confirmingLocalRevision: oldMetadataDeleteRevision
                    )
                }
            }
            if !previousMetadata.contains(where: { $0.name == next }),
               let newMetadataRevision = metadataRevisions[next] {
                cacheConfirmServerDelete(
                    accountUserID: userID,
                    entityType: .tagMetadata,
                    entityID: next,
                    confirmingLocalRevision: newMetadataRevision
                )
            }
            if let mode = previousSideMode {
                tagSideModes[old] = mode
                TagSideModeStore.store(mode, for: old)
            }
            surface(error)
        }
    }

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

    /// Sign in with Apple (#631): exchange the identity token (whose nonce
    /// claim is the SHA-256 hash of `rawNonce`) for a Supabase session. The
    /// hash/raw pairing is produced by `AppleAuthNonce.flow` at the button.
    public func signInWithApple(idToken: String, rawNonce: String) async {
        await perform {
            try await self.auth.signInWithApple(idToken: idToken, rawNonce: rawNonce)
        }
    }

    public func registerPasskey() async {
        await perform {
            try await self.auth.registerPasskey()
            self.toastMessage = "Passkey registered."
            // #712: a registration must be visible as a persistent list entry
            // and count in Settings, not just a transient toast.
            await self.loadPasskeys()
        }
    }

    /// #712: fetch the passkey list for the current account. Account-scoped
    /// like every other fetch, so a completion that resumes after an account
    /// switch cannot publish into the wrong account.
    public func loadPasskeys() async {
        guard let userID = currentUserID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        do {
            let fetched = try await auth.listPasskeys()
            guard accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch) else {
                return
            }
            passkeys = fetched
        } catch {
            if accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch) {
                surface(error)
            }
        }
    }

    /// #712: remove a passkey server-side (not just hide it locally). The UI
    /// confirms before calling this; failures surface through the shared
    /// error path, and a successful delete reloads the list.
    public func removePasskey(_ id: UUID) async {
        await perform {
            try await self.auth.deletePasskey(id: id)
            self.toastMessage = "Passkey removed."
            await self.loadPasskeys()
        }
    }

    /// #632: THE user-initiated sign-out, mirroring the web's `signOutUser`
    /// (#273): drain the queue BEFORE `auth.signOut()` — the insert needs a
    /// live token — bounded by the deadline, then ask once about any
    /// remainder (Sign Out / Cancel), and only then sign out. A FORCED or
    /// revoked sign-out never reaches this: `handleAuthEvent`'s `.signedOut`
    /// case leaves the queue untouched, and `deleteAccount` keeps its own
    /// discard-after-server-confirmation path.
    public func signOut() async {
        guard !isSigningOut else { return }
        isSigningOut = true
        defer { isSigningOut = false }
        await perform {
            // End the guided owner while the old account scope and bearer
            // token are still live. Its durable recording/session writes must
            // participate in the bounded drain and remainder decision below.
            await self.teardownGuidedProtocolBeforeAuthRevocation()
            guard let userID = self.currentUserID, let queue = self.queue else {
                try await self.auth.signOut()
                self.watch.relaySession(nil)
                return
            }
            let result = await SignOutQueuePolicy.drainBeforeSignOut(
                userId: userID,
                drain: { await self.drainQueueForSignOut(accountUserID: $0) },
                countRemaining: { await queue.count(for: $0) },
                askAboutRemainder: { count in await self.askAboutSignOutRemainder(count: count) },
                signOut: { try await self.auth.signOut() }
            )
            // #632 review: a cancel at the remainder prompt ("Stay Signed In")
            // returns `outcome == nil` with no error — the session is still
            // up, so NOTHING may follow this guard. In particular NOT the
            // watch relay: relaying nil would tell the companion "signedOut"
            // (it drops its bearer token and its queue uploads stall on
            // "Waiting for iPhone" until the phone next foregrounds and
            // re-relays) while the phone itself stays signed in.
            guard result.outcome != nil else { return }
            if let signOutError = result.signOutError { throw signOutError }
            self.watch.relaySession(nil)
        }
    }

    /// The sign-out drain: attempt EVERYTHING for the account, not just
    /// backoff-due items — the token is about to die, so a backed-off entry
    /// that never got tried would strand for the whole sign-out for no
    /// reason. (Web parity: the web queue has no per-entry backoff, so its
    /// pre-sign-out drain attempts everything.) Counts what actually
    /// uploaded.
    private func drainQueueForSignOut(accountUserID: UUID) async -> Int {
        guard let queue else { return 0 }
        var uploaded = 0
        for item in await queue.items(for: accountUserID) {
            if (await upload(item, mode: .signOut)).uploaded { uploaded += 1 }
        }
        return uploaded
    }

    public func updatePassword(_ password: String) async {
        await perform {
            try await self.auth.updatePassword(password)
            self.passwordRecovery = false
            self.toastMessage = "Password updated."
        }
    }

    /// #722 (parity with web #542): send a password reset email for the
    /// signed-in user's address. The reset link reopens the app via the
    /// custom scheme; `handleDeepLink` routes it to `PasswordRecoveryView`.
    public func sendPasswordResetEmail() async {
        // Read the address before the await (repo closure-capture rule); the
        // signing-in account is the only one a reset should target.
        guard let email = currentUserEmail else { return }
        await perform {
            try await self.auth.resetPassword(email: email)
            self.toastMessage = "Password reset email sent to \(email)."
        }
    }

    /// Route an incoming URL. `sendmeter://<host>` is the navigation scheme
    /// the Live Activity / Dynamic Island taps (sendmeter://force) and any
    /// future widgets/complications use — it must be intercepted BEFORE the
    /// auth parser, or supabase-swift's PKCE `session(from:)` throws "Not a
    /// valid PKCE flow URL" and the raw error lands in the ErrorBanner
    /// (#674 review F2). Everything else is an auth callback
    /// (com.jirathip.sendlog://auth#access_token=…).
    public func handleDeepLink(_ url: URL) async {
        if url.scheme == "sendmeter" {
            routeNativeDeepLink(url)
            return
        }
        await perform { try await self.auth.handleDeepLink(url) }
    }

    /// Map a `sendmeter://` host to a tab — the native mirror of the watch's
    /// `WatchNavigation.resolvedPath`. Pure so it is unit-testable.
    public static func tab(forDeepLink url: URL) -> AppTab? {
        switch url.host {
        case "force": return .force
        case "dashboard": return .dashboard
        case "workout": return .workout
        case "history": return .history
        case "settings": return .settings
        default: return nil
        }
    }

    private func routeNativeDeepLink(_ url: URL) {
        guard let tab = Self.tab(forDeepLink: url) else { return }
        selectedTab = tab
    }

    /// #674 review F7: the orphan sweep ALSO runs on the root view's first
    /// appearance, because `becameActive()` is driven by a `scenePhase`
    /// change and whether a COLD launch delivers one is version-dependent.
    /// This is the launch-time guarantee: force-quit mid-protocol → relaunch
    /// → the stranded card is retired even if no phase change fires.
    public func reconcileStrandedActivitiesAtLaunch() {
        guidedActivity.reconcileOrphans()
        manualWorkoutActivity.reconcileOrphans()
    }

    public func becameActive() async {
        // #674 review F7: clear any guided Live Activity stranded by a
        // force-quit / jetsam BEFORE the auth gate — a killed app never ran
        // the in-process teardown, and relaunch is the only chance to retire
        // the card. No-op while a run is in progress.
        guidedActivity.reconcileOrphans()
        manualWorkoutActivity.reconcileOrphans()
        guard authSession != nil else { return }
        await relayValidSessionToWatch(guaranteed: false)
        await drainQueue()
        // #673: only sweep all 9 tables when the foreground is actually
        // stale. A no-change foreground (data already loaded, realtime
        // healthy, last full refresh inside the grace window) issues 0
        // full-table fetches — realtime's targeted slice reconciler already
        // converges the watched tables. The decision is the pure
        // `ForegroundRefreshPolicy` (unit-tested); it reads live actor state
        // synchronously before the first await, so there is no stale-closure
        // capture here.
        if foregroundRefreshPolicy.shouldRefreshOnForeground(
            lastFullRefreshAt: lastListRefreshAt,
            now: ProcessInfo.processInfo.systemUptime,
            realtimeConnected: realtime.connectionStatus == .connected,
            hasLoadedData: hasLoadedSessions && forceModel.hasLoadedRecordings
        ) {
            await refreshAll(showSpinner: false)
        }
        // #631: keep Send Conditions honest on foreground (cached value
        // stays on failure — the service never fabricates). Only the silent
        // refresh path runs here: a COLD first check stays user-initiated
        // (the card's Check tap), so the location prompt is never fired
        // without a tap — web parity.
        if weather.conditions != nil {
            _ = await weather.refresh(trigger: .foreground)
        }
        // Foreground reconciliation for the live mirror: a dropped realtime
        // socket degrades to this refetch (the row is the authoritative
        // server state), and the mirror cursor rejects anything older.
        await refreshLiveWorkoutRow()
        if UserDefaults.standard.bool(forKey: "sendmeter.native.health-authorized") {
            await health.ensureBackgroundObserversRegistered()
            await silentHealthRefresh(trigger: .foreground)
        }
        // Last on purpose: the drain's "Saved" toasts above must not clobber
        // the loss notice — the user hearing about the lost rep is the point.
        surfaceLostRecordingNoticeIfAny()
    }

    private func handleAuthEvent(_ event: AuthChangeEvent, session: AuthSession?) async {
        switch event {
        case .initialSession, .signedIn, .tokenRefreshed, .userUpdated, .mfaChallengeVerified:
            guard let session else {
                await teardownGuidedProtocolBeforeAuthRevocation()
                authSession = nil
                bootState = .signedOut
                await tearDownRealtime()
                return
            }
            // #679: capture the transition at the real authStateChanges
            // boundary. Recorded here (not in AuthService) so a single
            // sign-in/refresh is never counted twice.
            switch event {
            case .signedIn:
                auth.recordAuthEvent(.signIn, detail: "Session established")
            case .initialSession:
                auth.recordAuthEvent(.signIn, detail: "Session restored at launch")
            case .tokenRefreshed:
                auth.recordAuthEvent(.refresh, detail: "Access token refreshed")
            default:
                break
            }
            let changedUser = authSession?.user.id != session.user.id
            if changedUser {
                await teardownGuidedProtocolBeforeAuthRevocation()
            }
            authSession = session
            bootState = .signedIn
            watch.relaySession(session)
            if changedUser || didBootstrapUserID != session.user.id {
                resetAccountState()
                await refreshAll(showSpinner: true)
                // #712: load the passkey list for the (newly) signed-in user.
                await loadPasskeys()
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
            if GuidedForceAuthTransitionPolicy.passwordRecoveryNeedsTeardown(
                currentUserID: authSession?.user.id,
                nextUserID: session?.user.id
            ) {
                await teardownGuidedProtocolBeforeAuthRevocation()
            }
            authSession = session
            passwordRecovery = true
            bootState = session == nil ? .signedOut : .signedIn
        case .signedOut, .userDeleted:
            await teardownGuidedProtocolBeforeAuthRevocation()
            // #679: sign-out boundary.
            auth.recordAuthEvent(
                .signOut,
                detail: event == .signedOut ? "Signed out" : "Account deleted"
            )
            watch.relaySession(nil)
            authSession = nil
            didBootstrapUserID = nil
            resetAccountState()
            bootState = .signedOut
            await tearDownRealtime()
        }
    }

    private func relayValidSessionToWatch(guaranteed: Bool) async {
        // #679: route the watch relay through the single session-freshness
        // guard so a stale relayed token is never handed to the companion.
        do {
            let valid = try await self.auth.ensureFreshSession()
            authSession = valid
            watch.relaySession(valid, guaranteed: guaranteed)
        } catch {
            watch.relaySession(nil, guaranteed: guaranteed)
        }
    }

    // MARK: Local cache (#747)

    /// Publish the account's cached read snapshot before any network call.
    ///
    /// A cache failure is deliberately swallowed here and never crashes the
    /// auth/bootstrap path: `refreshAll` continues with the existing
    /// network-only behavior and the failure is visible in the Settings
    /// diagnostics ring.
    private func hydrateCachedWorkspace(accountUserID: UUID) {
        do {
            guard let snapshot = try CacheHydrator.load(
                workspace: cachedWorkspace,
                accountUserID: accountUserID
            ) else { return }
            sessions = snapshot.sessions
            hasLoadedSessions = !snapshot.sessions.isEmpty
            if let cachedSettings = snapshot.settings {
                settings = cachedSettings
            }
            phasePeriods = snapshot.phasePeriods
            healthMetrics = snapshot.healthMetrics
            recordings = snapshot.recordings
            presets = snapshot.presets
            routines = snapshot.routines
            workouts = snapshot.workouts
            tagMetadata = snapshot.tagMetadata
            // Pending rows are the cache's durable optimistic overlay. Rebuild
            // the in-memory overlays before the first remote merge so a
            // pending item cannot be dropped when `refreshAll` replaces the
            // published collections with the authoritative snapshot.
            pendingSessions = Dictionary(
                uniqueKeysWithValues: snapshot.sessions
                    .filter(\.pending)
                    .map { ($0.id, $0) }
            )
            let pendingRecordingIDs = try cachedWorkspace?.pendingEntityIDs(
                accountUserID: accountUserID,
                entityType: .recordings
            ) ?? []
            pendingRecordings = PendingRecordingOverlay()
            let recordingsByID = Dictionary(
                uniqueKeysWithValues: snapshot.recordings.map { ($0.id, $0) }
            )
            for pendingID in pendingRecordingIDs {
                guard let id = UUID(uuidString: pendingID),
                      let recording = recordingsByID[id] else { continue }
                pendingRecordings.insert(recording, accountUserID: accountUserID)
            }
            forceModel.hasLoadedRecordings = !snapshot.recordings.isEmpty
            publishForceProgressInputMutation(.recordings)
            refreshPendingCacheWriteCount(accountUserID: accountUserID)
        } catch {
            recordCacheFailure("cache read", error)
        }
    }

    /// Applies one entity refresh to the cache: a full snapshot on first sync
    /// or after a cursor reset, or a cursor-bounded delta otherwise. Cache
    /// errors are recorded and non-fatal, matching the cold-start read policy.
    private func reconcileEntityRefresh<T: Encodable>(
        _ delta: RemoteEntityDelta<T>,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        fullSnapshot: CachedWorkspaceSnapshot?
    ) {
        guard let cachedWorkspace else { return }
        do {
            if fullSnapshot != nil {
                try cachedWorkspace.reconcileServerDelta(
                    delta,
                    accountUserID: accountUserID,
                    entityType: entityType
                )
            } else {
                try cachedWorkspace.reconcileDelta(
                    delta,
                    accountUserID: accountUserID,
                    entityType: entityType
                )
            }
        } catch {
            recordCacheFailure("cache entity reconcile", error)
        }
    }

    private func cacheCursor(
        accountUserID: UUID,
        entityType: LocalCacheEntityType
    ) -> String? {
        guard let cachedWorkspace else { return nil }
        do {
            return try cachedWorkspace.cursor(
                accountUserID: accountUserID,
                entityType: entityType
            )
        } catch {
            recordCacheFailure("cache cursor read", error)
            return nil
        }
    }

    /// Re-adopts the reconciled cache values for the collections that do not
    /// carry their own in-memory optimistic overlays.
    ///
    /// Sessions and recordings deliberately stay on `mergeSessions` /
    /// `mergeRecordings`, which also restore RPE/editor overlays and durable
    /// queue rows. The remaining entities only have the cache as their durable
    /// local row, so this is the final authority after an authoritative refresh.
    private func applyCachedNonOverlayLists(accountUserID: UUID) {
        guard let cachedWorkspace else { return }
        do {
            let snapshot = try cachedWorkspace.load(accountUserID: accountUserID)
            if let cachedSettings = snapshot.settings {
                settings = cachedSettings
            }
            phasePeriods = snapshot.phasePeriods
            healthMetrics = snapshot.healthMetrics
            presets = snapshot.presets
            routines = snapshot.routines
            workouts = snapshot.workouts
            tagMetadata = snapshot.tagMetadata
            refreshPendingCacheWriteCount(accountUserID: accountUserID)
        } catch {
            recordCacheFailure("cache publish", error)
        }
    }

    @discardableResult
    private func cacheUpsertLocal<T: Encodable>(
        _ value: T,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String
    ) -> Int? {
        guard let cachedWorkspace else { return nil }
        do {
            let revision = try cachedWorkspace.upsertLocal(
                value,
                accountUserID: accountUserID,
                entityType: entityType,
                entityID: entityID
            )
            if CachedWorkspace.directWriteEntityTypes.contains(entityType) {
                refreshPendingCacheWriteCount(accountUserID: accountUserID)
            }
            return revision
        } catch {
            recordCacheFailure("cache local upsert", error)
            return nil
        }
    }

    private func cacheUpsertServer<T: Encodable>(
        _ value: T,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String,
        updatedAt: Date = Date()
    ) {
        guard let cachedWorkspace else { return }
        do {
            try cachedWorkspace.upsertServer(
                value,
                accountUserID: accountUserID,
                entityType: entityType,
                entityID: entityID,
                updatedAt: updatedAt
            )
        } catch {
            recordCacheFailure("cache server upsert", error)
        }
    }

    @discardableResult
    private func cacheMarkDeletedLocal(
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String
    ) -> Int? {
        guard let cachedWorkspace else { return nil }
        do {
            let revision = try cachedWorkspace.markDeletedLocal(
                accountUserID: accountUserID,
                entityType: entityType,
                entityID: entityID
            )
            if CachedWorkspace.directWriteEntityTypes.contains(entityType) {
                refreshPendingCacheWriteCount(accountUserID: accountUserID)
            }
            return revision
        } catch {
            recordCacheFailure("cache local delete", error)
            return nil
        }
    }

    private func cacheConfirmServerUpsert<T: Encodable>(
        _ value: T,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String,
        confirmingLocalRevision: Int? = nil
    ) {
        guard let cachedWorkspace else { return }
        do {
            let revision = try confirmingLocalRevision ?? cachedWorkspace.localRevision(
                accountUserID: accountUserID,
                entityType: entityType,
                entityID: entityID
            )
            // A confirmation is only an ack for a row that was written to the
            // cache by this device. If the local write never landed (or the
            // account was purged), do not synthesize a row here: a late ack
            // must never recreate purged account state, and a missing cache
            // row is repopulated by the next authoritative refresh.
            guard let revision else { return }
            try cachedWorkspace.confirmServerUpsert(
                value,
                accountUserID: accountUserID,
                entityType: entityType,
                entityID: entityID,
                confirmingLocalRevision: revision
            )
            if CachedWorkspace.directWriteEntityTypes.contains(entityType) {
                refreshPendingCacheWriteCount(accountUserID: accountUserID)
            }
        } catch {
            recordCacheFailure("cache confirmation", error)
        }
    }

    private func cacheConfirmServerDelete(
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        entityID: String,
        confirmingLocalRevision: Int? = nil
    ) {
        guard let cachedWorkspace else { return }
        do {
            let revision = try confirmingLocalRevision ?? cachedWorkspace.localRevision(
                accountUserID: accountUserID,
                entityType: entityType,
                entityID: entityID
            )
            guard let revision else { return }
            try cachedWorkspace.confirmServerDelete(
                accountUserID: accountUserID,
                entityType: entityType,
                entityID: entityID,
                confirmingLocalRevision: revision
            )
            if CachedWorkspace.directWriteEntityTypes.contains(entityType) {
                refreshPendingCacheWriteCount(accountUserID: accountUserID)
            }
        } catch {
            recordCacheFailure("cache delete confirmation", error)
        }
    }

    /// The cache rows an uploaded payload can confirm. Captured before the
    /// first network await so a newer local edit that arrives while the
    /// request is suspended cannot be acknowledged by the older response.
    private func cacheConfirmationTargets(
        for payload: PendingWrite
    ) -> [CacheEntityIdentity] {
        switch payload {
        case let .session(session):
            return [
                CacheEntityIdentity(
                    entityType: .sessions,
                    entityID: session.id.uuidString
                )
            ]
        case let .sessionDelete(deletePayload):
            return [
                CacheEntityIdentity(
                    entityType: .sessions,
                    entityID: deletePayload.sessionID.uuidString
                )
            ]
        case let .recording(recordingPayload):
            return [
                CacheEntityIdentity(
                    entityType: .recordings,
                    entityID: recordingPayload.id.uuidString
                )
            ]
        case let .recordingEdit(editPayload):
            return [
                CacheEntityIdentity(
                    entityType: .recordings,
                    entityID: editPayload.recordingID.uuidString
                )
            ]
        case let .sessionRPEEdit(edit):
            guard let sessionID = edit.sessionID else { return [] }
            return [
                CacheEntityIdentity(
                    entityType: .sessions,
                    entityID: sessionID.uuidString
                )
            ]
        case let .recordingDelete(deletePayload):
            var targets = [
                CacheEntityIdentity(
                    entityType: .recordings,
                    entityID: deletePayload.recordingID.uuidString
                )
            ]
            if let sessionID = deletePayload.sessionID {
                targets.append(
                    CacheEntityIdentity(
                        entityType: .sessions,
                        entityID: sessionID.uuidString
                    )
                )
            }
            return targets
        case let .workout(draft):
            return [
                CacheEntityIdentity(
                    entityType: .sessions,
                    entityID: draft.sessionID.uuidString
                )
            ]
        }
    }

    private func cacheConfirmationRevisions(
        for payload: PendingWrite,
        accountUserID: UUID
    ) -> [CacheEntityIdentity: Int] {
        guard let cachedWorkspace else { return [:] }
        var revisions: [CacheEntityIdentity: Int] = [:]
        for target in cacheConfirmationTargets(for: payload) {
            if let revision = try? cachedWorkspace.localRevision(
                accountUserID: accountUserID,
                entityType: target.entityType,
                entityID: target.entityID
            ) {
                revisions[target] = revision
            }
        }
        return revisions
    }

    private func cacheConfirmationRevision(
        _ revisions: [CacheEntityIdentity: Int],
        entityType: LocalCacheEntityType,
        entityID: String
    ) -> Int? {
        revisions[
            CacheEntityIdentity(
                entityType: entityType,
                entityID: entityID
            )
        ]
    }

    private func recordCacheFailure(_ operation: String, _ error: Error) {
        guard !cacheOpenFailureReported else { return }
        cacheOpenFailureReported = true
        auth.recordAuthEvent(
            .failure,
            detail: "Local cache \(operation): \(error.localizedDescription)"
        )
    }

    private func refreshPendingCacheWriteCount(accountUserID: UUID) {
        guard let cachedWorkspace else { return }
        do {
            pendingCacheWriteCount = try cachedWorkspace.pendingDirectWriteCount(
                accountUserID: accountUserID
            )
        } catch {
            recordCacheFailure("cache pending count", error)
        }
    }

    // MARK: Loading

    public func refreshAll(showSpinner: Bool = true) async {
        guard let userID = currentUserID else { return }
        // Cold-start / account-switch path: render the account's local
        // snapshot before any network request starts.
        hydrateCachedWorkspace(accountUserID: userID)
        let sessionCursor = cacheCursor(accountUserID: userID, entityType: .sessions)
        let settingsCursor = cacheCursor(accountUserID: userID, entityType: .settings)
        let phaseCursor = cacheCursor(accountUserID: userID, entityType: .phasePeriods)
        let healthCursor = cacheCursor(accountUserID: userID, entityType: .healthMetrics)
        let recordingCursor = cacheCursor(accountUserID: userID, entityType: .recordings)
        let presetCursor = cacheCursor(accountUserID: userID, entityType: .presets)
        let routineCursor = cacheCursor(accountUserID: userID, entityType: .routinePresets)
        let workoutCursor = cacheCursor(accountUserID: userID, entityType: .workoutsAndAttempts)
        let tagCursor = cacheCursor(accountUserID: userID, entityType: .tagMetadata)
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        let refreshCompletion = showSpinner
            ? AccountScopedCompletion(fetch: accountFetch)
            : nil
        if let refreshCompletion {
            refreshingOwner = refreshCompletion
            isRefreshing = true
        }
        defer {
            if let refreshCompletion,
               refreshCompletion.owns(
                   currentUserID: currentUserID,
                   accountEpoch: accountEpoch,
                   activeOwner: refreshingOwner
               ) {
                isRefreshing = false
                refreshingOwner = nil
            }
        }
        do {
            let today = LocalDateSupport.string(from: Date())
            async let remoteSessions = repository.fetchSessionDelta(
                since: sessionCursor,
                accountUserID: userID
            )
            async let remoteSettings = repository.fetchSettingsDelta(since: settingsCursor)
            async let remotePeriods = repository.fetchPhasePeriodDelta(since: phaseCursor)
            async let remoteHealth = repository.fetchHealthMetricDelta(since: healthCursor)
            async let remoteRecordings = repository.fetchRecordingDelta(since: recordingCursor)
            async let remotePresets = repository.fetchPresetDelta(since: presetCursor)
            async let remoteRoutines = repository.fetchRoutineDelta(since: routineCursor)
            async let remoteWorkouts = repository.fetchWorkoutDelta(since: workoutCursor)
            async let remoteTags = repository.fetchTagMetadataDelta(since: tagCursor)

            let fetchedSessions = try await remoteSessions
            let fetchedRecordings = try await remoteRecordings
            var fetchedSettings = try await remoteSettings
            if settingsCursor == nil, fetchedSettings.activeValues.isEmpty {
                // First sync with no settings row: keep the historical
                // create-default behavior, then read the stamped timestamp so
                // the next refresh can go incremental.
                _ = try await repository.fetchSettings(userID: userID, today: today)
                let settingsAfterUpsert = try await repository.fetchSettingsDelta(since: nil)
                if settingsAfterUpsert.activeValues.isEmpty {
                    fetchedSettings = RemoteEntityDelta(
                        changes: [],
                        activeValues: [UserSettings(currentPhase: .capacity, phaseStartDate: today)],
                        cursor: nil
                    )
                } else {
                    fetchedSettings = settingsAfterUpsert
                }
            }
            let fetchedPeriods = try await remotePeriods
            let fetchedHealth = try await remoteHealth
            let fetchedPresets = try await remotePresets
            let fetchedRoutines = try await remoteRoutines
            let fetchedWorkouts = try await remoteWorkouts
            let fetchedTags = try await remoteTags

            guard accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch) else {
                return
            }
            reconcileEntityRefresh(
                fetchedSessions,
                accountUserID: userID,
                entityType: .sessions,
                fullSnapshot: sessionCursor == nil
                    ? CachedWorkspaceSnapshot(sessions: fetchedSessions.activeValues)
                    : nil
            )
            reconcileEntityRefresh(
                fetchedSettings,
                accountUserID: userID,
                entityType: .settings,
                fullSnapshot: settingsCursor == nil
                    ? CachedWorkspaceSnapshot(settings: fetchedSettings.activeValues.first)
                    : nil
            )
            reconcileEntityRefresh(
                fetchedPeriods,
                accountUserID: userID,
                entityType: .phasePeriods,
                fullSnapshot: phaseCursor == nil
                    ? CachedWorkspaceSnapshot(phasePeriods: fetchedPeriods.activeValues)
                    : nil
            )
            reconcileEntityRefresh(
                fetchedHealth,
                accountUserID: userID,
                entityType: .healthMetrics,
                fullSnapshot: healthCursor == nil
                    ? CachedWorkspaceSnapshot(healthMetrics: fetchedHealth.activeValues)
                    : nil
            )
            reconcileEntityRefresh(
                fetchedRecordings,
                accountUserID: userID,
                entityType: .recordings,
                fullSnapshot: recordingCursor == nil
                    ? CachedWorkspaceSnapshot(recordings: fetchedRecordings.activeValues)
                    : nil
            )
            reconcileEntityRefresh(
                fetchedPresets,
                accountUserID: userID,
                entityType: .presets,
                fullSnapshot: presetCursor == nil
                    ? CachedWorkspaceSnapshot(presets: fetchedPresets.activeValues)
                    : nil
            )
            reconcileEntityRefresh(
                fetchedRoutines,
                accountUserID: userID,
                entityType: .routinePresets,
                fullSnapshot: routineCursor == nil
                    ? CachedWorkspaceSnapshot(routines: fetchedRoutines.activeValues)
                    : nil
            )
            reconcileEntityRefresh(
                fetchedWorkouts,
                accountUserID: userID,
                entityType: .workoutsAndAttempts,
                fullSnapshot: workoutCursor == nil
                    ? CachedWorkspaceSnapshot(workouts: fetchedWorkouts.activeValues)
                    : nil
            )
            reconcileEntityRefresh(
                fetchedTags,
                accountUserID: userID,
                entityType: .tagMetadata,
                fullSnapshot: tagCursor == nil
                    ? CachedWorkspaceSnapshot(tagMetadata: fetchedTags.activeValues)
                    : nil
            )

            let publishedSnapshot = try? cachedWorkspace?.load(accountUserID: userID)
            let publishedSessions = publishedSnapshot?.sessions
                ?? fetchedSessions.activeValues
            let publishedRecordings = publishedSnapshot?.recordings
                ?? fetchedRecordings.activeValues
            let publishedSessionIDs = Set(publishedSessions.map(\.id))
            let publishedRecordingIDs = Set(publishedRecordings.map(\.id))
            await restorePendingWrites(
                accountFetch: accountFetch,
                userID: userID,
                remoteSessionIDs: publishedSessionIDs,
                remoteRecordingIDs: publishedRecordingIDs
            )
            let publishedLists = accountFetch.publishIfCurrent(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) {
                // The cache is the reconciled source after either a full or a
                // delta refresh: re-adopt it so a pending local
                // preset/routine/settings/tag row is not hidden by the remote
                // snapshot in the published collections (sessions/recordings
                // keep their richer overlays below).
                applyCachedNonOverlayLists(accountUserID: userID)
                mergeSessions(remote: publishedSessions)
                // This is the explicit authoritative refresh boundary. A
                // server sample blob can change without metadata changing, so
                // refreshAll is allowed to invalidate every fit; realtime
                // rep reconciliation below stays key-scoped.
                invalidateTagCurveCache()
                mergeRecordings(remote: publishedRecordings)
                // The sample rows are fetched later by the curve request and
                // may have changed without any recording metadata change.
                // Publish this authoritative refresh boundary so a scoped
                // progress task restarts even when the metadata snapshot is
                // equal.
                publishForceProgressInputMutation(.recordings)
                forceModel.hasLoadedRecordings = true
            }
            guard publishedLists else { return }
            await refreshQueueCount(for: accountFetch)
            guard accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch) else {
                return
            }
            // #673: the authoritative sweep succeeded AND is still for the
            // current account — this is the freshness timestamp the
            // foreground gate reasons over. Bumped only here (not by the
            // realtime slice reconciler, which is a targeted refresh that
            // intentionally leaves the non-watched tables untouched).
            lastListRefreshAt = ProcessInfo.processInfo.systemUptime
            warmTagCurvesIfMissing(capturedBy: accountFetch)
        } catch {
            if accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch) {
                // Some slices may have already been published before the
                // failure. Put the last-known cache snapshot back so a partial
                // fetch cannot hide a pending local write.
                applyCachedNonOverlayLists(accountUserID: userID)
                surface(error)
            }
        }
    }

    /// #627: warm the per-tag curve cache in the background for every tag
    /// currently in the recordings (bounded by the pick window inside
    /// `ForceCurveEngine.pickCurveRecordings`), so the gauge-session end
    /// reads cached curves instead of fetching.
    public func warmTagCurvesIfMissing() {
        guard let userID = currentUserID else { return }
        warmTagCurvesIfMissing(
            capturedBy: AccountScopedFetch(
                accountUserID: userID,
                accountEpoch: accountEpoch
            )
        )
    }

    private func warmTagCurvesIfMissing(capturedBy accountFetch: AccountScopedFetch) {
        guard accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch) else {
            return
        }
        var keys = Set<TagCurveKey>()
        for recording in recordings where !recording.tag.isEmpty {
            keys.insert(
                TagCurveKey(
                    tag: recording.tag,
                    modality: GaugeSessionRPE.modality(of: recording)
                )
            )
        }
        for key in keys {
            warmTagCurveIfMissing(
                tag: key.tag,
                modality: key.modality,
                capturedBy: accountFetch
            )
        }
    }

    public func refreshTrash() async {
        guard let userID = currentUserID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        do {
            async let sessionTrash = repository.fetchDeletedSessions(accountUserID: userID)
            async let recordingTrash = repository.fetchDeletedRecordings()
            let fetchedSessions = try await sessionTrash
            let fetchedRecordings = try await recordingTrash
            _ = accountFetch.publishIfCurrent(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) {
                deletedSessions = fetchedSessions
                deletedRecordings = fetchedRecordings
            }
        } catch {
            if accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch) {
                surface(error)
            }
        }
    }

    // MARK: Sessions

    @discardableResult
    public func logSession(_ draft: SessionDraft) async -> SessionLogReceipt? {
        guard let userID = currentUserID else { return nil }
        let id = UUID()
        let pending = pendingSession(
            id: id,
            draft: draft,
            accountUserID: userID
        )
        pendingSessions[id] = pending
        mergeSessions(remote: sessions.filter { !$0.pending })
        let enqueued = await enqueueSession(draft: draft, id: id)
        if !enqueued {
            // #632: the session is lost — see the notice write in
            // `saveForceSummary`.
            LostRecordingStore.note(reason: "session", in: .standard)
            pendingSessions.removeValue(forKey: id)
            mergeSessions(remote: sessions.filter { !$0.pending })
            return nil
        }
        // The enqueue may have suspended while auth changed. Do not hand a
        // receipt for the old account to a newly signed-in UI.
        guard currentUserID == userID else { return nil }
        return SessionLogReceipt(sessionID: id, accountUserID: userID)
    }

    /// Enqueue a session into the durable queue (and kick off its upload),
    /// showing the optimistic pending row while it lands. `rpeConfirmed`
    /// defaults to `true` (a human entered the number); the #627 gauge-session
    /// path passes `false` — a W'-depletion prediction nobody reviewed —
    /// plus the recordings' group id to link them back.
    @discardableResult
    private func enqueueSession(
        draft: SessionDraft,
        id: UUID,
        rpeConfirmed: Bool? = nil,
        groupID: UUID? = nil
    ) async -> Bool {
        guard let userID = currentUserID else { return false }
        let pending = pendingSession(
            id: id,
            draft: draft,
            accountUserID: userID,
            rpeConfirmed: rpeConfirmed,
            groupID: groupID
        )
        cacheUpsertLocal(
            pending,
            accountUserID: userID,
            entityType: .sessions,
            entityID: CacheEntityID.session(pending)
        )
        pendingSessions[id] = pending
        mergeSessions(remote: sessions.filter { !$0.pending })
        let item = DurableQueueItem(
            id: id,
            accountUserID: userID,
            payload: PendingWrite.session(
                SessionQueuePayload(
                    id: id,
                    draft: draft,
                    rpeConfirmed: rpeConfirmed,
                    groupID: groupID
                )
            )
        )
        let enqueued = await enqueueAndUpload(item)
        if !enqueued {
            _ = cacheMarkDeletedLocal(
                accountUserID: userID,
                entityType: .sessions,
                entityID: id.uuidString
            )
        }
        return enqueued
    }

    public func updateSession(_ session: SendmeterCore.Session) async {
        guard let userID = currentUserID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        let previous = sessions.first { $0.id == session.id }
        var optimistic = session
        optimistic.pending = true
        optimistic.rejected = false
        optimistic.accountUserID = userID
        pendingSessions[session.id] = optimistic
        mergeSessions(remote: sessions.filter { !$0.pending })
        let optimisticRevision = cacheUpsertLocal(
            optimistic,
            accountUserID: userID,
            entityType: .sessions,
            entityID: CacheEntityID.session(optimistic)
        )
        do {
            let saved = try await repository.updateSession(session)
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            pendingSessions.removeValue(forKey: session.id)
            cacheConfirmServerUpsert(
                saved,
                accountUserID: userID,
                entityType: .sessions,
                entityID: CacheEntityID.session(saved),
                confirmingLocalRevision: optimisticRevision
            )
            replaceSession(saved)
            toastMessage = "Session updated."
        } catch {
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            pendingSessions.removeValue(forKey: session.id)
            if let previous {
                cacheConfirmServerUpsert(
                    previous,
                    accountUserID: userID,
                    entityType: .sessions,
                    entityID: CacheEntityID.session(previous),
                    confirmingLocalRevision: optimisticRevision
                )
                replaceSession(previous)
            } else {
                cacheConfirmServerDelete(
                    accountUserID: userID,
                    entityType: .sessions,
                    entityID: CacheEntityID.session(optimistic),
                    confirmingLocalRevision: optimisticRevision
                )
                sessions.removeAll { $0.id == session.id }
            }
            surface(error)
        }
    }

    public func deleteSession(_ session: SendmeterCore.Session) async {
        guard let userID = currentUserID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        let previous = sessions.first { $0.id == session.id }
        pendingSessions.removeValue(forKey: session.id)
        sessions.removeAll { $0.id == session.id }
        let deleteRevision = cacheMarkDeletedLocal(
            accountUserID: userID,
            entityType: .sessions,
            entityID: CacheEntityID.session(session)
        )
        do {
            try await repository.softDeleteSession(id: session.id)
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            cacheConfirmServerDelete(
                accountUserID: userID,
                entityType: .sessions,
                entityID: CacheEntityID.session(session),
                confirmingLocalRevision: deleteRevision
            )
            toastMessage = "Session moved to Trash."
        } catch {
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            if let previous {
                cacheConfirmServerUpsert(
                    previous,
                    accountUserID: userID,
                    entityType: .sessions,
                    entityID: CacheEntityID.session(previous),
                    confirmingLocalRevision: deleteRevision
                )
                replaceSession(previous)
            } else {
                cacheConfirmServerDelete(
                    accountUserID: userID,
                    entityType: .sessions,
                    entityID: CacheEntityID.session(session),
                    confirmingLocalRevision: deleteRevision
                )
            }
            surface(error)
        }
    }

    /// Undo a routine log using the exact receipt returned by `logSession`.
    /// The account-scoped claim and hide marker are made before any await. The
    /// delete intent is then written to the durable pending-write queue before
    /// its soft-delete is attempted, so an uploaded row whose delete fails is
    /// still hidden and retried after refresh/relaunch.
    public func undoSession(_ receipt: SessionLogReceipt) async {
        guard let queue else {
            surface(NSError(
                domain: "SendmeterNative",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "On-device delete queue is unavailable."]
            ))
            return
        }
        guard routineUndo.claim(receipt, currentUserID: currentUserID) else { return }
        let sessionID = receipt.sessionID
        let accountUserID = receipt.accountUserID
        let sessionBeforeUndo = sessions.first { $0.id == sessionID }
        let pendingSessionBeforeUndo = pendingSessions[sessionID]

        pendingSessions.removeValue(forKey: sessionID)
        sessions.removeAll { $0.id == sessionID }
        mergeSessions(remote: sessions.filter { !$0.pending })
        _ = cacheMarkDeletedLocal(
            accountUserID: accountUserID,
            entityType: .sessions,
            entityID: sessionID.uuidString
        )

        // The intent gets its own queue identity. Reusing the session insert's
        // id would let an in-flight insert remove the delete intent when both
        // operations overlap.
        let deleteItem = DurableQueueItem(
            id: UUID(),
            accountUserID: accountUserID,
            payload: PendingWrite.sessionDelete(
                SessionDeleteQueuePayload(sessionID: sessionID)
            )
        )
        do {
            try await queue.enqueue(deleteItem)
            await refreshQueueCount()
            let result = await upload(deleteItem)
            guard currentUserID == accountUserID else { return }
            if result.uploaded { toastMessage = "Routine undone" }
        } catch {
            // The optimistic hide is not durable until the delete intent has
            // been persisted. Roll it back only for the account that made the
            // receipt; a sign-out/user switch must never refresh old-account
            // data into the new account's model.
            let currentAccount = currentUserID
            _ = routineUndo.rollbackClaim(receipt, currentUserID: currentAccount)
            guard currentAccount == accountUserID else { return }
            if let sessionBeforeUndo {
                sessions.removeAll { $0.id == sessionID }
                sessions.append(sessionBeforeUndo)
            }
            if let pendingSessionBeforeUndo {
                pendingSessions[sessionID] = pendingSessionBeforeUndo
            }
            mergeSessions(remote: sessions.filter { !$0.pending })
            if let pendingSessionBeforeUndo {
                cacheUpsertLocal(
                    pendingSessionBeforeUndo,
                    accountUserID: accountUserID,
                    entityType: .sessions,
                    entityID: sessionID.uuidString
                )
            } else if let sessionBeforeUndo {
                cacheConfirmServerUpsert(
                    sessionBeforeUndo,
                    accountUserID: accountUserID,
                    entityType: .sessions,
                    entityID: sessionID.uuidString
                )
            } else {
                _ = cacheMarkDeletedLocal(
                    accountUserID: accountUserID,
                    entityType: .sessions,
                    entityID: sessionID.uuidString
                )
            }
            // The delete never became durable, so a refresh is the final
            // authority when the insert may have completed while Undo was
            // attempting to persist its intent. The local restoration above
            // keeps the already-inserted row truthful even if this refresh
            // itself is offline.
            await refreshAll(showSpinner: false)
            guard currentUserID == accountUserID else { return }
            surface(error)
        }
    }

    public func restoreSession(_ session: SendmeterCore.Session) async {
        guard let userID = currentUserID else { return }
        await perform {
            try await self.repository.restoreSession(id: session.id)
            self.cacheConfirmServerUpsert(
                session,
                accountUserID: userID,
                entityType: .sessions,
                entityID: CacheEntityID.session(session)
            )
            self.deletedSessions.removeAll { $0.id == session.id }
            await self.refreshAll(showSpinner: false)
        }
    }

    public func purgeSession(_ session: SendmeterCore.Session) async {
        guard let userID = currentUserID else { return }
        _ = cacheMarkDeletedLocal(
            accountUserID: userID,
            entityType: .sessions,
            entityID: CacheEntityID.session(session)
        )
        await perform {
            try await self.repository.purgeSession(id: session.id)
            self.cacheConfirmServerDelete(
                accountUserID: userID,
                entityType: .sessions,
                entityID: CacheEntityID.session(session)
            )
            self.deletedSessions.removeAll { $0.id == session.id }
        }
    }

    // MARK: Phase

    public func switchPhase(to phase: PhaseID) async {
        guard let userID = currentUserID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        let previousPeriods = phasePeriods
        let previousSettings = settings
        let today = LocalDateSupport.string(from: Date())
        let preview = localPhaseTransition(
            periods: previousPeriods,
            newPhase: phase,
            today: today
        )
        var periodUpsertRevisions: [UUID: Int] = [:]
        var periodDeleteRevisions: [UUID: Int] = [:]
        var settingsRevision: Int?
        phasePeriods = preview.periods
        settings = preview.settings
        let previewIDs = Set(preview.periods.map(\.id))
        for period in previousPeriods where !previewIDs.contains(period.id) {
            if let revision = cacheMarkDeletedLocal(
                accountUserID: userID,
                entityType: .phasePeriods,
                entityID: period.id.uuidString
            ) {
                periodDeleteRevisions[period.id] = revision
            }
        }
        for period in preview.periods {
            if let revision = cacheUpsertLocal(
                period,
                accountUserID: userID,
                entityType: .phasePeriods,
                entityID: period.id.uuidString
            ) {
                periodUpsertRevisions[period.id] = revision
            }
        }
        settingsRevision = cacheUpsertLocal(
            preview.settings,
            accountUserID: userID,
            entityType: .settings,
            entityID: CacheEntityID.settings
        )
        do {
            let result = try await repository.switchPhase(
                to: phase,
                currentPeriods: previousPeriods,
                today: today,
                userID: userID
            )
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            let serverIDs = Set(result.periods.map(\.id))
            // A same-day switch back deletes the open period from the preview,
            // so it is not in `preview.periods`; confirm its pending tombstone
            // from the server response too, otherwise it stays counted as an
            // unconfirmed local change forever.
            for period in previousPeriods where !serverIDs.contains(period.id) {
                cacheConfirmServerDelete(
                    accountUserID: userID,
                    entityType: .phasePeriods,
                    entityID: period.id.uuidString,
                    confirmingLocalRevision: periodDeleteRevisions[period.id]
                        ?? periodUpsertRevisions[period.id]
                )
            }
            for period in preview.periods where !serverIDs.contains(period.id) {
                cacheConfirmServerDelete(
                    accountUserID: userID,
                    entityType: .phasePeriods,
                    entityID: period.id.uuidString,
                    confirmingLocalRevision: periodUpsertRevisions[period.id]
                )
            }
            for period in result.periods {
                cacheConfirmServerUpsert(
                    period,
                    accountUserID: userID,
                    entityType: .phasePeriods,
                    entityID: CacheEntityID.phasePeriod(period),
                    confirmingLocalRevision: periodUpsertRevisions[period.id]
                )
            }
            cacheConfirmServerUpsert(
                result.settings,
                accountUserID: userID,
                entityType: .settings,
                entityID: CacheEntityID.settings,
                confirmingLocalRevision: settingsRevision
            )
            phasePeriods = result.periods
            settings = result.settings
            toastMessage = "Training Block changed to \(PhaseCatalog.definition(for: phase).name)."
        } catch {
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            for period in preview.periods where !previousPeriods.contains(where: { $0.id == period.id }) {
                cacheConfirmServerDelete(
                    accountUserID: userID,
                    entityType: .phasePeriods,
                    entityID: period.id.uuidString,
                    confirmingLocalRevision: periodUpsertRevisions[period.id]
                )
            }
            for period in previousPeriods {
                cacheConfirmServerUpsert(
                    period,
                    accountUserID: userID,
                    entityType: .phasePeriods,
                    entityID: CacheEntityID.phasePeriod(period),
                    confirmingLocalRevision: periodUpsertRevisions[period.id]
                        ?? periodDeleteRevisions[period.id]
                )
            }
            cacheConfirmServerUpsert(
                previousSettings,
                accountUserID: userID,
                entityType: .settings,
                entityID: CacheEntityID.settings,
                confirmingLocalRevision: settingsRevision
            )
            phasePeriods = previousPeriods
            settings = previousSettings
            surface(error)
        }
    }

    private func localPhaseTransition(
        periods: [PhasePeriod],
        newPhase: PhaseID,
        today: String
    ) -> (periods: [PhasePeriod], settings: UserSettings) {
        var result = periods
        for mutation in PhaseTransitionPlanner.plan(
            periods: periods,
            newPhase: newPhase,
            today: today
        ).mutations {
            switch mutation {
            case let .create(phase, startedOn):
                result.insert(
                    PhasePeriod(id: UUID(), phase: phase, startedOn: startedOn, endedOn: nil),
                    at: 0
                )
            case let .delete(periodID):
                result.removeAll { $0.id == periodID }
            case let .updatePhase(periodID, phase):
                if let index = result.firstIndex(where: { $0.id == periodID }) {
                    result[index].phase = phase
                }
            case let .close(periodID, endedOn):
                if let index = result.firstIndex(where: { $0.id == periodID }) {
                    result[index].endedOn = endedOn
                }
            case let .reopen(periodID):
                if let index = result.firstIndex(where: { $0.id == periodID }) {
                    result[index].endedOn = nil
                }
            case let .updateSettings(phase, startedOn):
                // Settings are derived from the resulting open period below,
                // exactly as the repository does after its own fetch.
                _ = (phase, startedOn)
            }
        }
        let open = result.first(where: { $0.endedOn == nil })
        return (
            result,
            UserSettings(
                currentPhase: open?.phase ?? newPhase,
                phaseStartDate: open?.startedOn ?? today
            )
        )
    }

    // MARK: Workout

    public func saveWorkout(_ draft: WorkoutDraft) async {
        guard let userID = currentUserID, draft.accountUserID == userID else { return }
        let pending = pendingSession(from: draft)
        cacheUpsertLocal(
            pending,
            accountUserID: userID,
            entityType: .sessions,
            entityID: CacheEntityID.session(pending)
        )
        pendingSessions[pending.id] = pending
        mergeSessions(remote: sessions.filter { !$0.pending })
        let item = DurableQueueItem(
            id: draft.sessionID,
            accountUserID: userID,
            payload: PendingWrite.workout(draft)
        )
        if !(await enqueueAndUpload(item)) {
            // #632: the workout draft is lost — see the notice write in
            // `saveForceSummary`.
            LostRecordingStore.note(reason: "workout", in: .standard)
            pendingSessions.removeValue(forKey: draft.sessionID)
            mergeSessions(remote: sessions.filter { !$0.pending })
            _ = cacheMarkDeletedLocal(
                accountUserID: userID,
                entityType: .sessions,
                entityID: draft.sessionID.uuidString
            )
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
        partial: Bool = false,
        /// #678: the note stamped on the recording (e.g. a disconnect-
        /// salvage's "Recovered after connection loss").
        note: String = "",
        /// #678: the durable-loss reason if this save refuses. A manual
        /// recovered-pull save passes `ForceDisconnectSalvage.lossReason` so
        /// a failed recovery is reported as a salvage loss, not an ordinary
        /// recording loss.
        lossReason: String = "recording"
    ) async -> Bool {
        await saveForceSummaryOutcome(
            summary,
            tag: tag,
            side: side,
            zone: zone,
            preset: preset,
            targetBand: targetBand,
            protocolRunID: protocolRunID,
            setNumber: setNumber,
            repetitionNumber: repetitionNumber,
            partial: partial,
            note: note,
            lossReason: lossReason
        ).didPersist
    }

    private func saveForceSummaryOutcome(
        _ summary: ForceSummary,
        tag: String,
        side: TindeqSide,
        zone: RecordedZone?,
        preset: TindeqPreset? = nil,
        targetBand: ForceTargetBand? = nil,
        protocolRunID: UUID? = nil,
        setNumber: Int? = nil,
        repetitionNumber: Int? = nil,
        partial: Bool = false,
        /// #678: the note stamped on the recording. Defaults to "" for a
        /// normal save; a disconnect-salvage passes
        /// `ForceDisconnectSalvage.recoveredNote`.
        note: String = "",
        /// #678: the durable-loss reason. Defaults to "recording"; a
        /// disconnect-salvage passes `ForceDisconnectSalvage.lossReason`.
        lossReason: String = "recording"
    ) async -> ForceSaveOutcome {
        guard let userID = currentUserID else { return .stale }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )

        // The session-end snapshot must count this rep, so the gate is
        // claimed synchronously — before the first await below (#613's
        // RepSettlement contract).
        await gaugeSessionSaveGate.begin()
        defer {
            Task { await gaugeSessionSaveGate.finish() }
        }
        guard accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch) else {
            return .stale
        }

        // #627: the gauge session is minted lazily on the FIRST save; every
        // recording taken during it shares its group id, exactly like the
        // web's `ensureSession` (SL-58).
        let groupID = gaugeSessionTracker.ensureSession(
            now: Date()
        ).groupID

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
            note: note,
            tag: String(tag.prefix(120)),
            side: side,
            groupID: groupID,
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
        cacheUpsertLocal(
            optimistic,
            accountUserID: userID,
            entityType: .recordings,
            entityID: CacheEntityID.recording(optimistic)
        )
        let savedKey = TagCurveKey(
            tag: recording.tag,
            modality: GaugeSessionRPE.modality(of: optimistic)
        )
        // Keep the just-captured samples beside the metadata-only optimistic
        // row. This is the only local copy available before the queue upload
        // has reconciled, and it must participate in the point estimate used
        // by the session-end RPE lookup.
        storePendingCurveSamples(recording.samples, for: recording.id)
        insertPendingRecording(optimistic, accountUserID: userID)
        invalidateTagCurveKeys([savedKey])
        mergeRecordings(
            remote: recordings.filter {
                !pendingRecordings.contains(id: $0.id, accountUserID: userID)
            }
        )
        await refreshTagCurvesForRPE(
            keys: [savedKey],
            capturedBy: accountFetch
        )
        guard accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch) else {
            return .stale
        }
        let item = DurableQueueItem(
            id: recording.id,
            accountUserID: userID,
            payload: PendingWrite.recording(recording)
        )
        let enqueued = await enqueueAndUpload(item)
        guard accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch) else {
            return .stale
        }
        if !enqueued {
            // #632: the rep is lost — the only copy was the in-memory
            // optimistic row being discarded below. The durable one-shot
            // notice IS the out-loud reporting (no Sentry in this target);
            // `surfaceLostRecordingNoticeIfAny` shows it on next foreground.
            LostRecordingStore.note(reason: lossReason, in: .standard)
            _ = cacheMarkDeletedLocal(
                accountUserID: userID,
                entityType: .recordings,
                entityID: recording.id.uuidString
            )
            removePendingRecording(for: recording.id, accountUserID: userID)
            removePendingCurveSamples(for: recording.id)
            invalidateTagCurveKeys([savedKey])
            mergeRecordings(
                remote: recordings.filter {
                    !pendingRecordings.contains(id: $0.id, accountUserID: userID)
                }
            )
            await refreshTagCurvesForRPE(
                keys: [savedKey],
                capturedBy: accountFetch
            )
        }
        // The point fit above is awaited before the save gate finishes. The
        // chart-only band is already queued for this key and is allowed to
        // replace that point estimate in the background.
        return enqueued ? .saved : .failed
    }

    // MARK: Gauge session (#627)

    /// End the active gauge session and auto-log it immediately at the
    /// W'-depletion predicted RPE (#627) — no confirm step, mirroring the
    /// web's `endGaugeSession` (#295) and the watch's `logSessionNow()`
    /// (#280). Called on Finish and on disconnect; the end CLAIM is
    /// synchronous (`endActive()` clears before the first await), so a
    /// Finish tap racing a disconnect effect logs exactly once. The
    /// prediction reads the recorded group's reps against the cached
    /// per-tag curves — never a fresh fetch — so a missing curve falls back
    /// instead of stalling the log.
    public func endGaugeSession(ifCurrentAccountScope expectedScope: NativeAccountScope? = nil) async {
        guard expectedScope == nil || accountScope == expectedScope else { return }
        // #613: wait for any in-flight rep save to become durable + locally
        // published BEFORE claiming the end — a disconnect's interrupted
        // save lands after the status change (the guided view's tick
        // preserves the partial rep), and a late rep must join THIS group,
        // not mint a new one. Bounded by local persistence, never the
        // network. The claim after the wait still precedes any await of the
        // insert, so concurrent end paths still log exactly once.
        await gaugeSessionSaveGate.waitForIdle()
        guard expectedScope == nil || accountScope == expectedScope else { return }
        guard let ended = gaugeSessionTracker.endActive() else { return }

        let groupRecordings = recordings.filter { $0.groupID == ended.groupID }
        let prediction = GaugeSessionRPE.predict(
            recordings: groupRecordings,
            curves: cachedCurves(for: groupRecordings)
        )
        let durationMinutes = GaugeSessionDuration.spanMinutes(recordings: groupRecordings)
            ?? GaugeSessionDuration.clamp(
                minutes: Date().timeIntervalSince(ended.startedAt) / 60
            )
        let draft = SessionDraft(
            date: LocalDateSupport.string(from: ended.startedAt),
            type: "tindeq",
            typeLabel: "Tindeq",
            durationMinutes: durationMinutes,
            rpe: prediction.rpe,
            note: GaugeSessionNote.build(recordings: groupRecordings),
            phase: settings.currentPhase
        )
        let ok = await enqueueSession(
            draft: draft,
            id: UUID(),
            rpeConfirmed: false,
            groupID: ended.groupID
        )
        guard expectedScope == nil || accountScope == expectedScope else { return }
        toastMessage = ok
            ? "Gauge session logged to history"
            : "Couldn\u{2019}t log gauge session. Try again."
    }

    /// #628: a guided protocol's run owns the disconnect-triggered session
    /// end (its interrupted path preserves the final rep first); the generic
    /// disconnect trigger defers while this is set.
    public func setGuidedProtocolActive(_ active: Bool) {
        forceModel.guidedProtocolActive = active
    }

    /// The Force view owns the guided runner, but auth/account lifecycle owns
    /// the revocation boundary. Keep the callback explicit so sign-out and
    /// auth-driven account reset can tear down before the old scope changes.
    public func setGuidedProtocolTeardown(
        ownerID: UUID,
        _ teardown: (@MainActor () async -> Void)?
    ) {
        guidedProtocolTeardownOwnerID = ownerID
        guidedProtocolTeardown = teardown
    }

    public func clearGuidedProtocolTeardown(ownerID: UUID) {
        guard guidedProtocolTeardownOwnerID == ownerID else { return }
        guidedProtocolTeardownOwnerID = nil
        guidedProtocolTeardown = nil
    }

    private func teardownGuidedProtocolBeforeAuthRevocation() async {
        guard guidedProtocolTeardownOwnerID != nil else { return }
        guard GuidedForceAuthTransitionPolicy.steps(
            hasActiveProtocol: guidedProtocolTeardown != nil
        ).first == .some(.teardownGuidedProtocol),
              let ownerID = guidedProtocolTeardownOwnerID
        else { return }
        let teardown = guidedProtocolTeardown
        await teardown?()
        // The callback normally clears itself after its terminal settlement.
        // Keep this matching owner guard as the auth-side backstop: a newer
        // guided session must never lose its callback to an older teardown.
        clearGuidedProtocolTeardown(ownerID: ownerID)
    }

    /// The keep-awake hold follows the transport + arming state (#628): the
    /// screen stays awake while connected (a short auto-lock must never cut
    /// a hold or protocol), armed, or measuring — the web's `useWakeLock`
    /// rule — and the last release restores the idle timer.
    public func scenePhaseChanged(_ phase: ScenePhase) {
        manualWorkoutRest.scenePhaseChanged(phase)
        if phase == .active {
            NotificationCenter.default.post(name: .manualWorkoutActivityAction, object: nil)
            updateKeepAwake()
            // #671: resume the display-rate flush driver for a live stream
            // (recording/armed) torn down on backgrounding.
            tindeq.setFlushDriverPaused(false)
        } else {
            keepAwakeRelease?()
            keepAwakeRelease = nil
            // #671 review N1: only `.background` suspends the process. `.inactive`
            // fires behind a notification banner or Control Center pull while the
            // gauge is still on screen and rendering — tearing the flush driver
            // down then would freeze the live trace mid-pull.
            if phase == .background {
                tindeq.setFlushDriverPaused(true)
                // #747 slice 4: arm the BGAppRefreshTask when the app leaves
                // the foreground. Execution timing is device-only; the
                // testable body is `runBackgroundSync()`.
                BackgroundSyncService.schedule()
            }
        }
    }

    /// Re-derive the keep-awake hold from the transport + arming state.
    /// Public so views can re-assert after local-only changes (the hands-free
    /// toggle) that don't flow through a published property.
    public func updateKeepAwake() {
        let active = tindeq.status == .connected
            || tindeq.status == .measuring
            || tindeq.handsFreeArmed
        if active, keepAwakeRelease == nil {
            keepAwakeRelease = keepAwake.acquire()
        } else if !active, let release = keepAwakeRelease {
            release()
            keepAwakeRelease = nil
        }
    }

    // MARK: Hands-free force (#628)

    private func armHandsFreeStream() {
        do {
            try tindeq.armHandsFree()
        } catch {
            handsFree.handleDisconnected()
            errorMessage = UserFacingError.message(for: error)
        }
    }

    /// The claimed hands-free stop: stop the device, save the rep against
    /// the free-pull context snapshot, trim the low-force release tail, and
    /// re-arm only once the save is DURABLE (so a failed save can never
    /// re-arm a stream that still owes a rep). The `.stopping` phase is the
    /// controller's claim; re-arm is the controller's `rearmAfterSave()`.
    private func completeHandsFreeRep() {
        guard let summary = tindeq.stopMeasuring() else {
            handsFree.disarm()
            return
        }
        let context = freePullContext
        let trimEndMilliseconds = handsFree.consumeTrimEndMilliseconds()
        // #682 Guard 1: the verdict runs LAST, at the persist boundary, on the
        // trimmed evidence (a `.staticLoad` termination trims to the flat-window
        // start; release trims to the release edge). A trivial rep — peak below
        // `minPeakKg` or duration below `minDurationMs` — is discarded silently
        // here, BEFORE `saveForceSummaryOutcome`, so it never enters the
        // recording queue and is never reported as queued. Only hands-free reps
        // reach this function; manual recordings (which go through
        // `saveForceSummary`) are unchanged while hands-free is opt-in.
        let trimmed = trimSummary(summary, endMilliseconds: trimEndMilliseconds)
        if recordingVerdict(
            peakKg: trimmed.peakKilograms,
            durationMs: Double(trimmed.durationMilliseconds)
        ) != .persist {
            tindeq.clearCompletedRecording()
            handsFree.rearmAfterSave()
            return
        }
        Task {
            let outcome = await saveForceSummaryOutcome(
                trimmed,
                tag: context.tag,
                side: context.side,
                zone: context.zone,
                preset: context.preset,
                targetBand: context.targetBand
            )
            if outcome.didPersist {
                tindeq.clearCompletedRecording()
                handsFree.rearmAfterSave()
            } else if outcome.shouldDisarmHandsFree {
                handsFree.disarm()
                if outcome.shouldReportHandsFreeFailure {
                    errorMessage = UserFacingError.message(for: .saveFailed)
                }
            }
        }
    }

    /// #678: the disconnect-salvage save. Routes the already-claimed
    /// interrupted rep through `saveForceSummaryOutcome` so it persists with an
    /// explicit `accountUserID`, the tag/side LOCKED at recording start (web
    /// #298 — never a fallback), and the recovered note — and reports a durable
    /// loss (`LostRecordingStore`, via `saveForceSummaryOutcome`) if the save
    /// refuses. The buffer was cleared synchronously by the caller's claim, so
    /// the only paths here are: it survived, or it is honestly reported lost.
    private func salvageInterruptedRecording(_ summary: ForceSummary, wasHandsFree: Bool) async {
        // #682 Guard 1 (watch parity): a sub-threshold hands-free rep that ends
        // by a BLE drop is discarded, silently, exactly like the normal
        // hands-free stop path — it never enters the recording queue nor
        // reports a durable loss. Manual interrupted reps are never gated.
        if !ForceDisconnectSalvage.shouldPersistSalvage(
            wasHandsFree: wasHandsFree,
            peakKg: summary.peakKilograms,
            durationMs: Double(summary.durationMilliseconds)
        ) {
            clearForceRecordingLock()
            return
        }
        // #678: the LOCK is the single authority (web #298 "never a fallback").
        // When no lock was captured the rep is saved honestly untagged/
        // unspecified — never re-derived from the live pickers. The AppModel-
        // held lock survives a Force tab remount, so there is no drop-time
        // snapshot fallback to consider.
        let lock = forceRecordingLock ?? FreePullContext()
        let resolved = ForceDisconnectSalvage.attribution(
            locked: ForceDisconnectSalvage.Attribution(tag: lock.tag, side: lock.side)
        )
        let outcome = await saveForceSummaryOutcome(
            summary,
            tag: resolved.tag,
            side: resolved.side,
            zone: lock.zone,
            preset: lock.preset,
            targetBand: lock.targetBand,
            note: ForceDisconnectSalvage.recoveredNote,
            lossReason: ForceDisconnectSalvage.lossReason
        )
        switch outcome {
        case .saved:
            clearForceRecordingLock()
        case .failed:
            // `saveForceSummaryOutcome` already recorded the durable loss
            // under `ForceDisconnectSalvage.lossReason`; say so out loud too.
            clearForceRecordingLock()
            errorMessage = UserFacingError.message(for: .saveFailed)
        case .stale:
            // The account no longer owns the active model — signing out or a
            // mid-save epoch change. Not a persistence failure (no loss to
            // report), and the interrupted buffer is already claimed, so the
            // rep cannot be recovered under the wrong account.
            break
        }
    }

    /// #503's trim contract: a release-triggered stop ends the rep at the
    /// proven release point on the recording clock; a manual tap (nil trim)
    /// keeps the whole buffer.
    private func trimSummary(_ summary: ForceSummary, endMilliseconds: Double?) -> ForceSummary {
        guard let endMilliseconds else { return summary }
        let trimmedSamples = summary.samples.filter { $0.milliseconds <= endMilliseconds }
        guard !trimmedSamples.isEmpty else { return summary }
        let peak = trimmedSamples.map(\.kilograms).max() ?? summary.peakKilograms
        let average = trimmedSamples.reduce(0) { $0 + $1.kilograms } / Double(trimmedSamples.count)
        let duration = max(1, Int(endMilliseconds.rounded()))
        return ForceSummary(
            durationMilliseconds: duration,
            peakKilograms: peak,
            averageKilograms: average,
            samples: trimmedSamples
        )
    }

    // MARK: Tag curves (#627)

    /// The prediction's synchronous cache read — never a fetch, so ending a
    /// session cannot stall (the web's #613 rule).
    private func cachedCurves(for recordings: [TindeqRecording]) -> [TagForceCurve] {
        var seen = Set<TagCurveKey>()
        return recordings.compactMap { recording in
            let key = TagCurveKey(
                tag: recording.tag,
                modality: GaugeSessionRPE.modality(of: recording)
            )
            guard !key.tag.isEmpty, !seen.contains(key) else { return nil }
            seen.insert(key)
            return tagCurveCache[key]
        }
    }

    /// Background-warm the tag's fitted curve (mirrors the web's cached
    /// `fetchTagCurves()` registry): computed from the native recordings via
    /// ForceCurveEngine, cached per tag+modality. Each key owns its task, so a
    /// new rep only cancels/restarts the affected fit instead of discarding
    /// unrelated tags' work.
    public func warmTagCurveIfMissing(tag: String, modality: String) {
        guard let userID = currentUserID else { return }
        warmTagCurveIfMissing(
            tag: tag,
            modality: modality,
            capturedBy: AccountScopedFetch(
                accountUserID: userID,
                accountEpoch: accountEpoch
            )
        )
    }

    /// Computes the Static curve for the Force progress detail's selected
    /// side. The published tag-curve cache intentionally remains all-sides
    /// because RPE and Focus Next consume that identity; this one-shot detail
    /// fit is scoped to the same measured Static evidence as the trend.
    public func forceProgressCurveInputKey(
        tag: String?,
        side: TindeqSide?
    ) -> ForceProgressCurveInputKey {
        ForceProgressCurveInputKey(
            selectedTag: tag,
            selectedSide: side?.rawValue,
            revision: forceModel.forceProgressRevision,
            accountUserID: currentUserID,
            accountEpoch: accountEpoch
        )
    }

    public func forceCurveModel(
        tag: String,
        side: TindeqSide,
        inputKey: ForceProgressCurveInputKey? = nil
    ) async -> ForceCurveModel? {
        let requestKey = inputKey
            ?? forceProgressCurveInputKey(tag: tag, side: side)
        guard !Task.isCancelled,
              side != .unspecified,
              let userID = currentUserID
        else { return nil }
        guard forceProgressCurveInputKey(tag: tag, side: side) == requestKey else {
            return nil
        }

        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        let recordingsSnapshot = recordings
        let pendingIDs = pendingRecordings.ids(accountUserID: userID)
        let locallyAvailableSampleIDs = Set(
            pendingCurveSamples.compactMap { id, samples in
                samples.isEmpty ? nil : id
            }
        )
        let evidence = ForceProgress.staticCapacityEvidence(
            recordings: recordingsSnapshot,
            tag: tag,
            side: side
        )
        let candidates = ForceCurveEngine.pickCurveRecordings(
            evidence.curveFitRecordings.filter {
                TagCurveCachePolicy.includes(
                    recordingID: $0.id,
                    pendingIDs: pendingIDs,
                    locallyAvailableSampleIDs: locallyAvailableSampleIDs
                )
            }
        )
        guard !candidates.isEmpty else { return nil }

        let curveModel = await fetchForceCurveModel(
            candidates: candidates,
            localSamples: pendingCurveSamples,
            purpose: .chartBand
        )
        guard !Task.isCancelled,
              accountFetch.canApply(
                  to: currentUserID,
                  accountEpoch: accountEpoch
              ),
              forceProgressCurveInputKey(tag: tag, side: side) == requestKey
        else { return nil }
        return curveModel
    }

    private func warmTagCurveIfMissing(
        tag: String,
        modality: String,
        capturedBy accountFetch: AccountScopedFetch
    ) {
        guard accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch) else {
            return
        }
        let key = TagCurveKey(tag: tag, modality: modality)
        guard !key.tag.isEmpty, !key.modality.isEmpty else { return }
        let generation = tagCurveGenerations.generation(for: key)
        // A chart fit that completed with no capability model is still a
        // completed answer for this generation. It must not be retried on
        // every view update until the next input invalidation.
        guard tagCurveBandGenerations[key] != generation,
              tagCurveWarmTasks[key] == nil
        else { return }
        let request = TagCurveCacheRequest(
            accountFetch: accountFetch,
            generation: generation
        )
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.runTagCurveWarm(key: key, request: request)
        }
        tagCurveWarmTasks[key] = task
        tagCurveWarmTaskGenerations[key] = generation
    }

    private func runTagCurveWarm(
        key: TagCurveKey,
        request: TagCurveCacheRequest
    ) async {
        defer {
            if tagCurveWarmTaskGenerations[key] == request.generation {
                tagCurveWarmTaskGenerations.removeValue(forKey: key)
                tagCurveWarmTasks.removeValue(forKey: key)
            }
        }
        guard request.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch,
            currentGeneration: tagCurveGenerations.generation(for: key)
        ) else { return }
        let curve = await computeTagCurve(
            key: key,
            purpose: .chartBand
        )
        guard !Task.isCancelled,
              request.canApply(
                  to: currentUserID,
                  accountEpoch: accountEpoch,
                  currentGeneration: tagCurveGenerations.generation(for: key)
              )
        else { return }
        _ = request.accountFetch.publishIfCurrent(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) {
            if let curve {
                tagCurveCache[key] = curve
            } else if tagCurveCache[key] == nil {
                // A chart-only fetch/fit failure must not erase the awaited
                // point estimate that the save path already made available
                // to synchronous RPE. It will be replaced on the next input
                // invalidation or authoritative refresh.
                tagCurveCache.removeValue(forKey: key)
            }
            tagCurveBandGenerations[key] = request.generation
            publishTagCurves()
        }
    }

    private func publishTagCurves() {
        forceModel.tagCurves = tagCurveCache.values.sorted {
            $0.tag < $1.tag || ($0.tag == $1.tag && $0.modality < $1.modality)
        }
        // The fitted model is a progress-card input too. Use the same small
        // published revision as recording metadata so an Equatable card can
        // ignore display-rate Tindeq frames without hiding a new curve.
        publishForceProgressInputMutation(.curveModel)
    }

    /// Rebuilds only the point estimate needed by the synchronous RPE lookup.
    /// The 200-resample display band is deliberately scheduled separately so
    /// a rep save never pays that chart-only cost before the session-end gate
    /// releases.
    private func refreshTagCurvesForRPE(
        keys: Set<TagCurveKey>,
        capturedBy accountFetch: AccountScopedFetch
    ) async {
        for key in keys.sorted(by: tagCurveKeySort) {
            guard accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch) else {
                return
            }
            let request = TagCurveCacheRequest(
                accountFetch: accountFetch,
                generation: tagCurveGenerations.generation(for: key)
            )
            let curve = await computeTagCurve(
                key: key,
                purpose: .pointEstimate
            )
            guard request.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch,
                currentGeneration: tagCurveGenerations.generation(for: key)
            ) else { continue }
            _ = request.accountFetch.publishIfCurrent(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) {
                if let curve {
                    tagCurveCache[key] = curve
                } else {
                    // A current no-fit result must remove an old curve rather
                    // than leave stale CF/W′/Max values on the Force card.
                    tagCurveCache.removeValue(forKey: key)
                }
                // A point estimate is not a completed chart fit. The next
                // line schedules the band-only replacement for this key.
                tagCurveBandGenerations.removeValue(forKey: key)
                publishTagCurves()
            }
            warmTagCurveIfMissing(
                tag: key.tag,
                modality: key.modality,
                capturedBy: accountFetch
            )
        }
    }

    private func tagCurveKeySort(_ lhs: TagCurveKey, _ rhs: TagCurveKey) -> Bool {
        lhs.tag < rhs.tag || (lhs.tag == rhs.tag && lhs.modality < rhs.modality)
    }

    private func computeTagCurve(
        key: TagCurveKey,
        purpose: TagCurveFitPurpose
    ) async -> TagForceCurve? {
        let recordingsSnapshot = recordings
        let pendingIDs = Set(
            recordingsSnapshot.compactMap { recording in
                pendingRecordings.contains(id: recording.id, accountUserID: currentUserID)
                    ? recording.id
                    : nil
            }
        )
        let locallyAvailableSampleIDs = Set(
            pendingCurveSamples.compactMap { id, samples in
                samples.isEmpty ? nil : id
            }
        )
        let byTag = recordingsSnapshot.filter {
            TagCurveKey(
                tag: $0.tag,
                modality: GaugeSessionRPE.modality(of: $0)
            ) == key
                && !$0.rejected
                && TagCurveCachePolicy.includes(
                    recordingID: $0.id,
                    pendingIDs: pendingIDs,
                    locallyAvailableSampleIDs: locallyAvailableSampleIDs
                )
                && modalityFilter($0, modality: key.modality)
                // #651: warm-up/prehab (submaximal) and salvage blobs
                // (inflated duration / deflated avg) corrupt CF/W′ — exclude
                // them exactly like the web's `curveCandidateRecordings`.
                && ZoneMix.isCurveFitCandidate($0)
        }
        guard !byTag.isEmpty else { return nil }
        let candidates = ForceCurveEngine.pickCurveRecordings(byTag)
        guard !candidates.isEmpty else { return nil }
        let curveModel = await fetchForceCurveModel(
            candidates: candidates,
            localSamples: pendingCurveSamples,
            purpose: purpose
        )
        guard let curveModel else { return nil }
        guard !Task.isCancelled,
              let cf = curveModel.criticalForceKilograms,
              let wPrime = curveModel.impulseAboveCriticalForceKilogramSeconds
        else { return nil }
        let displayTag = recordingsSnapshot.first {
            TagCurveKey(
                tag: $0.tag,
                modality: GaugeSessionRPE.modality(of: $0)
            ) == key
        }?.tag ?? key.tag
        return TagForceCurve(
            tag: displayTag,
            modality: key.modality,
            cf: cf,
            wPrime: wPrime,
            maxForceKilograms: curveModel.maximumForceKilograms,
            forceCurveModel: curveModel
        )
    }

    private func fetchForceCurveModel(
        candidates: [TindeqRecording],
        localSamples: [UUID: [TindeqSample]],
        purpose: TagCurveFitPurpose
    ) async -> ForceCurveModel? {
        guard !candidates.isEmpty else { return nil }
        let repository = self.repository
        let sampleSets = await withTaskGroup(of: ForceCurveSampleFetch.self) { group in
            for (candidateIndex, candidate) in candidates.enumerated() {
                group.addTask {
                    if let samples = localSamples[candidate.id], !samples.isEmpty {
                        return ForceCurveSampleFetch(
                            candidateIndex: candidateIndex,
                            samples: samples
                        )
                    }
                    let samples = try? await repository.fetchRecordingSamples(id: candidate.id)
                    return ForceCurveSampleFetch(
                        candidateIndex: candidateIndex,
                        samples: (samples?.isEmpty == false) ? samples : nil
                    )
                }
            }
            var completed: [ForceCurveSampleFetch] = []
            for await result in group {
                completed.append(result)
            }
            return ForceCurveEngine.orderedSampleSets(
                candidateCount: candidates.count,
                completed: completed
            )
        }
        guard !Task.isCancelled, !sampleSets.isEmpty else { return nil }
        return await Task.detached(priority: .utility) {
            ForceCurveEngine.compute(
                recordings: sampleSets,
                bootstrapSamples: purpose.bootstrapSamples
            )
        }.value
    }

    private func modalityFilter(_ recording: TindeqRecording, modality: String) -> Bool {
        if modality == "reverse_action" {
            return recording.protocolMode == .reverseAction && recording.capacityEvidence == true
        }
        return recording.protocolMode != .reverseAction
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
                && !pendingRecordings.contains(id: $0.id, accountUserID: currentUserID)
                && ($0.protocolMode != .reverseAction || $0.capacityEvidence == true)
                // #651: effort-only for PR/trend — warm-up/prehab never win by
                // walkover. Recovery blobs are deliberately NOT excluded here:
                // a blob's peakKg is a max over samples, unaffected by rest
                // contamination (web #486 asymmetry).
                && ZoneMix.isEffortRecording($0)
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

        let candidates = ForceCurveEngine.pickCurveRecordings(
            metadata.filter(ZoneMix.isCurveFitCandidate)
        )
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
            // #651: `metadata` here is EFFORT-only (PR/trend keep a recovered
            // blob's valid peakKg), while `sampleSets` came from
            // curve-fit candidates — a salvage blob's inflated duration /
            // deflated avg never reaches the CF/W′ regression. Web #486
            // asymmetry preserved.
            ForceCurveEngine.references(metadata: metadata, sampleSets: sampleSets)
        }.value
    }

    /// Save the History recording editor's metadata and, when the recording is
    /// linked to a session, its session RPE through the same durable queue used
    /// for native inserts. `sessionRPE == nil` means leave the linked session's
    /// current value alone (useful for callers that only edit tag/side/note).
    public func updateRecording(
        _ recording: TindeqRecording,
        sessionRPE: Double? = nil
    ) async {
        guard let userID = currentUserID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        guard !recordingEditCoordinator.isDeleted(recording.id) else { return }
        let linkedSession = recording.groupID.flatMap { groupID in
            sessions.first { $0.groupID == groupID && !$0.pending }
        }
        // A metadata-only save must not discard an RPE edit that is already
        // queued for this linked session. Carry that optimistic value forward
        // into the coalesced payload so the stable queue item remains the
        // complete latest form state.
        let effectiveSessionRPE = sessionRPE ?? linkedSession.flatMap {
            pendingSessionRPEEdits[$0.id]?.sessionRPE
        }
        let editCreatedAt = Date()
        let sessionRPERevision: UInt64?
        if linkedSession != nil, effectiveSessionRPE != nil {
            sessionRPERevision = recordingEditCoordinator.nextSessionRPERevision(
                now: editCreatedAt
            )
        } else {
            sessionRPERevision = nil
        }
        // HistoryView passes its already-edited binding here. Capture the row
        // that still owns the current cache key before the first await; using
        // `recording` for both sides would lose Crimp when the draft is Pinch.
        let authoritativeBefore = recordings.first(where: { $0.id == recording.id })
        let authoritativeOldKey = authoritativeBefore.map {
            TagCurveKey(
                tag: $0.tag,
                modality: GaugeSessionRPE.modality(of: $0)
            )
        }
        let draftKey = TagCurveKey(
            tag: recording.tag,
            modality: GaugeSessionRPE.modality(of: recording)
        )
        let edit = RecordingEdit(
            recordingID: recording.id,
            tag: recording.tag,
            side: recording.side,
            note: recording.note,
            sessionID: linkedSession?.id,
            sessionRPE: effectiveSessionRPE,
            sessionRPERevision: sessionRPERevision
        )
        let previousRecording = recordings.first { $0.id == recording.id } ?? recording
        let previousSession = linkedSession
        let editOrderingKey = edit.sessionRPERevision
            ?? recordingEditCoordinator.nextEditorOrderingKey(now: editCreatedAt)

        applyPendingRecordingEdit(edit)
        if let optimisticRecording = recordings.first(where: { $0.id == recording.id }) {
            cacheUpsertLocal(
                optimisticRecording,
                accountUserID: userID,
                entityType: .recordings,
                entityID: CacheEntityID.recording(optimisticRecording)
            )
        }
        if let sessionID = edit.sessionID,
           let optimisticSession = sessions.first(where: { $0.id == sessionID }) {
            cacheUpsertLocal(
                optimisticSession,
                accountUserID: userID,
                entityType: .sessions,
                entityID: CacheEntityID.session(optimisticSession)
            )
        }
        let metadataEdit = RecordingEdit(
            recordingID: edit.recordingID,
            tag: edit.tag,
            side: edit.side,
            note: edit.note
        )
        let metadataItem = DurableQueueItem(
            id: RecordingEditQueueIdentity.recording(edit.recordingID),
            accountUserID: userID,
            createdAt: editCreatedAt,
            orderingKey: editOrderingKey,
            terminalKey: edit.recordingID,
            payload: PendingWrite.recordingEdit(metadataEdit)
        )
        let rpeItem: DurableQueueItem<PendingWrite>?
        if let sessionID = edit.sessionID, edit.sessionRPE != nil {
            rpeItem = DurableQueueItem(
                id: RecordingEditQueueIdentity.sessionRPE(sessionID),
                accountUserID: userID,
                createdAt: editCreatedAt,
                orderingKey: editOrderingKey,
                terminalKey: edit.recordingID,
                payload: PendingWrite.sessionRPEEdit(edit)
            )
        } else {
            rpeItem = nil
        }
        var items: [DurableQueueItem<PendingWrite>] = [metadataItem]
        if let rpeItem { items.append(rpeItem) }
        // Keep this edit on the caller's task through its first upload
        // attempt. That serializes successive online saves from the detail
        // view. The stable queue id coalesces successive offline saves, so a
        // stale metadata PATCH cannot overwrite the newest one on replay.
        let enqueued = await enqueueAndUpload(
            items,
            startUpload: false,
            capturedBy: accountFetch
        )
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return }
        if !enqueued {
            rollbackPendingRecordingEdit(
                edit,
                previousRecording: previousRecording,
                previousSession: previousSession
            )
            cacheConfirmServerUpsert(
                previousRecording,
                accountUserID: userID,
                entityType: .recordings,
                entityID: CacheEntityID.recording(previousRecording)
            )
            if let previousSession {
                cacheConfirmServerUpsert(
                    previousSession,
                    accountUserID: userID,
                    entityType: .sessions,
                    entityID: CacheEntityID.session(previousSession)
                )
            }
        } else {
            let metadataResult = await upload(metadataItem, capturedBy: accountFetch)
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            if metadataResult.uploaded {
                let saved = recordings.first(where: { $0.id == recording.id }) ?? recording
                let newKey = TagCurveKey(
                    tag: saved.tag,
                    modality: GaugeSessionRPE.modality(of: saved)
                )
                let keys = TagCurveCachePolicy.metadataEditKeys(
                    authoritativeBefore: authoritativeOldKey,
                    draft: draftKey,
                    saved: newKey
                )
                await refreshTagCurvesForRPE(keys: keys, capturedBy: accountFetch)
                guard accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else { return }
            }
            if let rpeItem {
                _ = await upload(rpeItem, capturedBy: accountFetch)
                guard accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else { return }
            }
        }
    }

    public func deleteRecording(_ recording: TindeqRecording) async {
        guard let userID = currentUserID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        let key = TagCurveKey(
            tag: recording.tag,
            modality: GaugeSessionRPE.modality(of: recording)
        )
        guard let deleteToken = recordingEditCoordinator.beginDelete(
            recordingID: recording.id,
            capturedBy: accountFetch
        ) else { return }

        let previousRecording = recordings.first { $0.id == recording.id } ?? recording
        let previousEdit = pendingRecordingEdits[recording.id]
        let initialSessionID = previousEdit?.sessionID ?? recording.groupID.flatMap { groupID in
            sessions.first { $0.groupID == groupID && !$0.pending }?.id
        }
        var barrierSessionID = initialSessionID
        var barrierToken = initialSessionID.map {
            recordingEditCoordinator.beginSessionRPEBarrier(sessionID: $0)
        }
        var canceledQueueEdits: [DurableQueueItem<PendingWrite>] = []
        var previousSessionEdit: RecordingEdit?
        var previousSessionRPEOrderingKey: UInt64?
        var previousSessionBase: SendmeterCore.Session?
        var previousSession = initialSessionID.flatMap { sessionID in
            sessions.first { $0.id == sessionID && !$0.pending }
        }
        var deleteIntentPersisted = false
        defer {
            if let barrierToken {
                _ = recordingEditCoordinator.endSessionRPEBarrier(barrierToken)
                if let barrierSessionID {
                    Task { [weak self] in
                        await self?.drainSessionRPE(
                            sessionID: barrierSessionID,
                            accountUserID: userID,
                            capturedBy: accountFetch
                        )
                    }
                }
            }
        }

        do {
            guard await migrateLegacyRecordingEdits(
                userID: userID,
                capturedBy: accountFetch
            ) != nil,
            accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else {
                throw NSError(
                    domain: "SendmeterNative",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Recording edits could not be migrated."]
                )
            }
            let queuedEdits = await recordingEditQueueItems(
                recordingID: recording.id,
                sessionID: barrierSessionID,
                accountUserID: userID
            )
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            if barrierSessionID == nil {
                let discoveredSessionID = Set(
                    queuedEdits.compactMap { item -> UUID? in
                        switch item.payload {
                        case let .recordingEdit(edit), let .sessionRPEEdit(edit):
                            return edit.sessionID
                        default:
                            return nil
                        }
                    }
                ).sorted { $0.uuidString < $1.uuidString }.first
                if let discoveredSessionID {
                    barrierSessionID = discoveredSessionID
                    barrierToken = recordingEditCoordinator.beginSessionRPEBarrier(
                        sessionID: discoveredSessionID
                    )
                    previousSession = sessions.first {
                        $0.id == discoveredSessionID && !$0.pending
                    }
                }
            }
            if let barrierSessionID {
                await waitForSessionRPEWrites(sessionID: barrierSessionID)
                guard accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else { return }
            }

            canceledQueueEdits = queuedEdits.filter { item in
                sourceRecordingID(for: item.payload) == recording.id
            }
            let candidates = queuedEdits.compactMap { item -> RecordingEditQueueCandidate? in
                switch item.payload {
                case let .recordingEdit(edit), let .sessionRPEEdit(edit):
                    guard edit.sessionID != nil, edit.sessionRPE != nil else { return nil }
                    return RecordingEditQueueCandidate(
                        edit: edit,
                        queueItemID: item.id,
                        createdAt: item.createdAt,
                        nextAttemptAt: item.nextAttemptAt
                    )
                default:
                    return nil
                }
            }
            let authoritative = barrierSessionID.flatMap {
                RecordingEditMigration.authoritativeSessionRPE(
                    sessionID: $0,
                    candidates: candidates
                )
            }
            if authoritative?.edit.recordingID == recording.id {
                previousSessionEdit = authoritative?.edit
                previousSessionRPEOrderingKey = authoritative?.ordering.primary
            } else if let barrierSessionID,
                      let sessionEdit = pendingSessionRPEEdits[barrierSessionID],
                      sessionEdit.recordingID == recording.id,
                      authoritative == nil {
                // A relaunch can restore the optimistic overlay before the
                // durable item is visible in this snapshot. It is still the
                // deleted recording's claim when no authoritative queue
                // replacement exists.
                previousSessionEdit = sessionEdit
                previousSessionRPEOrderingKey = sessionEdit.sessionRPERevision
            }

            pendingRecordingEdits.removeValue(forKey: recording.id)
            if let previousSessionEdit,
               let sessionID = previousSessionEdit.sessionID,
               pendingSessionRPEEdits[sessionID]?.recordingID == recording.id {
                previousSessionBase = pendingSessionRPEBases.removeValue(forKey: sessionID)
                    ?? sessions.first { $0.id == sessionID && !$0.pending }
                    ?? previousSession
                pendingSessionRPEEdits.removeValue(forKey: sessionID)
                if let previousSessionBase {
                    replaceSession(previousSessionBase)
                }
            }
            let before = recordings
            _ = cacheMarkDeletedLocal(
                accountUserID: userID,
                entityType: .recordings,
                entityID: CacheEntityID.recording(recording)
            )
            if let previousSessionBase {
                cacheUpsertLocal(
                    previousSessionBase,
                    accountUserID: userID,
                    entityType: .sessions,
                    entityID: CacheEntityID.session(previousSessionBase)
                )
            }
            recordings.removeAll { $0.id == recording.id }
            publishForceProgressRecordingMutationIfNeeded(before: before, after: recordings)
            invalidateTagCurveKeys([key])

            let deleteCreatedAt = Date()
            let deleteItem: DurableQueueItem<PendingWrite> = DurableQueueItem(
                id: RecordingEditQueueIdentity.delete(recording.id),
                accountUserID: userID,
                createdAt: deleteCreatedAt,
                // The terminal marker, not editor ordering, dominates a
                // delete. Keeping this at zero prevents the delete's wall
                // clock from entering the session-RPE watermark/floor.
                orderingKey: 0,
                terminalKey: recording.id,
                payload: .recordingDelete(
                    RecordingDeleteQueuePayload(
                        recordingID: recording.id,
                        operationID: deleteToken.id,
                        sessionID: previousSessionEdit?.sessionID,
                        previousSessionRPE: previousSessionBase?.rpe,
                        previousSessionRPEConfirmed: previousSessionBase?.rpeConfirmed,
                        compensationOrderingKey: previousSessionRPEOrderingKey,
                        compensationState: .pending
                    )
                )
            )
            let legacyRemovals = canceledQueueEdits
                .filter { $0.terminalKey == nil }
                .map {
                    DurableQueueRemoval(
                        id: $0.id,
                        accountUserID: $0.accountUserID,
                        expectedRevision: $0.revision
                    )
                }
            guard let queue else {
                throw NSError(
                    domain: "SendmeterNative",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "On-device delete queue is unavailable."]
                )
            }
            guard try await queue.enqueueTerminalDelete(
                deleteItem,
                terminalKey: recording.id,
                canceling: legacyRemovals,
                preservingOrderingIdentities: barrierSessionID.map {
                    [RecordingEditQueueIdentity.sessionRPE($0)]
                } ?? []
            ) else {
                throw NSError(
                    domain: "SendmeterNative",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "The recording delete was already completed."]
                )
            }
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            deleteIntentPersisted = true
            let result = await upload(deleteItem, capturedBy: accountFetch)
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            if result.uploaded {
                toastMessage = "Force recording moved to Trash."
            }
            await refreshTagCurvesForRPE(
                keys: [key],
                capturedBy: accountFetch
            )
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
        } catch {
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            // Once the terminal intent is durable, keep the tombstone and the
            // optimistic removal. The queue owns retrying the backend delete;
            // re-enqueuing edits here would reopen the race this path closes.
            guard !deleteIntentPersisted else {
                surface(error)
                return
            }
            guard recordingEditCoordinator.clearDelete(
                deleteToken,
                currentUserID: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            if let previousEdit {
                pendingRecordingEdits[recording.id] = previousEdit
            }
            if let previousSessionEdit,
               let sessionID = previousSessionEdit.sessionID {
                pendingSessionRPEEdits[sessionID] = previousSessionEdit
                if let previousSessionBase {
                    pendingSessionRPEBases[sessionID] = previousSessionBase
                    replaceSession(previousSessionBase)
                } else if let previousSession {
                    replaceSession(previousSession)
                }
            }
            replaceRecording(previousRecording)
            cacheConfirmServerUpsert(
                previousRecording,
                accountUserID: userID,
                entityType: .recordings,
                entityID: CacheEntityID.recording(previousRecording)
            )
            if let previousSessionBase {
                cacheConfirmServerUpsert(
                    previousSessionBase,
                    accountUserID: userID,
                    entityType: .sessions,
                    entityID: CacheEntityID.session(previousSessionBase)
                )
            }
            await refreshTagCurvesForRPE(
                keys: [key],
                capturedBy: accountFetch
            )
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            surface(error)
        }
    }

    public func restoreRecording(_ recording: TindeqRecording) async {
        guard let userID = currentUserID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        let key = TagCurveKey(
            tag: recording.tag,
            modality: GaugeSessionRPE.modality(of: recording)
        )
        guard let restoreToken = recordingEditCoordinator.beginRestore(
            recordingID: recording.id,
            capturedBy: accountFetch
        ) else { return }
        // Capture the exact server tombstone before the first await. A Date
        // rounded from this token is not enough to protect A→B→A restore
        // completions, so the repository conditions its PATCH on the raw
        // observed value.
        let expectedDeletedAtToken = recording.deletedAtToken
        defer {
            _ = recordingEditCoordinator.clearRestore(
                restoreToken,
                currentUserID: currentUserID,
                accountEpoch: accountEpoch
            )
        }
        let deleteKey = QueueUploadKey(
            itemID: RecordingEditQueueIdentity.delete(recording.id),
            accountUserID: userID
        )
        await waitForQueueUpload(deleteKey)
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return }
        let expectedTombstone = recordingEditCoordinator.tombstoneToken(
            recordingID: recording.id
        )
        let expectedTerminalOperation = await queue?.terminalizedToken(
            for: recording.id,
            accountUserID: userID
        )
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return }
        let pendingDelete = await queue?.item(
            id: RecordingEditQueueIdentity.delete(recording.id),
            accountUserID: userID
        )
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return }
        do {
            guard let expectedDeletedAtToken else {
                throw RecordingRestoreError.missingTombstoneObservation
            }
            try await repository.restoreRecording(
                id: recording.id,
                expectedDeletedAtToken: expectedDeletedAtToken
            )
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            if let queue {
                if let pendingDelete {
                    guard try await queue.cancelPendingTerminalDelete(
                        id: pendingDelete.id,
                        accountUserID: userID,
                        expectedRevision: pendingDelete.revision,
                        terminalKey: recording.id
                    ) else {
                        throw NSError(
                            domain: "SendmeterNative",
                            code: 6,
                            userInfo: [NSLocalizedDescriptionKey: "The recording delete changed while restoring."]
                        )
                    }
                }
                guard accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else { return }
                guard try await queue.clearTerminalized(
                    key: recording.id,
                    accountUserID: userID,
                    expectedOperationID: expectedTerminalOperation
                ) else {
                    throw NSError(
                        domain: "SendmeterNative",
                        code: 7,
                        userInfo: [NSLocalizedDescriptionKey: "The recording restore changed while restoring."]
                    )
                }
                guard accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else { return }
            }
            guard recordingEditCoordinator.clearDelete(
                recordingID: recording.id,
                expectedToken: expectedTombstone,
                currentUserID: currentUserID,
                accountEpoch: accountEpoch,
                capturedBy: accountFetch
            ) else { return }
            cacheConfirmServerUpsert(
                recording,
                accountUserID: userID,
                entityType: .recordings,
                entityID: CacheEntityID.recording(recording)
            )
            deletedRecordings.removeAll { $0.id == recording.id }
            await refreshAll(showSpinner: false)
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            await refreshTagCurvesForRPE(
                keys: [key],
                capturedBy: accountFetch
            )
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
        } catch {
            if accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch) {
                surface(error)
            }
        }
    }

    public func purgeRecording(_ recording: TindeqRecording) async {
        guard let userID = currentUserID else { return }
        _ = cacheMarkDeletedLocal(
            accountUserID: userID,
            entityType: .recordings,
            entityID: CacheEntityID.recording(recording)
        )
        do {
            try await repository.purgeRecording(id: recording.id)
            cacheConfirmServerDelete(
                accountUserID: userID,
                entityType: .recordings,
                entityID: CacheEntityID.recording(recording)
            )
            deletedRecordings.removeAll { $0.id == recording.id }
        } catch {
            // Keep the optimistic tombstone on failure: purge is a terminal
            // intent and the queued delete path already owns retrying it.
            surface(error)
        }
    }

    public func linkRecordings(_ recordings: [TindeqRecording], to session: SendmeterCore.Session) async {
        guard let userID = currentUserID else { return }
        let unlinked = recordings.filter { $0.groupID == nil }
        guard !unlinked.isEmpty else { return }
        await perform {
            let result = try await self.repository.linkRecordingsToSession(
                sessionID: session.id,
                recordingIDs: unlinked.map(\.id)
            )
            if let result {
                // #630: the RPC may have minted the session's group id on
                // the spot (a manually logged session never had one) — stamp
                // recordings AND the session with the returned id, not a
                // guess, so the timeline groups them before the next refetch.
                for recording in unlinked {
                    if let index = self.recordings.firstIndex(where: { $0.id == recording.id }) {
                        self.recordings[index].groupID = result.groupID
                        self.cacheUpsertServer(
                            self.recordings[index],
                            accountUserID: userID,
                            entityType: .recordings,
                            entityID: CacheEntityID.recording(self.recordings[index])
                        )
                    }
                }
                if let index = self.sessions.firstIndex(where: { $0.id == session.id }),
                   self.sessions[index].groupID != result.groupID {
                    var updated = self.sessions[index]
                    updated.groupID = result.groupID
                    self.sessions[index] = updated
                    self.cacheUpsertServer(
                        updated,
                        accountUserID: userID,
                        entityType: .sessions,
                        entityID: CacheEntityID.session(updated)
                    )
                }
            }
            self.toastMessage = "Force recordings linked."
        }
    }

    /// #630: group ticked loose recordings under a NEW Tindeq session,
    /// mirroring the web's `HistoryView.createSessionFromSelection`: RPE 5
    /// default, date from the first recording, note summarizing count + tags,
    /// duration = the recordings' actual span (recomputed transactionally by
    /// the link RPC anyway). Unlike the web — which PATCHes `group_id` onto
    /// every recording and THEN inserts the session, so an insert failure
    /// orphans the whole group — this inserts the session first and routes
    /// the recordings through `link_tindeq_recordings_to_session`, whose
    /// single transaction mints the group id and recomputes duration (#490):
    /// no orphan window. Returns false (and surfaces the error) when the
    /// selection or a write fails, so the view keeps the ticked rows.
    public func createSessionFromRecordings(_ recordings: [TindeqRecording]) async -> Bool {
        guard let userID = currentUserID else { return false }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        guard let plan = SelectionSessionPlanner.plan(
            recordings: recordings,
            phase: settings.currentPhase
        ) else { return false }
        let sessionID = UUID()
        let optimistic = pendingSession(
            id: sessionID,
            draft: plan.draft,
            accountUserID: userID
        )
        let optimisticRevision = cacheUpsertLocal(
            optimistic,
            accountUserID: userID,
            entityType: .sessions,
            entityID: CacheEntityID.session(optimistic)
        )
        pendingSessions[sessionID] = optimistic
        mergeSessions(remote: sessions.filter { !$0.pending })
        var serverInsertedSession: SendmeterCore.Session?
        do {
            let saved = try await repository.insertSession(plan.draft, id: sessionID)
            serverInsertedSession = saved
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return false }
            let result = try await repository.linkRecordingsToSession(
                sessionID: sessionID,
                recordingIDs: plan.recordingIDs
            )
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return false }
            if let result {
                var updated = saved
                updated.groupID = result.groupID
                if let minutes = result.durationMinutes {
                    updated.durationMinutes = minutes
                }
                replaceSession(updated)
                for recordingID in plan.recordingIDs {
                    if let index = recordings.firstIndex(where: { $0.id == recordingID }) {
                        self.recordings[index].groupID = result.groupID
                        cacheUpsertServer(
                            self.recordings[index],
                            accountUserID: userID,
                            entityType: .recordings,
                            entityID: CacheEntityID.recording(self.recordings[index])
                        )
                    }
                }
            } else {
                replaceSession(saved)
            }
            let finalSession = result.map { updated -> SendmeterCore.Session in
                var value = saved
                value.groupID = updated.groupID
                if let minutes = updated.durationMinutes {
                    value.durationMinutes = minutes
                }
                return value
            } ?? saved
            cacheConfirmServerUpsert(
                finalSession,
                accountUserID: userID,
                entityType: .sessions,
                entityID: CacheEntityID.session(finalSession),
                confirmingLocalRevision: optimisticRevision
            )
            pendingSessions.removeValue(forKey: sessionID)
            toastMessage = "Session created from recordings"
            return true
        } catch {
            if accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) {
                if let serverInsertedSession {
                    pendingSessions.removeValue(forKey: sessionID)
                    cacheConfirmServerUpsert(
                        serverInsertedSession,
                        accountUserID: userID,
                        entityType: .sessions,
                        entityID: CacheEntityID.session(serverInsertedSession),
                        confirmingLocalRevision: optimisticRevision
                    )
                    replaceSession(serverInsertedSession)
                } else {
                    pendingSessions.removeValue(forKey: sessionID)
                    mergeSessions(remote: sessions.filter { !$0.pending })
                    cacheConfirmServerDelete(
                        accountUserID: userID,
                        entityType: .sessions,
                        entityID: sessionID.uuidString,
                        confirmingLocalRevision: optimisticRevision
                    )
                }
            }
            surface(error)
            return false
        }
    }

    public func savePreset(_ preset: TindeqPreset, isNew: Bool) async {
        guard let userID = currentUserID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        let previous = presets.first { $0.id == preset.id }
        let optimisticRevision = cacheUpsertLocal(
            preset,
            accountUserID: userID,
            entityType: .presets,
            entityID: CacheEntityID.preset(preset)
        )
        presets.removeAll { $0.id == preset.id }
        presets.insert(preset, at: 0)
        do {
            let saved = try await (isNew
                ? repository.insertPreset(preset)
                : repository.updatePreset(preset))
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            cacheConfirmServerUpsert(
                saved,
                accountUserID: userID,
                entityType: .presets,
                entityID: CacheEntityID.preset(saved),
                confirmingLocalRevision: optimisticRevision
            )
            presets.removeAll { $0.id == saved.id }
            presets.insert(saved, at: 0)
        } catch {
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            presets.removeAll { $0.id == preset.id }
            if let previous {
                cacheConfirmServerUpsert(
                    previous,
                    accountUserID: userID,
                    entityType: .presets,
                    entityID: CacheEntityID.preset(previous),
                    confirmingLocalRevision: optimisticRevision
                )
                presets.insert(previous, at: 0)
            } else {
                cacheConfirmServerDelete(
                    accountUserID: userID,
                    entityType: .presets,
                    entityID: CacheEntityID.preset(preset),
                    confirmingLocalRevision: optimisticRevision
                )
            }
            surface(error)
        }
    }

    public func deletePreset(_ preset: TindeqPreset) async {
        guard let userID = currentUserID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        let previous = presets.first { $0.id == preset.id }
        presets.removeAll { $0.id == preset.id }
        let deleteRevision = cacheMarkDeletedLocal(
            accountUserID: userID,
            entityType: .presets,
            entityID: CacheEntityID.preset(preset)
        )
        do {
            try await repository.deletePreset(id: preset.id)
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            cacheConfirmServerDelete(
                accountUserID: userID,
                entityType: .presets,
                entityID: CacheEntityID.preset(preset),
                confirmingLocalRevision: deleteRevision
            )
        } catch {
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            if let previous {
                cacheConfirmServerUpsert(
                    previous,
                    accountUserID: userID,
                    entityType: .presets,
                    entityID: CacheEntityID.preset(previous),
                    confirmingLocalRevision: deleteRevision
                )
                presets.insert(previous, at: 0)
            } else {
                cacheConfirmServerDelete(
                    accountUserID: userID,
                    entityType: .presets,
                    entityID: CacheEntityID.preset(preset),
                    confirmingLocalRevision: deleteRevision
                )
            }
            surface(error)
        }
    }

    // MARK: Routines

    public func saveRoutine(_ routine: RoutinePreset, isNew: Bool) async {
        guard let userID = currentUserID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        let previous = routines.first { $0.id == routine.id }
        let optimisticRevision = cacheUpsertLocal(
            routine,
            accountUserID: userID,
            entityType: .routinePresets,
            entityID: CacheEntityID.routine(routine)
        )
        routines.removeAll { $0.id == routine.id }
        routines.insert(routine, at: 0)
        do {
            let saved = try await (isNew
                ? repository.insertRoutine(routine)
                : repository.updateRoutine(routine))
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            cacheConfirmServerUpsert(
                saved,
                accountUserID: userID,
                entityType: .routinePresets,
                entityID: CacheEntityID.routine(saved),
                confirmingLocalRevision: optimisticRevision
            )
            routines.removeAll { $0.id == saved.id }
            routines.insert(saved, at: 0)
        } catch {
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            routines.removeAll { $0.id == routine.id }
            if let previous {
                cacheConfirmServerUpsert(
                    previous,
                    accountUserID: userID,
                    entityType: .routinePresets,
                    entityID: CacheEntityID.routine(previous),
                    confirmingLocalRevision: optimisticRevision
                )
                routines.insert(previous, at: 0)
            } else {
                cacheConfirmServerDelete(
                    accountUserID: userID,
                    entityType: .routinePresets,
                    entityID: CacheEntityID.routine(routine),
                    confirmingLocalRevision: optimisticRevision
                )
            }
            surface(error)
        }
    }

    public func deleteRoutine(_ routine: RoutinePreset) async {
        guard let userID = currentUserID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        let previous = routines.first { $0.id == routine.id }
        routines.removeAll { $0.id == routine.id }
        let deleteRevision = cacheMarkDeletedLocal(
            accountUserID: userID,
            entityType: .routinePresets,
            entityID: CacheEntityID.routine(routine)
        )
        do {
            try await repository.deleteRoutine(id: routine.id)
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            cacheConfirmServerDelete(
                accountUserID: userID,
                entityType: .routinePresets,
                entityID: CacheEntityID.routine(routine),
                confirmingLocalRevision: deleteRevision
            )
        } catch {
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            if let previous {
                cacheConfirmServerUpsert(
                    previous,
                    accountUserID: userID,
                    entityType: .routinePresets,
                    entityID: CacheEntityID.routine(previous),
                    confirmingLocalRevision: deleteRevision
                )
                routines.insert(previous, at: 0)
            } else {
                cacheConfirmServerDelete(
                    accountUserID: userID,
                    entityType: .routinePresets,
                    entityID: CacheEntityID.routine(routine),
                    confirmingLocalRevision: deleteRevision
                )
            }
            surface(error)
        }
    }

    // MARK: Health and account

    /// The user-facing sync entry point (Settings' Connect/Sync). With
    /// `requestAuthorization` it also requests HealthKit permission and
    /// records the health-authorized flag that gates the automatic refresh
    /// paths. A manual sync is authoritative (#109: bypasses the post-noon
    /// lock). The start stamp keeps a foreground/appear right after from
    /// re-syncing within the coalescing window.
    public func syncHealth(requestAuthorization: Bool) async {
        guard let userID = currentUserID else { return }
        await perform {
            if requestAuthorization {
                try await self.health.requestAuthorization()
                UserDefaults.standard.set(true, forKey: "sendmeter.native.health-authorized")
            }
            self.lastHealthRefreshStartedAt = ProcessInfo.processInfo.systemUptime
            try await self.computeAndPublishReadiness(userID: userID, trigger: .manual)
            self.toastMessage = "Apple Health synced."
        }
    }

    /// #661: the silent refresh trigger for Dashboard appear and app
    /// foreground (and a manual pull-to-refresh). Runs the recompute ONLY
    /// when the coalescing policy says so. The last reading is always kept on
    /// failure — a throwing query or a successful-but-empty read never blanks
    /// a scored today row and never fabricates a score (see
    /// `ReadinessSyncPolicy`). A failure is swallowed, not surfaced: this is
    /// a background-quality refresh (web `runForegroundSync` parity), so a
    /// HealthKit hiccup must not throw an error banner over the last reading.
    /// `.manual` maps to the authoritative #109 trigger and so may surface the
    /// honest empty state; appear/foreground/background are automatic.
    public func silentHealthRefresh(trigger: HealthRefreshTrigger) async {
        guard UserDefaults.standard.bool(forKey: "sendmeter.native.health-authorized") else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard healthRefreshPolicy.shouldRefresh(
            trigger: trigger,
            lastStartedAt: lastHealthRefreshStartedAt,
            now: now
        ) else { return }
        guard let userID = currentUserID else { return }
        lastHealthRefreshStartedAt = now
        do {
            try await computeAndPublishReadiness(userID: userID, trigger: trigger.syncTrigger)
        } catch {
            // Silent: keep the last reading on failure.
        }
    }

    /// A background HealthKit observer fire. Same path as foreground sync:
    /// recompute via RecoveryEngine, upsert `health_metrics`, relay to the
    /// watch. Single-flight with the other triggers — a fire during a
    /// foreground sync coalesces into at most one follow-up instead of
    /// double-computing.
    private func handleHealthBackgroundUpdate() async {
        guard let userID = currentUserID else { return }
        await perform {
            try await self.computeAndPublishReadiness(userID: userID, trigger: .automatic)
        }
    }

    /// The one recompute path, owned by `ReadinessRecomputeGate`: exactly one
    /// pass runs at a time and a concurrent trigger (foreground or
    /// background) coalesces into at most one follow-up. The gate is entered
    /// before the first await so two fires cannot both start a compute.
    ///
    /// Per-pass (mirrors the shipped plugin's `performPass`):
    /// - ACWR is read from the SERVER (`fetchSessionLoads`), never the
    ///   in-memory `sessions` — a cold-launch appear must not compute against
    ///   an empty session list (a fabricated score up to 20 points high,
    ///   #661 F2). An ACWR fetch failure fails the whole pass (last reading
    ///   kept), rather than scoring with a missing load penalty.
    /// - `ReadinessWritePolicy` (#109) decides whether an automatic trigger
    ///   may overwrite today's score (frozen morning score after noon).
    /// - `ReadinessSyncPolicy` decides what to relay vs upsert (never a
    ///   blanked score, never a stamped `computed_at` over a kept row).
    private func computeAndPublishReadiness(userID: UUID, trigger: SyncTrigger) async throws {
        guard recomputeGate.request() == .start else { return }
        do {
            while true {
                let now = Date()
                // Fail-open (plugin parity): a fetch blip means "not yet
                // locked", i.e. an automatic sync may still overwrite.
                let existing = try? await repository.fetchTodayHealthMetric()
                let allowOverwrite = ReadinessWritePolicy.shouldOverwriteReadiness(
                    existingReadiness: existing?.readiness,
                    existingRowDate: existing?.date,
                    now: now,
                    trigger: trigger
                )
                let acwr = try await serverACWRRatio()
                let fresh = try await health.computeTodayMetric(acwr: acwr)
                let plan = ReadinessSyncPolicy.plan(
                    existingToday: existing,
                    freshlyComputed: fresh,
                    allowReadinessOverwrite: allowOverwrite
                )
                let previousToday = healthMetrics.first { $0.date == fresh.date }
                let optimisticRevision = cacheUpsertLocal(
                    plan.relayMetric,
                    accountUserID: userID,
                    entityType: .healthMetrics,
                    entityID: CacheEntityID.healthMetric(plan.relayMetric)
                )
                do {
                    try await repository.upsertHealthMetric(plan.upsertMetric, userID: userID)
                } catch {
                    if let previousToday {
                        cacheConfirmServerUpsert(
                            previousToday,
                            accountUserID: userID,
                            entityType: .healthMetrics,
                            entityID: CacheEntityID.healthMetric(previousToday),
                            confirmingLocalRevision: optimisticRevision
                        )
                    } else {
                        cacheConfirmServerDelete(
                            accountUserID: userID,
                            entityType: .healthMetrics,
                            entityID: CacheEntityID.healthMetric(plan.relayMetric),
                            confirmingLocalRevision: optimisticRevision
                        )
                    }
                    throw error
                }
                cacheConfirmServerUpsert(
                    plan.relayMetric,
                    accountUserID: userID,
                    entityType: .healthMetrics,
                    entityID: CacheEntityID.healthMetric(plan.relayMetric),
                    confirmingLocalRevision: optimisticRevision
                )
                healthMetrics.removeAll { $0.date == fresh.date }
                healthMetrics.insert(plan.relayMetric, at: 0)
                watch.publishReadiness(plan.relayMetric)
                guard recomputeGate.complete() == .rerun else { return }
            }
        } catch {
            recomputeGate.cancel()
            throw error
        }
    }

    /// ACWR ratio from the server's session loads over the EWMA lookback
    /// window (#661 F2) — never from the in-memory `sessions`.
    private func serverACWRRatio() async throws -> Double? {
        let loads = try await repository.fetchSessionLoads()
        var loadByDate: [String: Double] = [:]
        for load in loads { loadByDate[load.date, default: 0] += load.load }
        var dailyLoads: [Double] = []
        dailyLoads.reserveCapacity(TrainingMetrics.ewmaLookbackDays)
        for offset in stride(from: TrainingMetrics.ewmaLookbackDays - 1, through: 0, by: -1) {
            let day = LocalDateSupport.daysAgo(offset)
            dailyLoads.append(loadByDate[day] ?? 0)
        }
        return TrainingMetrics.acwrRatio(dailyLoads: dailyLoads)
    }

    public func deleteAccount() async {
        guard let userID = currentUserID else { return }
        // Invalidate the current account generation before the remote delete so
        // an upload already suspended on this account cannot confirm into the
        // cache after it is purged. Existing upload tasks keep their old
        // `AccountScopedFetch` and will fail the post-await guard, so a purge
        // cannot be re-populated by an in-flight ack.
        let purgeBoundary = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch &+ 1
        )
        accountEpoch = purgeBoundary.accountEpoch
        await perform {
            try await self.repository.deleteAccount()
            try await self.queue?.discardAll(accountUserID: userID, reason: "account-deleted")
            if let cachedWorkspace = self.cachedWorkspace {
                do {
                    try cachedWorkspace.store.deleteAccount(userID)
                } catch {
                    self.recordCacheFailure("cache delete account", error)
                }
            }
            self.pendingCacheWriteCount = 0
            try await self.auth.signOut()
        }
    }

    // MARK: Lost-recording notice + sign-out remainder (#632)

    /// Park the sign-out remainder decision: sets the count the dialog shows
    /// and suspends until `resolveSignOutRemainder` resumes it. Called from
    /// the drain-before-sign-out decision inside `SignOutQueuePolicy`, only
    /// when the drain actually left something behind.
    private func askAboutSignOutRemainder(count: Int) async -> SignOutRemainderChoice {
        signOutRemainderCount = count
        return await withCheckedContinuation { continuation in
            signOutRemainderContinuation = continuation
        }
    }

    /// The dialog's answer. `cancel` aborts the sign-out (session stays up,
    /// queue untouched); `signOut` proceeds, keeping the remainder on device
    /// for this account's next sign-in.
    public func resolveSignOutRemainder(_ choice: SignOutRemainderChoice) {
        guard signOutRemainderContinuation != nil else { return }
        signOutRemainderCount = nil
        signOutRemainderContinuation?.resume(returning: choice)
        signOutRemainderContinuation = nil
    }

    /// #632: the other side of the queue — the durable one-shot notice parked
    /// when a save could not be persisted at all (`LostRecordingStore.note`,
    /// the #264 "out loud" half, native edition). The path that loses a rep
    /// has no way to say so at that moment, so this is where the user finally
    /// hears about it: on the next launch/foreground, mirroring the web's
    /// `takeLostRecordingsNotice` effect in App.tsx. `take` clears the
    /// record, so it shows exactly once.
    private func surfaceLostRecordingNoticeIfAny() {
        guard let notice = LostRecordingStore.take(in: .standard) else { return }
        // #632 review: cause-free on purpose — the native failures that lose
        // a rep are queue-unavailable or a refused persist write, not
        // necessarily a full disk, so claiming a cause ("device storage was
        // full", the web's copy) would be a guess.
        let label = "\(notice.count) item\(notice.count == 1 ? "" : "s")"
        toastMessage = "\(label) couldn\u{2019}t be saved."
    }
    // MARK: Offline queue

    public func drainQueue() async {
        guard let userID = currentUserID, let queue else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        guard await migrateLegacyRecordingEdits(
            userID: userID,
            capturedBy: accountFetch
        ) != nil,
              accountFetch.canApply(
                  to: currentUserID,
                  accountEpoch: accountEpoch
              ) else { return }
        let due = await queue.items(for: userID, dueAt: Date())
        for item in due {
            _ = await upload(item, capturedBy: accountFetch)
        }
        await refreshQueueCount(for: accountFetch)
    }

    public func retryAllQueuedWrites() async {
        guard let userID = currentUserID, let queue else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        guard await migrateLegacyRecordingEdits(
            userID: userID,
            capturedBy: accountFetch
        ) != nil,
              accountFetch.canApply(
                  to: currentUserID,
                  accountEpoch: accountEpoch
              ) else { return }
        let pending = await queue.items(for: userID)
        for item in pending {
            _ = await upload(item, mode: .manual, capturedBy: accountFetch)
        }
        await refreshQueueCount(for: accountFetch)
    }

    /// The BGTask body: drain the durable queue, then reconcile every cache
    /// entity through its cursor delta. Account scope and cancellation are
    /// re-checked after each await by `BackgroundSyncEngine`, so an account
    /// switch or sign-out while the task is suspended cannot write into the
    /// wrong account or advance a cursor after partial work.
    public func runBackgroundSync() async -> BackgroundSyncOutcome {
        guard let userID = currentUserID else { return .accountChanged }
        guard let workspace = cachedWorkspace else {
            await drainQueue()
            return .failed
        }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        let run = BackgroundSyncRun(
            accountUserID: userID,
            accountEpoch: accountEpoch,
            isCurrent: { [weak self] userID, epoch in
                guard let self else { return false }
                return accountFetch.canApply(
                    to: self.currentUserID,
                    accountEpoch: self.accountEpoch
                )
            },
            drain: { [weak self] in
                await self?.drainQueue()
            },
            operations: makeBackgroundSyncOperations(
                accountUserID: userID,
                workspace: workspace
            )
        )
        let outcome = await BackgroundSyncEngine.run(run)
        if case .completed = outcome {
            publishBackgroundSyncSnapshot(
                accountUserID: userID,
                capturedBy: accountFetch
            )
        }
        return outcome
    }

    private func makeBackgroundSyncOperations(
        accountUserID: UUID,
        workspace: CachedWorkspace
    ) -> [BackgroundSyncOperation] {
        let repository = repository
        return [
            makeBackgroundSyncOperation(
                entityType: .sessions,
                accountUserID: accountUserID,
                workspace: workspace,
                fetch: { cursor in
                    try await repository.fetchSessionDelta(
                        since: cursor,
                        accountUserID: accountUserID
                    )
                },
                snapshot: { CachedWorkspaceSnapshot(sessions: $0.activeValues) }
            ),
            makeBackgroundSyncOperation(
                entityType: .settings,
                accountUserID: accountUserID,
                workspace: workspace,
                fetch: { cursor in
                    try await repository.fetchSettingsDelta(since: cursor)
                },
                snapshot: { CachedWorkspaceSnapshot(settings: $0.activeValues.first) }
            ),
            makeBackgroundSyncOperation(
                entityType: .phasePeriods,
                accountUserID: accountUserID,
                workspace: workspace,
                fetch: { cursor in
                    try await repository.fetchPhasePeriodDelta(since: cursor)
                },
                snapshot: { CachedWorkspaceSnapshot(phasePeriods: $0.activeValues) }
            ),
            makeBackgroundSyncOperation(
                entityType: .healthMetrics,
                accountUserID: accountUserID,
                workspace: workspace,
                fetch: { cursor in
                    try await repository.fetchHealthMetricDelta(since: cursor)
                },
                snapshot: { CachedWorkspaceSnapshot(healthMetrics: $0.activeValues) }
            ),
            makeBackgroundSyncOperation(
                entityType: .recordings,
                accountUserID: accountUserID,
                workspace: workspace,
                fetch: { cursor in
                    try await repository.fetchRecordingDelta(since: cursor)
                },
                snapshot: { CachedWorkspaceSnapshot(recordings: $0.activeValues) }
            ),
            makeBackgroundSyncOperation(
                entityType: .presets,
                accountUserID: accountUserID,
                workspace: workspace,
                fetch: { cursor in
                    try await repository.fetchPresetDelta(since: cursor)
                },
                snapshot: { CachedWorkspaceSnapshot(presets: $0.activeValues) }
            ),
            makeBackgroundSyncOperation(
                entityType: .routinePresets,
                accountUserID: accountUserID,
                workspace: workspace,
                fetch: { cursor in
                    try await repository.fetchRoutineDelta(since: cursor)
                },
                snapshot: { CachedWorkspaceSnapshot(routines: $0.activeValues) }
            ),
            makeBackgroundSyncOperation(
                entityType: .workoutsAndAttempts,
                accountUserID: accountUserID,
                workspace: workspace,
                fetch: { cursor in
                    try await repository.fetchWorkoutDelta(since: cursor)
                },
                snapshot: { CachedWorkspaceSnapshot(workouts: $0.activeValues) }
            ),
            makeBackgroundSyncOperation(
                entityType: .tagMetadata,
                accountUserID: accountUserID,
                workspace: workspace,
                fetch: { cursor in
                    try await repository.fetchTagMetadataDelta(since: cursor)
                },
                snapshot: { CachedWorkspaceSnapshot(tagMetadata: $0.activeValues) }
            )
        ]
    }

    private func makeBackgroundSyncOperation<Value: Encodable & Sendable>(
        entityType: LocalCacheEntityType,
        accountUserID: UUID,
        workspace: CachedWorkspace,
        fetch: @escaping @MainActor @Sendable (String?) async throws -> RemoteEntityDelta<Value>,
        snapshot: @escaping @MainActor @Sendable (RemoteEntityDelta<Value>) -> CachedWorkspaceSnapshot
    ) -> BackgroundSyncOperation {
        BackgroundSyncOperation(entityType: entityType) {
            let cursor = try workspace.cursor(
                accountUserID: accountUserID,
                entityType: entityType
            )
            let delta = try await fetch(cursor)
            let firstSnapshot = cursor == nil ? snapshot(delta) : nil
            return BackgroundSyncPreparedOperation {
                if firstSnapshot != nil {
                    try workspace.reconcileServerDelta(
                        delta,
                        accountUserID: accountUserID,
                        entityType: entityType
                    )
                } else {
                    try workspace.reconcileDelta(
                        delta,
                        accountUserID: accountUserID,
                        entityType: entityType
                    )
                }
            }
        }
    }

    private func publishBackgroundSyncSnapshot(
        accountUserID: UUID,
        capturedBy accountFetch: AccountScopedFetch
    ) {
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return }
        guard let workspace = cachedWorkspace else { return }
        do {
            let snapshot = try workspace.load(accountUserID: accountUserID)
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            applyCachedNonOverlayLists(accountUserID: accountUserID)
            mergeSessions(remote: snapshot.sessions)
            mergeRecordings(remote: snapshot.recordings)
            forceModel.hasLoadedRecordings = true
            warmTagCurvesIfMissing(capturedBy: accountFetch)
        } catch {
            recordCacheFailure("background cache publish", error)
        }
    }

    @discardableResult
    private func enqueueAndUpload(
        _ item: DurableQueueItem<PendingWrite>,
        startUpload: Bool = true,
        capturedBy: AccountScopedFetch? = nil
    ) async -> Bool {
        await enqueueAndUpload(
            [item],
            startUpload: startUpload,
            capturedBy: capturedBy
        )
    }

    @discardableResult
    private func enqueueAndUpload(
        _ items: [DurableQueueItem<PendingWrite>],
        startUpload: Bool = true,
        capturedBy: AccountScopedFetch? = nil
    ) async -> Bool {
        guard let userID = currentUserID,
              let firstItem = items.first,
              items.allSatisfy({ $0.accountUserID == firstItem.accountUserID }),
              userID == firstItem.accountUserID else {
            return false
        }
        let accountFetch = capturedBy ?? AccountScopedFetch(
            accountUserID: firstItem.accountUserID,
            accountEpoch: accountEpoch
        )
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return false }
        guard let queue else {
            if accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch) {
                surface(NSError(
                    domain: "SendmeterNative",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "On-device queue is unavailable."]
                ))
            }
            return false
        }
        guard await migrateLegacyRecordingEdits(
            userID: userID,
            capturedBy: accountFetch
        ) != nil else {
            return false
        }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return false }
        let editorRecordingIDs = Set(items.compactMap { sourceRecordingID(for: $0.payload) })
        let editorTerminalKey = editorRecordingIDs.count == 1
            && items.allSatisfy { $0.terminalKey == editorRecordingIDs.first }
            ? editorRecordingIDs.first
            : nil
        if let editorTerminalKey,
           recordingEditCoordinator.isDeleted(editorTerminalKey) {
            return false
        }
        do {
            var editorBatchAccepted = true
            if let editorTerminalKey {
                editorBatchAccepted = try await queue.enqueueUnlessTerminalizedKeepingNewest(
                    items,
                    terminalKey: editorTerminalKey,
                    accountUserID: userID
                )
            } else {
                try await queue.enqueue(items)
            }
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return true }
            guard editorBatchAccepted else { return false }
            await refreshQueueCount(for: accountFetch)
            if startUpload {
                for item in items {
                    Task { [weak self] in
                        _ = await self?.upload(item, capturedBy: accountFetch)
                    }
                }
            }
            return true
        } catch {
            if accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch) {
                surface(error)
            }
            await refreshQueueCount(for: accountFetch)
            return false
        }
    }

    /// #675 N1: the classification + diagnostic an upload failure recorded,
    /// so `retryQuarantinedWrites` can decide whether a fresh failure replaces
    /// the prior rejection stamp or the prior stamp is restored verbatim.
    private struct UploadFailure {
        let classification: RejectionClass
        let code: String?
        let detail: String
    }

    private struct UploadResult {
        let uploaded: Bool
        let failure: UploadFailure?

        init(uploaded: Bool, failure: UploadFailure?) {
            self.uploaded = uploaded
            self.failure = failure
        }
    }

    private func sourceRecordingID(for payload: PendingWrite) -> UUID? {
        switch payload {
        case let .recordingEdit(edit), let .sessionRPEEdit(edit):
            return edit.recordingID
        case let .recordingDelete(delete):
            return delete.recordingID
        default:
            return nil
        }
    }

    /// Normalize every pre-follow-up combined recording edit before any queue
    /// snapshot is replayed. The durable metadata item keeps its recording
    /// identity, while exactly one stable session identity carries the
    /// authoritative RPE for each linked session.
    ///
    /// This is deliberately a queue migration rather than a per-item upload
    /// side effect. If the newer shared item has already uploaded and been
    /// removed, an older combined item cannot recreate its stale RPE on the
    /// next relaunch: every combined item was stripped to metadata before the
    /// shared item was allowed to leave the queue.
    private func migrateLegacyRecordingEdits(
        userID: UUID,
        capturedBy capturedAccountFetch: AccountScopedFetch? = nil
    ) async -> [DurableQueueItem<PendingWrite>]? {
        guard queue != nil else { return [] }
        let accountFetch = capturedAccountFetch ?? AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return nil }

        while true {
            if let flight = legacyMigrationFlights[userID] {
                let result = await flight.task.value
                if legacyMigrationFlights[userID]?.id == flight.id {
                    legacyMigrationFlights.removeValue(forKey: userID)
                }
                guard accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else { return nil }
                // A flight captured an earlier A epoch and may have returned
                // a snapshot that was valid only before B. A later A call
                // must get a fresh migration flight, even though the UUID is
                // the same.
                if flight.accountFetch != accountFetch {
                    continue
                }
                return result
            }

            let flightID = UUID()
            let task: Task<[DurableQueueItem<PendingWrite>]?, Never> = Task { [weak self] in
                guard let self else { return nil }
                return await self.performLegacyRecordingEditMigration(
                    userID: userID,
                    capturedBy: accountFetch
                )
            }
            legacyMigrationFlights[userID] = LegacyRecordingEditMigrationFlight(
                id: flightID,
                accountFetch: accountFetch,
                task: task
            )
            let result = await task.value
            if legacyMigrationFlights[userID]?.id == flightID {
                legacyMigrationFlights.removeValue(forKey: userID)
            }
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return nil }
            return result
        }
    }

    private func performLegacyRecordingEditMigration(
        userID: UUID,
        capturedBy accountFetch: AccountScopedFetch
    ) async -> [DurableQueueItem<PendingWrite>]? {
        guard let queue,
              accountFetch.canApply(
                  to: currentUserID,
                  accountEpoch: accountEpoch
              ) else { return nil }
        let queued = await queue.items(for: userID, includeQuarantined: true)
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return nil }

        var currentByID: [UUID: DurableQueueItem<PendingWrite>] = [:]
        var legacyItems: [(item: DurableQueueItem<PendingWrite>, edit: RecordingEdit)] = []
        var candidatesBySession: [UUID: [RecordingEditQueueCandidate]] = [:]
        for item in queued {
            currentByID[item.id] = item
            switch item.payload {
            case let .recordingEdit(edit):
                guard let sessionID = edit.sessionID, edit.sessionRPE != nil else {
                    continue
                }
                legacyItems.append((item, edit))
                candidatesBySession[sessionID, default: []].append(
                    RecordingEditQueueCandidate(
                        edit: edit,
                        queueItemID: item.id,
                        createdAt: item.createdAt,
                        nextAttemptAt: item.nextAttemptAt
                    )
                )
            case let .sessionRPEEdit(edit):
                guard let sessionID = edit.sessionID, edit.sessionRPE != nil else {
                    continue
                }
                candidatesBySession[sessionID, default: []].append(
                    RecordingEditQueueCandidate(
                        edit: edit,
                        queueItemID: item.id,
                        createdAt: item.createdAt,
                        nextAttemptAt: item.nextAttemptAt
                    )
                )
            default:
                continue
            }
        }

        var replacements: [DurableQueueConditionalReplacement<PendingWrite>] = legacyItems.map { entry in
            DurableQueueConditionalReplacement(
                item: entry.item.replacingPayload(
                    .recordingEdit(RecordingEditMigration.metadataOnly(entry.edit)),
                    terminalKey: entry.edit.recordingID
                ),
                expectedRevision: entry.item.revision
            )
        }

        for (sessionID, candidates) in candidatesBySession {
            guard let authoritative = RecordingEditMigration.authoritativeSessionRPE(
                sessionID: sessionID,
                candidates: candidates
            ) else { continue }
            guard let legacy = legacyItems.first(where: {
                $0.item.id == authoritative.queueItemID
            }) else {
                // A stable session item already won. All legacy candidates in
                // this group are still normalized conditionally above.
                continue
            }
            let source = legacy.item
            let stableID = RecordingEditQueueIdentity.sessionRPE(sessionID)
            replacements.append(
                DurableQueueConditionalReplacement(
                    item: DurableQueueItem(
                        id: stableID,
                        accountUserID: userID,
                        createdAt: source.createdAt,
                        orderingKey: authoritative.edit.sessionRPERevision
                            ?? RecordingEditCoordinator.orderingKey(for: source.createdAt),
                        terminalKey: authoritative.edit.recordingID,
                        updatedAt: source.updatedAt,
                        attempts: source.attempts,
                        permanentAttempts: source.permanentAttempts ?? 0,
                        nextAttemptAt: source.nextAttemptAt,
                        lastError: source.lastError,
                        quarantined: source.quarantined,
                        payload: .sessionRPEEdit(authoritative.edit)
                    ),
                    expectedRevision: currentByID[stableID]?.revision
                )
            )
        }

        do {
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return nil }
            _ = try await queue.replaceIfCurrent(replacements)
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return nil }
        } catch {
            if accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch) {
                surface(error)
            }
            return nil
        }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return nil }
        let migrated = await queue.items(for: userID, includeQuarantined: true)
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return nil }
        return migrated
    }

    private func waitForSessionRPEWrites(sessionID: UUID) async {
        guard recordingEditCoordinator.hasActiveSessionRPEWrites(sessionID: sessionID) else {
            return
        }
        await withCheckedContinuation { continuation in
            if recordingEditCoordinator.hasActiveSessionRPEWrites(sessionID: sessionID) {
                sessionRPEWaiters[sessionID, default: []].append(continuation)
            } else {
                continuation.resume()
            }
        }
    }

    private func waitForQueueUpload(_ key: QueueUploadKey) async {
        guard inFlightUploadClaims.isClaimed(key) else { return }
        await withCheckedContinuation { continuation in
            if inFlightUploadClaims.isClaimed(key) {
                queueUploadWaiters[key, default: []].append(continuation)
            } else {
                continuation.resume()
            }
        }
    }

    private func finishSessionRPEWrite(_ token: RecordingEditWriteToken) {
        _ = recordingEditCoordinator.endSessionRPEWrite(token)
        guard !recordingEditCoordinator.hasActiveSessionRPEWrites(
            sessionID: token.sessionID
        ) else { return }
        let waiters = sessionRPEWaiters.removeValue(forKey: token.sessionID) ?? []
        for waiter in waiters { waiter.resume() }
    }

    private func updateSessionRPE(
        edit: RecordingEdit,
        accountUserID: UUID
    ) async throws -> SendmeterCore.Session? {
        guard let sessionID = edit.sessionID,
              let sessionRPE = edit.sessionRPE,
              currentUserID == accountUserID,
              let token = recordingEditCoordinator.beginSessionRPEWrite(
                  recordingID: edit.recordingID,
                  sessionID: sessionID
              ) else {
            return nil
        }
        defer { finishSessionRPEWrite(token) }
        return try await repository.updateSessionRPE(
            id: sessionID,
            rpe: sessionRPE
        )
    }

    @discardableResult
    private func upload(
        _ item: DurableQueueItem<PendingWrite>,
        mode: QueueUploadMode = .automatic,
        capturedBy capturedAccountFetch: AccountScopedFetch? = nil
    ) async -> UploadResult {
        guard let queue else {
            return UploadResult(uploaded: false, failure: nil)
        }
        let accountFetch = capturedAccountFetch ?? AccountScopedFetch(
            accountUserID: item.accountUserID,
            accountEpoch: accountEpoch
        )
        guard accountFetch.accountUserID == item.accountUserID else {
            return UploadResult(uploaded: false, failure: nil)
        }
        guard accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch) else {
            return UploadResult(uploaded: false, failure: nil)
        }
        guard await migrateLegacyRecordingEdits(
            userID: item.accountUserID,
            capturedBy: accountFetch
        ) != nil else {
            return UploadResult(uploaded: false, failure: nil)
        }
        let uploadKey = QueueUploadKey(
            itemID: item.id,
            accountUserID: item.accountUserID
        )
        guard let uploadClaim = inFlightUploadClaims.claim(uploadKey) else {
            // A second producer may have captured the same queue item before
            // the first producer finished. It must not replay that snapshot.
            return UploadResult(uploaded: false, failure: nil)
        }
        let claimedItemID = item.id
        let claimedAccountUserID = item.accountUserID
        let claimedRevision = item.revision
        defer {
            inFlightUploadClaims.release(uploadClaim)
            if !inFlightUploadClaims.isClaimed(uploadKey) {
                let waiters = queueUploadWaiters.removeValue(forKey: uploadKey) ?? []
                for waiter in waiters { waiter.resume() }
            }
            // Every return path, including an old request's failure or a
            // delete/account guard, must drain a replacement that arrived
            // while this claim was held. Read it after releasing the claim so
            // the replacement can acquire the same single-flight key.
            Task { [weak self] in
                guard let self, let queue = self.queue,
                      let replacement = await queue.item(
                          id: claimedItemID,
                          accountUserID: claimedAccountUserID
                      ), replacement.revision != claimedRevision else { return }
                _ = await self.upload(replacement, capturedBy: accountFetch)
            }
        }

        // Queue reads are snapshots. Re-read through the active queue filter
        // after claiming the item so an automatic producer cannot upload an
        // item that another producer quarantined while this snapshot was
        // suspended. Manual retries are allowed to bypass ordinary backoff,
        // but never the non-quarantined filter.
        guard let currentItem = await queue.activeItem(
            id: item.id,
            accountUserID: item.accountUserID,
            dueAt: mode.revalidationDueAt(now: Date())
        ), accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch) else {
            return UploadResult(uploaded: false, failure: nil)
        }
        var item = currentItem
        // Capture the local revisions before the switch's first network await.
        // The cache row is the durable source after a relaunch; a newer local
        // edit made while this request is in flight bumps the row again, so
        // acknowledging with this captured value is what keeps it pending.
        let cacheRevisions = cacheConfirmationRevisions(
            for: item.payload,
            accountUserID: item.accountUserID
        )
        let isTerminalDelete: Bool = if case .recordingDelete = item.payload {
            true
        } else {
            false
        }
        if !isTerminalDelete,
           let recordingID = sourceRecordingID(for: item.payload),
           recordingEditCoordinator.isDeleted(recordingID) {
            // The terminal delete transaction owns removal of editor items.
            // Do not remove one here: if delete-intent persistence later
            // fails, the delete rolls back and this durable edit must remain.
            return UploadResult(uploaded: false, failure: nil)
        }
        let result: UploadResult
        do {
            var sessionReceipt: SessionLogReceipt?
            var savedSession: SendmeterCore.Session?
            var finishedSessionInsertID: UUID?
            var completedDeleteReceipt: SessionLogReceipt?
            var suppressSavedToast = false
            switch item.payload {
            case let .session(payload):
                finishedSessionInsertID = payload.id
                let receipt = SessionLogReceipt(
                    sessionID: payload.id,
                    accountUserID: item.accountUserID
                )
                sessionReceipt = receipt
                suppressSavedToast = payload.draft.type == "routine"
                if routineUndo.isClaimed(receipt) {
                    pendingSessions.removeValue(forKey: payload.id)
                } else {
                    let saved = try await self.repository.insertSession(
                        payload.draft,
                        id: payload.id,
                        rpeConfirmed: payload.rpeConfirmed,
                        groupID: payload.groupID
                    )
                    guard accountFetch.canApply(
                        to: currentUserID,
                        accountEpoch: accountEpoch
                    ) else {
                        // The request belonged to the original account. Do
                        // not merge its result into a newly signed-in one;
                        // leave the durable item for that account to reconcile.
                        return UploadResult(uploaded: false, failure: nil)
                    }
                    if routineUndo.isClaimed(receipt) {
                        // Undo may have claimed the receipt while the insert
                        // was in flight. The separate durable delete intent
                        // owns the soft-delete retry; do not let this insert
                        // result surface as a saved row.
                        suppressSavedToast = true
                        pendingSessions.removeValue(forKey: payload.id)
                    } else {
                        pendingSessions.removeValue(forKey: payload.id)
                        replaceSession(saved)
                        savedSession = saved
                    }
                }
                if let savedSession {
                    cacheConfirmServerUpsert(
                        savedSession,
                        accountUserID: item.accountUserID,
                        entityType: .sessions,
                        entityID: CacheEntityID.session(savedSession),
                        confirmingLocalRevision: cacheConfirmationRevision(
                            cacheRevisions,
                            entityType: .sessions,
                            entityID: savedSession.id.uuidString
                        )
                    )
                }
            case let .sessionDelete(deletePayload):
                suppressSavedToast = true
                // A delete intent can be created while the matching insert is
                // awaiting the server. The queue entry is the durable
                // dependency: leave the delete due until that insert has
                // either completed (and left the queue) or been skipped
                // because Undo claimed it. Soft-deleting first is a no-op on
                // many backends and would let the later insert resurrect the
                // exact row Undo removed.
                let queuedForDelete = await queue.items(
                    for: item.accountUserID,
                    includeQuarantined: true
                )
                guard accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else {
                    return UploadResult(uploaded: false, failure: nil)
                }
                let hasPendingInsert = queuedForDelete.contains { queued in
                    guard queued.id != item.id else { return false }
                    switch queued.payload {
                    case let .session(insertPayload):
                        return insertPayload.id == deletePayload.sessionID
                    default:
                        return false
                    }
                }
                guard !hasPendingInsert else {
                    return UploadResult(uploaded: false, failure: nil)
                }
                let receipt = SessionLogReceipt(
                    sessionID: deletePayload.sessionID,
                    accountUserID: item.accountUserID
                )
                try await self.repository.softDeleteSession(id: deletePayload.sessionID)
                guard accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else {
                    // The request belonged to the original account. Leave
                    // the durable intent for that account to reconcile rather
                    // than allowing a new account's UI to acknowledge it.
                    return UploadResult(uploaded: false, failure: nil)
                }
                completedDeleteReceipt = receipt
                cacheConfirmServerDelete(
                    accountUserID: item.accountUserID,
                    entityType: .sessions,
                    entityID: deletePayload.sessionID.uuidString,
                    confirmingLocalRevision: cacheConfirmationRevision(
                        cacheRevisions,
                        entityType: .sessions,
                        entityID: deletePayload.sessionID.uuidString
                    )
                )
            case let .recording(recording):
                let saved = try await self.repository.insertRecording(recording)
                let oldKey = TagCurveKey(
                    tag: recording.tag,
                    modality: GaugeSessionRPE.modality(
                        of: self.pendingRecording(from: recording)
                    )
                )
                let publishedRecording = accountFetch.publishIfCurrent(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) {
                    removePendingRecording(
                        for: recording.id,
                        accountUserID: item.accountUserID
                    )
                    replaceRecording(saved)
                    cacheConfirmServerUpsert(
                        saved,
                        accountUserID: item.accountUserID,
                        entityType: .recordings,
                        entityID: CacheEntityID.recording(saved),
                        confirmingLocalRevision: cacheConfirmationRevision(
                            cacheRevisions,
                            entityType: .recordings,
                            entityID: saved.id.uuidString
                        )
                    )
                }
                guard publishedRecording else {
                    return UploadResult(uploaded: false, failure: nil)
                }
                let newKey = TagCurveKey(
                    tag: saved.tag,
                    modality: GaugeSessionRPE.modality(of: saved)
                )
                // The queue's network completion is another input boundary:
                // an equal server row still replaces the optimistic fit, and
                // a normalized/different row touches both old and new keys.
                let affectedKeys = TagCurveCachePolicy.affectedKeys(
                    old: oldKey,
                    new: newKey
                )
                await refreshTagCurvesForRPE(
                    keys: affectedKeys,
                    capturedBy: accountFetch
                )
                if accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) {
                    removePendingCurveSamples(for: recording.id)
                }
            case let .recordingEdit(edit):
                let savedRecording = try await self.repository.updateRecordingMeta(
                    id: edit.recordingID,
                    payload: edit.recordingPayload
                )
                guard accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else {
                    // Leave the durable edit for its owning account. No
                    // response from the old account may enter the new user's
                    // in-memory History list.
                    return UploadResult(uploaded: false, failure: nil)
                }
                if recordingEditCoordinator.isDeleted(edit.recordingID) {
                    // Leave removal to the atomic terminal-delete
                    // transaction so a failed delete persist cannot lose the
                    // edit that the optimistic rollback needs.
                    return UploadResult(uploaded: false, failure: nil)
                }
                // A newer edit may have been queued while this request was
                // suspended. Only clear/apply this edit's optimistic overlay
                // when it is still current; the newer payload remains the
                // source of truth for the next upload.
                let currentQueueRevision = await queue.item(
                    id: item.id,
                    accountUserID: item.accountUserID
                )?.revision
                guard accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else {
                    return UploadResult(uploaded: false, failure: nil)
                }
                let pendingEdit = pendingRecordingEdits[edit.recordingID]
                let metadataIsCurrent = pendingEdit?.tag == edit.tag
                    && pendingEdit?.side == edit.side
                    && pendingEdit?.note == edit.note
                if RecordingEditRacePolicy.acceptsRecordingResponse(
                    recordingID: edit.recordingID,
                    responseRevision: item.revision,
                    currentRevision: currentQueueRevision,
                    deleted: recordingEditCoordinator.isDeleted(edit.recordingID)
                ) && metadataIsCurrent {
                    pendingRecordingEdits.removeValue(forKey: edit.recordingID)
                    replaceRecording(savedRecording)
                    cacheConfirmServerUpsert(
                        savedRecording,
                        accountUserID: item.accountUserID,
                        entityType: .recordings,
                        entityID: CacheEntityID.recording(savedRecording),
                        confirmingLocalRevision: cacheConfirmationRevision(
                            cacheRevisions,
                            entityType: .recordings,
                            entityID: savedRecording.id.uuidString
                        )
                    )
                }
            case let .sessionRPEEdit(edit):
                guard let sessionID = edit.sessionID,
                      edit.sessionRPE != nil else {
                    return UploadResult(uploaded: false, failure: nil)
                }
                guard let savedSession = try await updateSessionRPE(
                    edit: edit,
                    accountUserID: item.accountUserID
                ) else {
                    // A delete barrier owns this session lane. Leave the
                    // durable item for the post-delete drain; a recording
                    // tombstone is handled by the common stale-item guard.
                    return UploadResult(uploaded: false, failure: nil)
                }
                guard accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else {
                    return UploadResult(uploaded: false, failure: nil)
                }
                if recordingEditCoordinator.isDeleted(edit.recordingID) {
                    // See the metadata-edit branch: a tombstone alone is not
                    // durable cancellation. The delete transaction removes
                    // this item only after its own intent is persisted.
                    return UploadResult(uploaded: false, failure: nil)
                }
                let currentQueueRevision = await queue.item(
                    id: item.id,
                    accountUserID: item.accountUserID
                )?.revision
                guard accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else {
                    return UploadResult(uploaded: false, failure: nil)
                }
                if RecordingEditRacePolicy.acceptsSessionRPEResponse(
                    responseRevision: item.revision,
                    currentRevision: currentQueueRevision,
                    deleted: recordingEditCoordinator.isDeleted(edit.recordingID)
                ), pendingSessionRPEEdits[sessionID] == edit {
                    pendingSessionRPEEdits.removeValue(forKey: sessionID)
                    pendingSessionRPEBases.removeValue(forKey: sessionID)
                    replaceSession(savedSession)
                    cacheConfirmServerUpsert(
                        savedSession,
                        accountUserID: item.accountUserID,
                        entityType: .sessions,
                        entityID: CacheEntityID.session(savedSession),
                        confirmingLocalRevision: cacheConfirmationRevision(
                            cacheRevisions,
                            entityType: .sessions,
                            entityID: savedSession.id.uuidString
                        )
                    )
                }
            case let .recordingDelete(delete):
                suppressSavedToast = true
                guard recordingEditCoordinator.isDeleted(delete.recordingID),
                      !recordingEditCoordinator.isRestoring(delete.recordingID),
                      accountFetch.canApply(
                          to: currentUserID,
                          accountEpoch: accountEpoch
                      ) else {
                    return UploadResult(uploaded: false, failure: nil)
                }
                do {
                    var compensationBarrier: RecordingEditBarrierToken?
                    if let sessionID = delete.sessionID,
                       delete.previousSessionRPE != nil {
                        compensationBarrier = recordingEditCoordinator.beginSessionRPEBarrier(
                            sessionID: sessionID
                        )
                    }
                    defer {
                        if let sessionID = delete.sessionID,
                           let compensationBarrier {
                            _ = recordingEditCoordinator.endSessionRPEBarrier(
                                compensationBarrier
                            )
                            if !recordingEditCoordinator.hasActiveSessionRPEWrites(
                                sessionID: sessionID
                            ) {
                                Task { [weak self] in
                                    await self?.drainSessionRPE(
                                        sessionID: sessionID,
                                        accountUserID: item.accountUserID,
                                        capturedBy: accountFetch
                                    )
                                }
                            }
                        }
                    }
                    if let sessionID = delete.sessionID,
                       let previousRPE = delete.previousSessionRPE {
                        await waitForSessionRPEWrites(sessionID: sessionID)
                        guard accountFetch.canApply(
                            to: currentUserID,
                            accountEpoch: accountEpoch
                        ), recordingEditCoordinator.isDeleted(delete.recordingID) else {
                            return UploadResult(uploaded: false, failure: nil)
                        }
                        guard try await queue.protectOrderingIdentity(
                            queueItemID: RecordingEditQueueIdentity.sessionRPE(sessionID),
                            accountUserID: item.accountUserID,
                            terminalKey: delete.recordingID,
                            terminalItemID: item.id
                        ) else {
                            throw NSError(
                                domain: "SendmeterNative",
                                code: 11,
                                userInfo: [NSLocalizedDescriptionKey: "Recording delete ordering proof was not durable."]
                            )
                        }
                        guard accountFetch.canApply(
                            to: currentUserID,
                            accountEpoch: accountEpoch
                        ), recordingEditCoordinator.isDeleted(delete.recordingID) else {
                            return UploadResult(uploaded: false, failure: nil)
                        }
                        let currentRPEClaim = await queue.item(
                            id: RecordingEditQueueIdentity.sessionRPE(sessionID),
                            accountUserID: item.accountUserID
                        )
                        guard accountFetch.canApply(
                            to: currentUserID,
                            accountEpoch: accountEpoch
                        ), recordingEditCoordinator.isDeleted(delete.recordingID) else {
                            return UploadResult(uploaded: false, failure: nil)
                        }
                        let rpeWatermark = await queue.orderingWatermark(
                            for: RecordingEditQueueIdentity.sessionRPE(sessionID),
                            accountUserID: item.accountUserID
                        )
                        guard accountFetch.canApply(
                            to: currentUserID,
                            accountEpoch: accountEpoch
                        ), recordingEditCoordinator.isDeleted(delete.recordingID) else {
                            return UploadResult(uploaded: false, failure: nil)
                        }
                        let compensationState = delete.compensationState ?? .pending
                        let decision = RecordingDeleteCompensationPolicy.decision(
                            state: compensationState,
                            compensationOrderingKey: delete.compensationOrderingKey,
                            currentOrderingKey: currentRPEClaim?.orderingKey,
                            watermarkOrderingKey: rpeWatermark?.orderingKey
                        )
                        switch decision {
                    case .apply:
                        let restoredSession = try await self.repository.updateSessionRPE(
                            id: sessionID,
                            rpe: previousRPE,
                            rpeConfirmed: delete.previousSessionRPEConfirmed ?? true
                        )
                        guard accountFetch.canApply(
                            to: currentUserID,
                            accountEpoch: accountEpoch
                        ), recordingEditCoordinator.isDeleted(delete.recordingID) else {
                            return UploadResult(uploaded: false, failure: nil)
                        }
                        let appliedPayload = RecordingDeleteQueuePayload(
                            recordingID: delete.recordingID,
                            operationID: delete.operationID,
                            sessionID: delete.sessionID,
                            previousSessionRPE: delete.previousSessionRPE,
                            previousSessionRPEConfirmed: delete.previousSessionRPEConfirmed,
                            compensationOrderingKey: delete.compensationOrderingKey,
                            compensationState: .applied
                        )
                        let updatedItem = item.replacingPayload(
                            .recordingDelete(appliedPayload)
                        )
                        guard try await queue.enqueueIfCurrent(
                            updatedItem,
                            expectedRevision: item.revision
                        ) else {
                            throw NSError(
                                domain: "SendmeterNative",
                                code: 8,
                                userInfo: [NSLocalizedDescriptionKey: "Recording delete compensation progress was not durable."]
                            )
                        }
                        guard accountFetch.canApply(
                            to: currentUserID,
                            accountEpoch: accountEpoch
                        ), recordingEditCoordinator.isDeleted(delete.recordingID) else {
                            return UploadResult(uploaded: false, failure: nil)
                        }
                        item = updatedItem
                        _ = accountFetch.publishIfCurrent(
                            to: currentUserID,
                            accountEpoch: accountEpoch
                        ) {
                            replaceSession(restoredSession)
                        }
                        cacheConfirmServerUpsert(
                            restoredSession,
                            accountUserID: item.accountUserID,
                            entityType: .sessions,
                            entityID: CacheEntityID.session(restoredSession),
                            confirmingLocalRevision: cacheConfirmationRevision(
                                cacheRevisions,
                                entityType: .sessions,
                                entityID: restoredSession.id.uuidString
                            )
                        )
                    case .skipAlreadyApplied:
                        break
                    case .skipSuperseded:
                        let supersededPayload = RecordingDeleteQueuePayload(
                            recordingID: delete.recordingID,
                            operationID: delete.operationID,
                            sessionID: delete.sessionID,
                            previousSessionRPE: delete.previousSessionRPE,
                            previousSessionRPEConfirmed: delete.previousSessionRPEConfirmed,
                            compensationOrderingKey: delete.compensationOrderingKey,
                            compensationState: .superseded
                        )
                        let updatedItem = item.replacingPayload(
                            .recordingDelete(supersededPayload)
                        )
                        guard try await queue.enqueueIfCurrent(
                            updatedItem,
                            expectedRevision: item.revision
                        ) else {
                            throw NSError(
                                domain: "SendmeterNative",
                                code: 8,
                                userInfo: [NSLocalizedDescriptionKey: "Recording delete ordering changed while retrying."]
                            )
                        }
                        guard accountFetch.canApply(
                            to: currentUserID,
                            accountEpoch: accountEpoch
                        ), recordingEditCoordinator.isDeleted(delete.recordingID) else {
                            return UploadResult(uploaded: false, failure: nil)
                        }
                        item = updatedItem
                        }
                    try await self.repository.softDeleteRecording(id: delete.recordingID)
                    guard accountFetch.canApply(
                        to: currentUserID,
                        accountEpoch: accountEpoch
                    ), recordingEditCoordinator.isDeleted(delete.recordingID) else {
                        return UploadResult(uploaded: false, failure: nil)
                    }
                    guard try await queue.completeTerminalDelete(
                        id: item.id,
                        accountUserID: item.accountUserID,
                        expectedRevision: item.revision,
                        terminalKey: delete.recordingID,
                        operationID: delete.operationID
                    ) else {
                        throw NSError(
                            domain: "SendmeterNative",
                            code: 5,
                            userInfo: [NSLocalizedDescriptionKey: "Recording delete completion was not durable."]
                        )
                    }
                    cacheConfirmServerDelete(
                        accountUserID: item.accountUserID,
                        entityType: .recordings,
                        entityID: delete.recordingID.uuidString,
                        confirmingLocalRevision: cacheConfirmationRevision(
                            cacheRevisions,
                            entityType: .recordings,
                            entityID: delete.recordingID.uuidString
                        )
                    )
                }
                }
            case let .workout(draft):
                let saved = try await self.repository.insertPhoneWorkout(draft)
                let publishedWorkout = accountFetch.publishIfCurrent(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) {
                    pendingSessions.removeValue(forKey: draft.sessionID)
                    replaceSession(saved)
                    cacheConfirmServerUpsert(
                        saved,
                        accountUserID: item.accountUserID,
                        entityType: .sessions,
                        entityID: CacheEntityID.session(saved),
                        confirmingLocalRevision: cacheConfirmationRevision(
                            cacheRevisions,
                            entityType: .sessions,
                            entityID: saved.id.uuidString
                        )
                    )
                }
                guard publishedWorkout else {
                    return UploadResult(uploaded: false, failure: nil)
                }
            }
            if let sessionReceipt, routineUndo.isClaimed(sessionReceipt) {
                suppressSavedToast = true
            }
            // If a producer replaced this payload while its request was
            // suspended, keep that newer item; removing by id here would
            // otherwise lose it.
            let shouldRemoveUploadedItem = await queue.item(
                id: item.id,
                accountUserID: item.accountUserID
            )?.revision == item.revision
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else {
                return UploadResult(uploaded: false, failure: nil)
            }
            if shouldRemoveUploadedItem {
                do {
                    try await queue.remove(
                        id: item.id,
                        accountUserID: item.accountUserID,
                        reason: "uploaded"
                    )
                } catch let error as DurableQueueError {
                    // Undo may have removed the same queue item while its
                    // upload was in flight. That is already the desired
                    // terminal state.
                    if !(suppressSavedToast && error == .itemNotFound) { throw error }
                }
                guard accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else {
                    return UploadResult(uploaded: false, failure: nil)
                }
            }
            if let finishedSessionInsertID {
                await uploadPendingSessionDelete(
                    sessionID: finishedSessionInsertID,
                    accountUserID: item.accountUserID,
                    accountFetch: accountFetch
                )
                guard accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch) else {
                    return UploadResult(uploaded: false, failure: nil)
                }
            }
            if let completedDeleteReceipt {
                guard accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else {
                    return UploadResult(uploaded: false, failure: nil)
                }
                let publishedDelete = accountFetch.publishIfCurrent(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) {
                    _ = routineUndo.markDeleteCompleted(
                        completedDeleteReceipt,
                        currentUserID: item.accountUserID
                    )
                    sessions.removeAll { $0.id == completedDeleteReceipt.sessionID }
                    mergeSessions(remote: sessions.filter { !$0.pending })
                }
                guard publishedDelete else {
                    return UploadResult(uploaded: false, failure: nil)
                }
            }
            _ = accountFetch.publishIfCurrent(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) {
                if !suppressSavedToast { toastMessage = "Saved" }
            }
            result = UploadResult(uploaded: true, failure: nil)
        } catch {
            if case .recordingDelete = item.payload {
                // A delete intent is terminally durable until both the
                // backend mutation and the terminal marker commit. Keep it in
                // the queue on any failure so relaunch can retry safely.
            } else if let recordingID = sourceRecordingID(for: item.payload),
               recordingEditCoordinator.isDeleted(recordingID) {
                // The tombstone may still be in the pre-persist window. Do
                // not turn a failed delete persistence into lost edit data;
                // the terminal transaction, when durable, removes it.
                result = UploadResult(uploaded: false, failure: nil)
                await refreshQueueCount(for: accountFetch)
                return result
            }
            do {
                // #675: classify the rejection. A permanent one (constraint /
                // malformed / forbidden-with-valid-token) earns the entry a
                // bounded number of attempts and then a quarantine; auth /
                // parked / transient failures keep plain backoff. The
                // classification is the transport's (PostgRESTError
                // conformance), so the actor never parses server errors.
                //
                // #675 F5: a MANUAL retry ("Retry now" in History/Settings,
                // or the per-item quarantine retry) is an explicit user
                // action, not an automatic drain attempt — it must never
                // spend the quarantine budget, so its failures do not count
                // toward the permanent-attempt bound.
                let classification = (error as? ServerRejectionClassifying)?.rejectionClass ?? .retryable
                let code = (error as? PostgRESTError)?.code
                let applied = try await queue.markFailure(
                    id: item.id,
                    accountUserID: item.accountUserID,
                    error: error.localizedDescription,
                    classification: classification,
                    code: code,
                    countsTowardQuarantine: mode.countsTowardQuarantine,
                    expectedRevision: item.revision
                )
                if applied {
                    result = UploadResult(
                        uploaded: false,
                        failure: UploadFailure(
                            classification: classification,
                            code: code,
                            detail: error.localizedDescription
                        )
                    )
                } else {
                    // The queue identity now holds a newer replacement. The
                    // old request must not spend its backoff/quarantine
                    // budget or report its error against that replacement.
                    result = UploadResult(uploaded: false, failure: nil)
                }
            } catch {
                if accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch) {
                    surface(error)
                }
                result = UploadResult(uploaded: false, failure: nil)
            }
        }
        await refreshQueueCount(for: accountFetch)
        return result
    }

    /// Starts a delete that was intentionally held behind a matching session
    /// insert. The delete remains durable if this process goes away before
    /// the follow-up upload completes.
    private func uploadPendingSessionDelete(
        sessionID: UUID,
        accountUserID: UUID,
        accountFetch: AccountScopedFetch
    ) async {
        guard accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch),
              let queue
        else { return }
        let queued = await queue.items(
            for: accountUserID,
            dueAt: Date()
        )
        guard accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch) else {
            return
        }
        guard let deleteItem = queued.first(where: { item in
            guard case let .sessionDelete(payload) = item.payload else { return false }
            return payload.sessionID == sessionID
        }) else { return }
        _ = await upload(deleteItem, capturedBy: accountFetch)
    }

    private func drainSessionRPE(
        sessionID: UUID,
        accountUserID: UUID,
        capturedBy capturedAccountFetch: AccountScopedFetch? = nil
    ) async {
        guard let queue,
              let currentUserID,
              currentUserID == accountUserID else { return }
        let accountFetch = capturedAccountFetch ?? AccountScopedFetch(
            accountUserID: accountUserID,
            accountEpoch: accountEpoch
        )
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return }
        guard let item = await queue.item(
            id: RecordingEditQueueIdentity.sessionRPE(sessionID),
            accountUserID: accountUserID
        ) else { return }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return }
        guard case .sessionRPEEdit(_) = item.payload else { return }
        _ = await upload(item, capturedBy: accountFetch)
    }

    private func recordingEditQueueItems(
        recordingID: UUID,
        sessionID: UUID?,
        accountUserID: UUID
    ) async -> [DurableQueueItem<PendingWrite>] {
        guard let queue else { return [] }
        var ids = [RecordingEditQueueIdentity.recording(recordingID)]
        if let sessionID {
            ids.append(RecordingEditQueueIdentity.sessionRPE(sessionID))
        }
        var items: [DurableQueueItem<PendingWrite>] = []
        for id in ids {
            if let item = await queue.item(id: id, accountUserID: accountUserID) {
                items.append(item)
            }
        }
        // The session may not be in the current in-memory fetch (for
        // example, a relaunch raced the first refresh). Find a durable RPE
        // edit by its recording source as a second, account-scoped lookup.
        let allQueuedItems = await queue.items(for: accountUserID, includeQuarantined: true)
        for item in allQueuedItems
            where sourceRecordingID(for: item.payload) == recordingID
                && !items.contains(where: { $0.id == item.id }) {
            items.append(item)
        }
        return items
    }

    /// #675: the explicit-user-action re-attempt for quarantined entries —
    /// native mirror of the web's `retryStuckRecordings` (#484). With `id` it
    /// retries ONE quarantined entry (the per-item Settings action); without,
    /// all of them. Clears the rejection stamp (fresh bounded-attempt budget)
    /// and uploads immediately; on success the upload removes the entry from
    /// the queue.
    ///
    /// #675 F7: the entry is NOT re-armed onto the hot drain path by a failed
    /// manual retry. The upload runs manual (so its rejection never spends the
    /// quarantine budget — #675 F5), and on ANY failure the quarantine stamp
    /// is immediately re-applied, so the entry goes straight back to its
    /// quarantined, never-auto-retried state instead of getting free
    /// automatic retries behind the user's back.
    ///
    /// #675 N1: a failed manual retry preserves the rejection DIAGNOSTIC. The
    /// prior stamp is passed to `requarantine` as `previous`; a transient /
    /// auth / parked failure on the retry restores it verbatim (code, detail
    /// and `at` all survive), while only a FRESH `.permanent` rejection
    /// replaces the stamp with its own code/detail.
    public func retryQuarantinedWrites(id: UUID? = nil) async {
        guard let userID = currentUserID, let queue else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        guard await migrateLegacyRecordingEdits(
            userID: userID,
            capturedBy: accountFetch
        ) != nil else { return }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return }
        let quarantined = await queue.quarantinedItems(for: userID)
        for item in quarantined where id == nil || item.id == id {
            do {
                guard let previous = try await queue.retryQuarantined(
                    id: item.id,
                    accountUserID: item.accountUserID
                ) else { continue }
                let result = await upload(
                    item,
                    mode: .manual,
                    capturedBy: accountFetch
                )
                if !result.uploaded {
                    // #675 F7 + N1: the manual attempt failed — re-stamp the
                    // quarantine NOW so the entry is never auto-retried by a
                    // later drain (Settings tells the user it is "kept on this
                    // device and never retried on their own"). The stamp is
                    // the PRIOR rejection unless the retry itself was a fresh
                    // permanent rejection; either way the budget stays reset
                    // (0), so the next MANUAL retry starts a clean window.
                    let failure = result.failure
                    try await queue.requarantine(
                        id: item.id,
                        accountUserID: item.accountUserID,
                        previous: previous,
                        classification: failure?.classification ?? .retryable,
                        code: failure?.code,
                        detail: failure?.detail ?? item.lastError ?? "Manual retry failed",
                        now: Date()
                    )
                }
            } catch {
                if accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) {
                    surface(error)
                }
            }
        }
        await refreshQueueCount(for: accountFetch)
    }

    /// #675: discard ONE quarantined entry. Quarantined-only (the Settings
    /// surface's Discard action is never offered for an active entry); the
    /// #273 sign-out and account-deletion paths keep their own removal rules,
    /// so this is the only per-item discard site. Also drops the restored
    /// rejected placeholder from History/Force — a discarded entry is gone,
    /// it must not keep rendering as "Rejected" (#675 F1).
    public func discardQuarantinedWrite(id: UUID) async {
        guard let userID = currentUserID, let queue else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        do {
            let item = await queue.item(id: id, accountUserID: userID)
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            guard try await queue.discardQuarantined(
                id: id,
                accountUserID: userID,
                expectedRevision: item?.revision
            ) else {
                await refreshQueueCount(for: accountFetch)
                guard accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else { return }
                if let item, case .recordingDelete = item.payload {
                    // A concurrent retry or replacement won the revision
                    // check. The selected delete was not discarded, so
                    // refetch both views rather than leaving an optimistic
                    // tombstone/Trash row from the stale snapshot visible.
                    await refreshAll(showSpinner: false)
                    guard accountFetch.canApply(
                        to: currentUserID,
                        accountEpoch: accountEpoch
                    ) else { return }
                    await refreshTrash()
                    guard accountFetch.canApply(
                        to: currentUserID,
                        accountEpoch: accountEpoch
                    ) else { return }
                }
                return
            }
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            if let item {
                if case let .sessionDelete(payload) = item.payload {
                    _ = routineUndo.discardPendingDelete(
                        SessionLogReceipt(
                            sessionID: payload.sessionID,
                            accountUserID: item.accountUserID
                        ),
                        currentUserID: userID
                    )
                    // The remote row may have been hidden by Undo before the
                    // delete was quarantined. Re-fetch so discarding the
                    // durable delete intent restores the truthful server
                    // state immediately.
                    await refreshAll(showSpinner: false)
                    guard accountFetch.canApply(
                        to: currentUserID,
                        accountEpoch: accountEpoch
                    ) else { return }
                    return
                }
                if case let .recordingDelete(payload) = item.payload {
                    let terminalOperation = await queue.terminalizedToken(
                        for: payload.recordingID,
                        accountUserID: userID
                    )
                    guard accountFetch.canApply(
                        to: currentUserID,
                        accountEpoch: accountEpoch
                    ) else { return }
                    let tombstone = recordingEditCoordinator.tombstoneToken(
                        recordingID: payload.recordingID
                    )
                    if RecordingDeleteDiscardPolicy.ownsExactDelete(
                        operationID: payload.operationID,
                        tombstone: tombstone,
                        terminalOperationID: terminalOperation
                    ) {
                        if terminalOperation == payload.operationID {
                            guard try await queue.clearTerminalized(
                                key: payload.recordingID,
                                accountUserID: userID,
                                expectedOperationID: payload.operationID
                            ) else {
                                throw NSError(
                                    domain: "SendmeterNative",
                                    code: 9,
                                    userInfo: [NSLocalizedDescriptionKey: "The recording delete changed before it was discarded."]
                                )
                            }
                            guard accountFetch.canApply(
                                to: currentUserID,
                                accountEpoch: accountEpoch
                            ) else { return }
                        }
                        if let tombstone, tombstone.id == payload.operationID {
                            _ = recordingEditCoordinator.clearDelete(
                                tombstone,
                                currentUserID: currentUserID,
                                accountEpoch: accountEpoch
                            )
                        }
                    }
                    // A quarantined terminal delete has an unknown backend
                    // outcome. Clear only its exact local ownership above,
                    // then refetch both active and trash lists so the UI tells
                    // the truth instead of guessing that discard restored it.
                    await refreshAll(showSpinner: false)
                    guard accountFetch.canApply(
                        to: currentUserID,
                        accountEpoch: accountEpoch
                    ) else { return }
                    await refreshTrash()
                    guard accountFetch.canApply(
                        to: currentUserID,
                        accountEpoch: accountEpoch
                    ) else { return }
                    toastMessage = "Force recording delete discarded; state refreshed."
                    return
                }
                if case let .recordingEdit(edit) = item.payload {
                    if pendingRecordingEdits[edit.recordingID] == edit {
                        pendingRecordingEdits.removeValue(forKey: edit.recordingID)
                    }
                    if let sessionID = edit.sessionID,
                       pendingSessionRPEEdits[sessionID] == edit {
                        pendingSessionRPEEdits.removeValue(forKey: sessionID)
                        if let base = pendingSessionRPEBases.removeValue(forKey: sessionID) {
                            replaceSession(base)
                        }
                    }
                    // The rejected edit may have been visible optimistically;
                    // the server row is authoritative after the user discards
                    // it. A refresh also handles a session RPE overlay.
                    await refreshAll(showSpinner: false)
                    guard accountFetch.canApply(
                        to: currentUserID,
                        accountEpoch: accountEpoch
                    ) else { return }
                    return
                }
                if case let .sessionRPEEdit(edit) = item.payload {
                    if let sessionID = edit.sessionID,
                       pendingSessionRPEEdits[sessionID] == edit {
                        pendingSessionRPEEdits.removeValue(forKey: sessionID)
                        if let base = pendingSessionRPEBases.removeValue(forKey: sessionID) {
                            replaceSession(base)
                        }
                    }
                    await refreshAll(showSpinner: false)
                    guard accountFetch.canApply(
                        to: currentUserID,
                        accountEpoch: accountEpoch
                    ) else { return }
                    return
                }
                let affectedKey: TagCurveKey? = {
                    if let existing = recordings.first(where: { $0.id == id }) {
                        return TagCurveKey(
                            tag: existing.tag,
                            modality: GaugeSessionRPE.modality(of: existing)
                        )
                    }
                    if case let .recording(recording) = item.payload {
                        let pending = pendingRecording(from: recording)
                        return TagCurveKey(
                            tag: pending.tag,
                            modality: GaugeSessionRPE.modality(of: pending)
                        )
                    }
                    return nil
                }()
                pendingSessions.removeValue(forKey: id)
                removePendingRecording(for: id, accountUserID: userID)
                removePendingCurveSamples(for: id)
                sessions.removeAll { $0.id == id }
                let beforeRecordings = recordings
                let beforeCount = recordings.count
                recordings.removeAll { $0.id == id }
                publishForceProgressRecordingMutationIfNeeded(
                    before: beforeRecordings,
                    after: recordings
                )
                let keys = affectedKey.map { Set([$0]) } ?? Set<TagCurveKey>()
                if recordings.count != beforeCount || !keys.isEmpty {
                    invalidateTagCurveKeys(keys)
                    await refreshTagCurvesForRPE(
                        keys: keys,
                        capturedBy: accountFetch
                    )
                }
            }
        } catch {
            if accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) {
                surface(error)
            }
        }
        await refreshQueueCount(for: accountFetch)
    }

    private func refreshQueueCount(for accountFetch: AccountScopedFetch? = nil) async {
        guard let userID = currentUserID else {
            pendingCacheWriteCount = 0
            queuedWriteCount = 0
            queueBreadcrumbs = []
            quarantinedWrites = nil
            return
        }
        let fetch = accountFetch ?? AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: self.accountEpoch
        )
        guard fetch.canApply(to: userID, accountEpoch: self.accountEpoch) else { return }
        let count: Int
        let breadcrumbs: [QueueBreadcrumb]
        let quarantined: [QuarantinedWrite]?
        if let queue {
            count = await queue.count(for: userID)
            breadcrumbs = await queue.breadcrumbs(for: userID)
            quarantined = await queue.quarantinedItems(for: userID).map { $0.summary() }
        } else {
            count = 0
            breadcrumbs = []
            quarantined = nil
        }
        refreshPendingCacheWriteCount(accountUserID: userID)
        _ = fetch.publishIfCurrent(
            to: currentUserID,
            accountEpoch: self.accountEpoch
        ) {
            queuedWriteCount = count
            queueBreadcrumbs = breadcrumbs
            quarantinedWrites = quarantined
        }
    }

    // MARK: Watch completions

    private func acceptStoredWatchCompletions() async {
        guard let userID = currentUserID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        for completion in watch.drainStoredCompletions() {
            await acceptWatchCompletion(completion, accountFetch: accountFetch)
        }
    }

    private func acceptWatchCompletion(
        _ completion: WatchWorkoutCompletion,
        accountFetch: AccountScopedFetch? = nil
    ) async {
        guard let userID = currentUserID else { return }
        let accountFetch = accountFetch ?? AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: self.accountEpoch
        )
        guard accountFetch.canApply(to: userID, accountEpoch: self.accountEpoch) else {
            return
        }
        if let owner = completion.accountUserID, owner != userID { return }
        let pending = completion.pendingSession()
        guard !sessions.contains(where: { $0.id == pending.id && !$0.pending }) else { return }
        pendingSessions[pending.id] = pending
        mergeSessions(remote: sessions.filter { !$0.pending })
        do {
            let refreshed = try await self.repository.fetchSessions(accountUserID: userID)
            _ = accountFetch.publishIfCurrent(
                to: currentUserID,
                accountEpoch: self.accountEpoch
            ) {
                mergeSessions(remote: refreshed)
            }
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
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        do {
            let row = try await repository.fetchLiveWorkout()
            guard let row,
                  liveWorkoutOwnedBy(row, userID: userID, trustsUnstamped: false)
            else { return }
            _ = accountFetch.publishIfCurrent(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) {
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
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        do {
            if slices.contains(.sessions) {
                guard let snapshot = try await reconcileRealtimeSlice(
                    accountUserID: userID,
                    capturedBy: accountFetch,
                    entityType: .sessions,
                    fetch: { cursor in
                        try await self.repository.fetchSessionDelta(
                            since: cursor,
                            accountUserID: userID
                        )
                    },
                    fallback: { CachedWorkspaceSnapshot(sessions: $0.activeValues) }
                ) else { return }
                let publishedSessions = accountFetch.publishIfCurrent(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) {
                    mergeSessions(remote: snapshot.sessions)
                }
                guard publishedSessions else { return }
            }
            if slices.contains(.recordings) {
                guard let snapshot = try await reconcileRealtimeSlice(
                    accountUserID: userID,
                    capturedBy: accountFetch,
                    entityType: .recordings,
                    fetch: { cursor in
                        try await self.repository.fetchRecordingDelta(since: cursor)
                    },
                    fallback: { CachedWorkspaceSnapshot(recordings: $0.activeValues) }
                ) else { return }
                let publishedRecordings = accountFetch.publishIfCurrent(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) {
                    mergeRecordings(remote: snapshot.recordings)
                    forceModel.hasLoadedRecordings = true
                }
                guard publishedRecordings else { return }
                warmTagCurvesIfMissing(capturedBy: accountFetch)
            }
            if slices.contains(.workouts) {
                guard let snapshot = try await reconcileRealtimeSlice(
                    accountUserID: userID,
                    capturedBy: accountFetch,
                    entityType: .workoutsAndAttempts,
                    fetch: { cursor in
                        try await self.repository.fetchWorkoutDelta(since: cursor)
                    },
                    fallback: { CachedWorkspaceSnapshot(workouts: $0.activeValues) }
                ) else { return }
                let publishedWorkouts = accountFetch.publishIfCurrent(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) {
                    workouts = snapshot.workouts
                }
                guard publishedWorkouts else { return }
            }
            if slices.contains(.health) {
                guard let snapshot = try await reconcileRealtimeSlice(
                    accountUserID: userID,
                    capturedBy: accountFetch,
                    entityType: .healthMetrics,
                    fetch: { cursor in
                        try await self.repository.fetchHealthMetricDelta(since: cursor)
                    },
                    fallback: { CachedWorkspaceSnapshot(healthMetrics: $0.activeValues) }
                ) else { return }
                let publishedHealth = accountFetch.publishIfCurrent(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) {
                    healthMetrics = snapshot.healthMetrics
                }
                guard publishedHealth else { return }
            }
        } catch {
            // Silent degradation, same as the web: a failed reconcile leaves
            // the list stale until the next event or pull-to-refresh.
        }
    }

    /// Fetches one realtime slice as a cursor-bounded delta, reconciles it into
    /// the account cache, and returns the post-reconcile cache snapshot.
    ///
    /// The account/epoch guard is re-checked in the gap between the network
    /// fetch and the cache write, so a realtime completion that outlives a
    /// sign-out never mutates the wrong account's rows. A nil cursor triggers
    /// the same full first-sync adopt/tombstone behavior as `refreshAll`.
    private func reconcileRealtimeSlice<Value: Encodable & Sendable>(
        accountUserID: UUID,
        capturedBy accountFetch: AccountScopedFetch,
        entityType: LocalCacheEntityType,
        fetch: @escaping (String?) async throws -> RemoteEntityDelta<Value>,
        fallback: @escaping (RemoteEntityDelta<Value>) -> CachedWorkspaceSnapshot
    ) async throws -> CachedWorkspaceSnapshot? {
        let cursor = cacheCursor(
            accountUserID: accountUserID,
            entityType: entityType
        )
        let delta = try await fetch(cursor)
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return nil }
        reconcileEntityRefresh(
            delta,
            accountUserID: accountUserID,
            entityType: entityType,
            fullSnapshot: cursor == nil ? fallback(delta) : nil
        )
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return nil }
        guard let workspace = cachedWorkspace else {
            return fallback(delta)
        }
        do {
            return try workspace.load(accountUserID: accountUserID)
        } catch {
            recordCacheFailure("cache realtime publish", error)
            // A cursor-bounded delta is not a complete snapshot. If the cache
            // cannot be read, degrade to the same full network fallback a
            // cache-open failure uses rather than publishing only the changed
            // rows and dropping the rest of the in-memory list.
            guard cursor != nil else { return fallback(delta) }
            let fullDelta = try await fetch(nil)
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return nil }
            return fallback(fullDelta)
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
        accountFetch: AccountScopedFetch,
        userID: UUID,
        remoteSessionIDs: Set<UUID>,
        remoteRecordingIDs: Set<UUID>
    ) async {
        guard let queued = await migrateLegacyRecordingEdits(
            userID: userID,
            capturedBy: accountFetch
        ) else {
            return
        }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return }
        if let queue {
            let orderingFloor = await queue.orderingFloor(for: userID)
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            if let orderingFloor {
                recordingEditCoordinator.observe(orderingFloor: orderingFloor)
            }
            let terminalizedKeys = await queue.terminalizedKeys(for: userID)
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            for recordingID in terminalizedKeys {
                _ = recordingEditCoordinator.ensureDelete(
                    recordingID: recordingID,
                    capturedBy: accountFetch
                )
            }
        }
        // #675 F1: restore BOTH the active entries AND the quarantined ones.
        // A quarantined write is data the user still owns — it is on device,
        // was permanently rejected, and must stay visible in History/Force
        // after a relaunch (rebuilding the optimistic placeholders from
        // `items(for:)` alone made it vanish: not on the server, and the
        // strict drain filter no longer returns it). The restored placeholder
        // is badged `rejected`, never "Syncing" — it will NOT upload on its
        // own. The hot drain path never sees these (only the Settings
        // Retry/Discard actions touch them).
        // `queue.items` is an async boundary. The account may have switched
        // while it was suspended; no pending state, including routine Undo,
        // may be mutated by that stale restore.
        guard let currentUserID = self.currentUserID,
              accountFetch.canApply(
                  to: currentUserID,
                  accountEpoch: self.accountEpoch
              )
        else { return }
        for id in remoteRecordingIDs {
            removePendingCurveSamples(for: id)
        }
        let restoredRecordings = queued.compactMap { item -> PendingRecordingOverlay.Entry? in
            guard case let .recording(recording) = item.payload,
                  !remoteRecordingIDs.contains(recording.id),
                  !recordingEditCoordinator.isDeleted(recording.id)
            else { return nil }
            return PendingRecordingOverlay.Entry(
                accountUserID: item.accountUserID,
                recording: pendingRecording(
                    from: recording,
                    rejected: item.quarantined != nil
                )
            )
        }
        let pendingBeforeRestore = pendingRecordings.recordings(accountUserID: currentUserID)
        let pendingIDsBeforeRestore = pendingRecordings.ids(accountUserID: currentUserID)
        guard pendingRecordings.applyRestored(
            restoredRecordings,
            capturedBy: accountFetch,
            currentUserID: currentUserID,
            accountEpoch: self.accountEpoch
        ) else { return }
        let pendingAfterRestore = pendingRecordings.recordings(accountUserID: currentUserID)
        if pendingIDsBeforeRestore != pendingRecordings.ids(accountUserID: currentUserID)
            || ForceProgress.progressInputsChanged(
                before: pendingBeforeRestore,
                after: pendingAfterRestore
            ) {
            publishForceProgressInputMutation(.pendingRecordings)
        }
        for item in queued {
            guard case let .recording(recording) = item.payload,
                  item.quarantined == nil,
                  !remoteRecordingIDs.contains(recording.id),
                  !recording.samples.isEmpty
            else { continue }
            storePendingCurveSamples(recording.samples, for: recording.id)
        }
        // Read delete intents first. A session insert and its Undo delete can
        // overlap in the queue; the delete must win before any optimistic row
        // is rebuilt from the insert payload.
        for item in queued {
            switch item.payload {
            case let .sessionDelete(payload):
                routineUndo.restorePendingDelete(
                    SessionLogReceipt(
                        sessionID: payload.sessionID,
                        accountUserID: item.accountUserID
                    ),
                    currentUserID: currentUserID
                )
            case let .recordingDelete(payload):
                if let sessionID = payload.sessionID, let queue {
                    do {
                        guard try await queue.protectOrderingIdentity(
                            queueItemID: RecordingEditQueueIdentity.sessionRPE(sessionID),
                            accountUserID: userID,
                            terminalKey: payload.recordingID,
                            terminalItemID: item.id
                        ) else {
                            surface(NSError(
                                domain: "SendmeterNative",
                                code: 10,
                                userInfo: [NSLocalizedDescriptionKey: "Recording delete ordering proof could not be restored."]
                            ))
                            return
                        }
                        guard accountFetch.canApply(
                            to: currentUserID,
                            accountEpoch: accountEpoch
                        ) else { return }
                    } catch {
                        if accountFetch.canApply(
                            to: currentUserID,
                            accountEpoch: accountEpoch
                        ) {
                            surface(error)
                        }
                        return
                    }
                }
                _ = recordingEditCoordinator.ensureDelete(
                    recordingID: payload.recordingID,
                    capturedBy: accountFetch
                )
            default:
                continue
            }
        }
        var restoredSessionRPECandidates: [UUID: [RecordingEditQueueCandidate]] = [:]
        for item in queued {
            let rejected = item.quarantined != nil
            switch item.payload {
            case let .session(payload):
                guard !remoteSessionIDs.contains(payload.id) else { continue }
                let receipt = SessionLogReceipt(
                    sessionID: payload.id,
                    accountUserID: item.accountUserID
                )
                guard !routineUndo.isClaimed(receipt) else { continue }
                pendingSessions[payload.id] = pendingSession(
                    id: payload.id,
                    draft: payload.draft,
                    accountUserID: currentUserID,
                    rpeConfirmed: payload.rpeConfirmed,
                    groupID: payload.groupID,
                    rejected: rejected
                )
            case .sessionDelete:
                continue
            case .recordingDelete:
                continue
            case let .workout(draft):
                guard !remoteSessionIDs.contains(draft.sessionID) else { continue }
                pendingSessions[draft.sessionID] = pendingSession(from: draft, rejected: rejected)
            case .recording:
                // Recording inserts were restored into the account-scoped
                // overlay before this switch.
                continue
            case let .recordingEdit(edit):
                // The edit is an overlay, not a second recording placeholder:
                // the base row may already be on the server, or may still be
                // rebuilt from a queued insert in the pass above.
                guard !recordingEditCoordinator.isDeleted(edit.recordingID) else {
                    continue
                }
                recordingEditCoordinator.observe(
                    sessionRPERevision: item.orderingKey == 0
                        ? edit.sessionRPERevision
                        : item.orderingKey,
                    createdAt: item.createdAt
                )
                pendingRecordingEdits[edit.recordingID] = edit
                if let sessionID = edit.sessionID, edit.sessionRPE != nil {
                    pendingSessionRPEEdits[sessionID] = edit
                }
            case let .sessionRPEEdit(edit):
                guard !recordingEditCoordinator.isDeleted(edit.recordingID) else {
                    continue
                }
                if let sessionID = edit.sessionID, edit.sessionRPE != nil {
                    recordingEditCoordinator.observe(
                        sessionRPERevision: item.orderingKey == 0
                            ? edit.sessionRPERevision
                            : item.orderingKey,
                        createdAt: item.createdAt
                    )
                    restoredSessionRPECandidates[sessionID, default: []].append(
                        RecordingEditQueueCandidate(
                            edit: edit,
                            queueItemID: item.id,
                            createdAt: item.createdAt,
                            nextAttemptAt: item.nextAttemptAt
                        )
                    )
                }
            }
        }
        for (sessionID, candidates) in restoredSessionRPECandidates {
            guard let authoritative = RecordingEditMigration.authoritativeSessionRPE(
                sessionID: sessionID,
                candidates: candidates
            ), !recordingEditCoordinator.isDeleted(authoritative.edit.recordingID) else {
                continue
            }
            pendingSessionRPEEdits[sessionID] = authoritative.edit
        }
    }

    private func pendingSession(
        id: UUID,
        draft: SessionDraft,
        accountUserID: UUID,
        rpeConfirmed: Bool? = nil,
        groupID: UUID? = nil,
        rejected: Bool = false
    ) -> SendmeterCore.Session {
        SendmeterCore.Session(
            id: id,
            date: draft.date,
            type: draft.type,
            typeLabel: draft.typeLabel,
            durationMinutes: draft.durationMinutes,
            rpe: draft.rpe,
            rpeConfirmed: rpeConfirmed ?? true,
            note: draft.note,
            phase: draft.phase,
            groupID: groupID,
            pending: true,
            rejected: rejected,
            accountUserID: accountUserID
        )
    }

    private func pendingSession(from draft: WorkoutDraft, rejected: Bool = false) -> SendmeterCore.Session {
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
            rejected: rejected,
            accountUserID: draft.accountUserID
        )
    }

    /// Apply a recording edit synchronously, before the first queue await, so
    /// History reflects the user's choice even when the network is offline.
    /// The same reducer is replayed over a fresh server fetch after relaunch.
    private func applyPendingRecordingEdit(_ edit: RecordingEdit) {
        let previousEdit = pendingRecordingEdits[edit.recordingID]
        pendingRecordingEdits[edit.recordingID] = edit
        if let previousEdit,
           previousEdit.sessionID != edit.sessionID,
           let previousSessionID = previousEdit.sessionID,
           pendingSessionRPEEdits[previousSessionID] == previousEdit {
            pendingSessionRPEEdits.removeValue(forKey: previousSessionID)
            pendingSessionRPEBases.removeValue(forKey: previousSessionID)
        }
        if let sessionID = edit.sessionID, edit.sessionRPE != nil {
            if pendingSessionRPEEdits[sessionID] == nil,
               let base = sessions.first(where: { $0.id == sessionID && !$0.pending }) {
                pendingSessionRPEBases[sessionID] = base
            }
            pendingSessionRPEEdits[sessionID] = edit
        }

        if let index = recordings.firstIndex(where: { $0.id == edit.recordingID }) {
            let before = recordings
            recordings[index] = RecordingEditReducer.apply(edit, to: recordings[index])
            publishForceProgressRecordingMutationIfNeeded(before: before, after: recordings)
        }
        if let sessionID = edit.sessionID,
           let index = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[index] = RecordingEditReducer.apply(edit, to: sessions[index])
        }
    }

    private func rollbackPendingRecordingEdit(
        _ edit: RecordingEdit,
        previousRecording: TindeqRecording,
        previousSession: SendmeterCore.Session?
    ) {
        if pendingRecordingEdits[edit.recordingID] == edit {
            pendingRecordingEdits.removeValue(forKey: edit.recordingID)
            replaceRecording(previousRecording)
        }
        if let sessionID = edit.sessionID,
           pendingSessionRPEEdits[sessionID] == edit {
            pendingSessionRPEEdits.removeValue(forKey: sessionID)
            if let base = pendingSessionRPEBases.removeValue(forKey: sessionID) {
                replaceSession(base)
            } else if let previousSession {
                replaceSession(previousSession)
            }
        }
    }

    private func pendingRecording(from recording: NewTindeqRecording, rejected: Bool = false) -> TindeqRecording {
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
            completionStatus: recording.completionStatus,
            rejected: rejected
        )
    }

    private func mergeRecordings(remote: [TindeqRecording]) {
        let previous = recordings
        let visibleRemote = remote.filter {
            !recordingEditCoordinator.isDeleted($0.id)
        }
        let remoteIDs = Set(visibleRemote.map(\.id))
        if let currentUserID {
            removePendingRecordings(withIDs: remoteIDs, accountUserID: currentUserID)
        }
        let merged = pendingRecordings
            .merged(remote: visibleRemote, accountUserID: currentUserID)
            .filter { !recordingEditCoordinator.isDeleted($0.id) }
            .map { recording in
                pendingRecordingEdits[recording.id].map {
                    RecordingEditReducer.apply($0, to: recording)
                } ?? recording
            }
            .sorted { $0.recordedAt > $1.recordedAt }
        recordings = merged
        publishForceProgressRecordingMutationIfNeeded(before: previous, after: merged)
        let affectedKeys = changedTagCurveKeys(before: previous, after: recordings)
        invalidateTagCurveKeys(affectedKeys)
    }

    private func mergeSessions(remote: [SendmeterCore.Session]) {
        let visibleRemote = remote.filter { session in
            !routineUndo.hasPendingDelete(
                sessionID: session.id,
                accountUserID: currentUserID
            )
        }
        let remoteIDs = Set(visibleRemote.map(\.id))
        for id in remoteIDs { pendingSessions.removeValue(forKey: id) }
        for session in visibleRemote
            where pendingSessionRPEEdits[session.id] != nil
                && pendingSessionRPEBases[session.id] == nil {
            pendingSessionRPEBases[session.id] = session
        }
        sessions = (visibleRemote + pendingSessions.values.filter { !remoteIDs.contains($0.id) })
            .map { session in
                pendingSessionRPEEdits[session.id].map {
                    RecordingEditReducer.apply($0, to: session)
                } ?? session
            }
            .sorted {
                if $0.date != $1.date { return $0.date > $1.date }
                return $0.id.uuidString > $1.id.uuidString
            }
        // Whether the fetch came back empty or not, the account's session list
        // has now been loaded once — consumers can distinguish "no history"
        // from "not fetched yet" (#652 F2).
        hasLoadedSessions = true
    }

    private func replaceSession(_ session: SendmeterCore.Session) {
        pendingSessions.removeValue(forKey: session.id)
        sessions.removeAll { $0.id == session.id }
        let visible = pendingSessionRPEEdits[session.id].map {
            RecordingEditReducer.apply($0, to: session)
        } ?? session
        sessions.append(visible)
        sessions.sort {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString > $1.id.uuidString
        }
        hasLoadedSessions = true
    }

    private func replaceRecording(_ recording: TindeqRecording) {
        guard !recordingEditCoordinator.isDeleted(recording.id) else {
            let previous = recordings
            recordings.removeAll { $0.id == recording.id }
            publishForceProgressRecordingMutationIfNeeded(before: previous, after: recordings)
            return
        }
        let previousRecording = recordings.first(where: { $0.id == recording.id })
        let previous = recordings
        recordings.removeAll { $0.id == recording.id }
        let visible = pendingRecordingEdits[recording.id].map {
            RecordingEditReducer.apply($0, to: recording)
        } ?? recording
        recordings.append(visible)
        recordings.sort { $0.recordedAt > $1.recordedAt }
        let oldKey = previousRecording.map {
            TagCurveKey(
                tag: $0.tag,
                modality: GaugeSessionRPE.modality(of: $0)
            )
        }
        let newKey = TagCurveKey(
            tag: recording.tag,
            modality: GaugeSessionRPE.modality(of: recording)
        )
        // Do this even when the server returned metadata equal to the
        // optimistic row. Its samples are a new fit input boundary, and the
        // old cache may have been built before this recording existed.
        if recordings != previous || previousRecording != nil {
            publishForceProgressRecordingMutationIfNeeded(before: previous, after: recordings)
            invalidateTagCurveKeys(
                TagCurveCachePolicy.affectedKeys(old: oldKey, new: newKey)
            )
        }
    }

    private func publishForceProgressRecordingMutationIfNeeded(
        before: [TindeqRecording],
        after: [TindeqRecording]
    ) {
        guard ForceProgress.progressInputsChanged(before: before, after: after) else {
            return
        }
        publishForceProgressInputMutation(.recordings)
    }

    private func changedTagCurveKeys(
        before: [TindeqRecording],
        after: [TindeqRecording]
    ) -> Set<TagCurveKey> {
        let oldByID = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
        let ids = Set(oldByID.keys).union(newByID.keys)
        var keys = Set<TagCurveKey>()
        for id in ids {
            let old = oldByID[id]
            let new = newByID[id]
            guard old != new else { continue }
            let oldKey = old.map {
                TagCurveKey(
                    tag: $0.tag,
                    modality: GaugeSessionRPE.modality(of: $0)
                )
            }
            let newKey = new.map {
                TagCurveKey(
                    tag: $0.tag,
                    modality: GaugeSessionRPE.modality(of: $0)
                )
            }
            keys.formUnion(TagCurveCachePolicy.affectedKeys(old: oldKey, new: newKey))
        }
        return keys
    }

    /// Drop only the affected fitted curves. An old fit may still be
    /// suspended in `computeTagCurve`; its per-key request stamp is rejected
    /// on resume, and its task is cancelled where the repository permits it.
    /// Clearing the published entries prevents stale Max/CF/W′ while the
    /// replacement point estimate or chart fit is pending.
    private func invalidateTagCurveKeys(_ keys: Set<TagCurveKey>) {
        guard !keys.isEmpty else { return }
        tagCurveGenerations.invalidate(keys)
        for key in keys {
            tagCurveWarmTasks[key]?.cancel()
            tagCurveWarmTasks.removeValue(forKey: key)
            tagCurveWarmTaskGenerations.removeValue(forKey: key)
            tagCurveCache.removeValue(forKey: key)
            tagCurveBandGenerations.removeValue(forKey: key)
            forceModel.tagCurves.removeAll {
                TagCurveKey(tag: $0.tag, modality: $0.modality) == key
            }
        }
        publishTagCurves()
    }

    /// Full refresh/account reset invalidation remains broader by design, but
    /// still advances every known key so an old task cannot publish after the
    /// snapshot is replaced.
    private func invalidateTagCurveCache() {
        let keys = Set(recordings.map {
            TagCurveKey(
                tag: $0.tag,
                modality: GaugeSessionRPE.modality(of: $0)
            )
        })
            .union(tagCurveCache.keys)
            .union(tagCurveWarmTasks.keys)
            .union(tagCurveBandGenerations.keys)
        tagCurveGenerations.invalidate(keys)
        for task in tagCurveWarmTasks.values { task.cancel() }
        tagCurveWarmTasks.removeAll()
        tagCurveWarmTaskGenerations.removeAll()
        tagCurveCache.removeAll()
        tagCurveBandGenerations.removeAll()
        forceModel.tagCurves = []
    }

    private func resetAccountState() {
        accountEpoch &+= 1
        // A cache failure is account-scoped for diagnostics: the next account
        // should be able to report its own open/read/reconcile failure even if
        // the previous account already suppressed one.
        cacheOpenFailureReported = false
        publishForceProgressInputMutation(.accountReset)
        refreshingOwner = nil
        isRefreshing = false
        // #673: a fresh account must not inherit the prior account's list
        // freshness — the foreground gate would otherwise treat a full
        // refresh as recent and skip the mandatory bootstrap sweep.
        lastListRefreshAt = nil
        sessions = []
        hasLoadedSessions = false
        deletedSessions = []
        deletedRecordings = []
        healthMetrics = []
        phasePeriods = []
        forceModel.hasLoadedRecordings = false
        recordings = []
        presets = []
        routines = []
        workouts = []
        tagMetadata = []
        passkeys = []
        pendingSessions = [:]
        pendingRecordings = PendingRecordingOverlay()
        clearPendingCurveSamples()
        pendingRecordingEdits = [:]
        pendingSessionRPEEdits = [:]
        pendingSessionRPEBases = [:]
        let staleRPEWaiters = sessionRPEWaiters.values.flatMap { $0 }
        sessionRPEWaiters.removeAll()
        for waiter in staleRPEWaiters { waiter.resume() }
        let staleQueueUploadWaiters = queueUploadWaiters.values.flatMap { $0 }
        queueUploadWaiters.removeAll()
        for waiter in staleQueueUploadWaiters { waiter.resume() }
        recordingEditCoordinator.resetAccountScopedState()
        routineUndo.reset()
        // Upload claims belong to their in-flight tasks, not to the loaded UI
        // snapshot. Keep them until upload's defer releases them: an A→B→A
        // account transition must not let the returning A duplicate a request
        // that is still suspended for A. B can proceed through its own key.
        queuedWriteCount = 0
        pendingCacheWriteCount = 0
        queueBreadcrumbs = []
        quarantinedWrites = nil
        gaugeSessionTracker.reset()
        forceModel.guidedProtocolActive = false
        guidedProtocolTeardown = nil
        guidedProtocolTeardownOwnerID = nil
        invalidateTagCurveCache()
        handsFree.handleDisconnected()
        manualWorkoutRest.stop()
        manualWorkoutActivity.end(immediate: true)
        manualWorkoutActivity.discardPendingEvents()
        keepAwakeRelease?()
        keepAwakeRelease = nil
        // The mirror must not survive an account change even without an
        // intervening .signedOut (deep-link sign-in as another user) — a
        // stale row would render the previous account's attempt count/HR for
        // up to the 30s staleness window (#final review finding 1).
        liveWorkoutMirror = .empty
        liveMirrorTicker?.cancel()
        liveMirrorTicker = nil
        // #631: Send Conditions are location-bound, not account-bound, but
        // they are also not signed-in data — drop them with the session so
        // the next user's dashboard starts clean.
        weather.resetForAccountChange()
    }

    private func perform(_ operation: @escaping () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            surface(error)
        }
    }

    private func surface(_ error: Error) {
        errorMessage = UserFacingError.message(for: error)
    }
}
