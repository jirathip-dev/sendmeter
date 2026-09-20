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
    case sessionMerge(SessionMergeQueuePayload)
    case recording(NewTindeqRecording)
    case recordingEdit(RecordingEdit)
    case sessionRPEEdit(RecordingEdit)
    case recordingDelete(RecordingDeleteQueuePayload)
    case workout(WorkoutDraft)
    /// #916: the direct-write replay intents. Their entity identity is the
    /// queue item's `id`, so the queue holds exactly ONE intent per preset or
    /// routine and a newer mutation coalesces onto it instead of racing it.
    case preset(DirectWriteIntent<TindeqPreset>)
    case routine(DirectWriteIntent<RoutinePreset>)
    /// #917: one training-block transition (phase periods + settings) as a
    /// single intent. The settings row and the periods are written together,
    /// so they are persisted together too.
    case phaseTransition(PhaseTransitionIntent)
    /// #918: one durable tag-registry mutation (rename / hide / unhide). A tag
    /// is a name, so its queue identity is the stable hash of that name and the
    /// queue holds at most ONE intent per tag: a newer mutation replaces the
    /// pending one and keeps the identity it continues (see
    /// `TagMutationReplayPolicy.replacing`).
    case tagMutation(TagMutationIntent)
    /// #919: one interrupted health-metric write. A health row's identity is
    /// its `(user_id, date)` key, mapped to a stable queue identity
    /// (`HealthWriteIdentity`) so the queue holds at most ONE intent per date:
    /// a newer pass replaces the pending one wholesale, and the recovery
    /// REVALIDATES the queued payload against the server's current row instead
    /// of replaying it (see `HealthWriteReplayPolicy`).
    case healthWrite(HealthWriteIntent)
}

private extension PendingWrite {
    /// The operation this payload replays, for the direct-write entities.
    var directWriteOperation: DirectWriteOperation? {
        switch self {
        case let .preset(intent): return intent.operation
        case let .routine(intent): return intent.operation
        default: return nil
        }
    }

    /// The entity identity the queue item is keyed by. Preset and routine cache
    /// entity ids are uuid strings, so the queue id is that uuid. The phase
    /// transition is an account-wide singleton: every transition for one
    /// account shares `PhaseTransitionIntent.queueItemID`, so a newer switch
    /// replaces the pending one instead of racing it.
    /// The queue item id for `accountUserID`. The account is passed in because
    /// the queue is ONE file shared by every account on the device: a health
    /// row's date is the same for all of them, so its key has to include the
    /// account or it would collide with another account's pending write for
    /// the same day (#919).
    func directWriteEntityID(accountUserID: UUID) -> UUID? {
        switch self {
        case let .preset(intent): return UUID(uuidString: intent.entityID)
        case let .routine(intent): return UUID(uuidString: intent.entityID)
        // A tag's registry identity IS its name, and the queue key is that
        // name's stable hash, so a relaunch (or a newer mutation for the same
        // tag) recovers the pending intent from the name alone.
        case let .tagMutation(intent): return intent.queueIdentity
        case .phaseTransition: return PhaseTransitionIntent.queueItemID
        // A health row's identity is its `(account, date)` key: the date alone
        // would collide across accounts, and the account alone would collide
        // across days.
        case let .healthWrite(intent):
            return intent.queueIdentity(accountUserID: accountUserID)
        default: return nil
        }
    }

    /// Whether a newer mutation of this payload REPLACES the pending one
    /// wholesale (no create/update/delete coalescing): the phase transition
    /// carries its whole intended end state, so the newest intent is the
    /// account's only pending transition.
    var replacesPendingWithNewest: Bool {
        switch self {
        case .phaseTransition: return true
        // #919: a health pass carries the whole row state it decided to write
        // (its biometrics plus, when the pass could score, its readiness), so
        // the newest pass for a date is the account's only pending write for
        // that date — there is no create/update/delete vocabulary to coalesce.
        case .healthWrite: return true
        default: return false
        }
    }

    var directWriteCacheEntityType: LocalCacheEntityType? {
        switch self {
        case .preset: return .presets
        case .routine: return .routinePresets
        // The transition writes TWO entity types; a single cache identity does
        // not describe it. Its confirmation enumerates them separately (and
        // every other payload is not a direct write at all).
        default: return nil
        }
    }

    /// The same intent re-labelled with a coalesced operation (keeping the
    /// newer content and the operation identity already persisted).
    func relabeled(with operation: DirectWriteOperation) -> PendingWrite? {
        switch self {
        case let .preset(intent):
            return .preset(intent.replacingOperation(operation))
        case let .routine(intent):
            return .routine(intent.replacingOperation(operation))
        default:
            return nil
        }
    }
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

/// The user-visible diagnostic for an active durable write. Active failures
/// are deliberately separate from `QuarantinedWrite`: auth, permission, and
/// transport failures stay retryable and must remain visible after relaunch.
public struct QueuedWriteDiagnostic: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let accountUserID: UUID
    public let createdAt: Date
    public let updatedAt: Date
    public let kind: String
    public let attempts: Int
    public let permanentAttempts: Int
    public let nextAttemptAt: Date
    public let rejectionClass: RejectionClass?
    public let lastError: String?
    public let lastFailureAt: Date?
    public let lastFailureCode: String?
}

private extension DurableQueueItem where Payload == PendingWrite {
    var writeKind: String {
        switch payload {
        case .session: return "Session"
        case .sessionDelete: return "Session deletion"
        case .sessionMerge: return "Session merge"
        case .recording: return "Force recording"
        case .recordingEdit: return "Force recording edit"
        case .sessionRPEEdit: return "Session RPE edit"
        case .recordingDelete: return "Force recording deletion"
        case .workout: return "Manual workout"
        case .preset: return "Preset"
        case .routine: return "Routine"
        case .phaseTransition: return "Training block change"
        case .tagMutation: return "Tag change"
        case .healthWrite: return "Health metric"
        }
    }

    func summary() -> QuarantinedWrite {
        return QuarantinedWrite(
            id: id,
            accountUserID: accountUserID,
            createdAt: createdAt,
            kind: writeKind,
            attempts: attempts,
            rejection: quarantined ?? QueueRejection(
                kind: .permanent,
                code: nil,
                detail: lastError ?? ""
            ),
            lastError: lastError
        )
    }

    func diagnostic() -> QueuedWriteDiagnostic {
        QueuedWriteDiagnostic(
            id: id,
            accountUserID: accountUserID,
            createdAt: createdAt,
            updatedAt: updatedAt,
            kind: writeKind,
            attempts: attempts,
            permanentAttempts: permanentAttempts ?? 0,
            nextAttemptAt: nextAttemptAt,
            rejectionClass: rejectionClass,
            lastError: lastError,
            lastFailureAt: lastFailure?.at,
            lastFailureCode: lastFailure?.code
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

/// #942: a queued same-day Tindeq merge — the plan's identity (survivor,
/// merged set, the recordings that move) plus the survivor's merged fields,
/// so a relaunch can rebuild the optimistic row and the RPC can be retried
/// verbatim. `rpeConfirmed` is part of the plan: the RPC writes it through.
private struct SessionMergeQueuePayload: Codable, Sendable {
    let survivorID: UUID
    let mergedSessionIDs: [UUID]
    let recordingIDs: [UUID]
    let groupID: UUID
    let draft: SessionDraft
    let rpeConfirmed: Bool
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
    /// Set by SplashView's first presentation, after synchronous model setup.
    private var splashPresentationFloor: SplashPresentationFloor?
    private var splashPresentationWaiters: [CheckedContinuation<SplashPresentationFloor, Never>] = []
    private var splashPresentationFloorConsumed = false
    public private(set) var splashPresentationDate: Date?
    public private(set) var authSession: AuthSession?
    /// Local auth self-heal and the SDK's resulting `.signedOut` event can
    /// cross an await in either order. This gate makes the account boundary
    /// idempotent: one failure advances `accountEpoch` at most once.
    private var authRecoveryInProgress = false
    /// Nonfatal server-time evidence is kept as account-scoped presentation
    /// state so Settings can give the user the Date & Time nudge without
    /// clearing an otherwise usable session.
    public private(set) var authClockAdvisoryMessage: String?
    public private(set) var sessions: [SendmeterCore.Session] = []
    /// True once the current account has crossed an authoritative session
    /// boundary: either a persisted sync cursor/empty-result marker was
    /// hydrated or a network/realtime refresh published successfully. A
    /// readable first-launch SQLite file does not qualify, so `sessions.isEmpty`
    /// and this flag still distinguish "no history" from "not loaded yet".
    /// Consumers use this to avoid claiming a fresh user has no history after
    /// an offline or failed refresh (#652 F2, #787).
    public private(set) var hasLoadedSessions = false
    /// True once the current account has crossed the recordings' authoritative
    /// sync boundary, including an authoritative empty result. A readable
    /// first-launch SQLite file does not qualify. History owns the shared
    /// recording collection on AppModel, so it needs this boundary without
    /// observing ForceModel's hot stream (#787).
    public private(set) var hasLoadedRecordings = false
    public private(set) var deletedSessions: [SendmeterCore.Session] = []
    public private(set) var deletedRecordings: [TindeqRecording] = []
    public private(set) var healthMetrics: [HealthMetric] = []
    /// The last completed HealthKit read for the current account. This is a
    /// read/check timestamp, not a claim that a row changed; the companion
    /// observation distinguishes a real reconciliation from a no-op or an
    /// empty source window.
    public private(set) var lastHealthSyncedAt: Date?
    public private(set) var lastHealthSyncObservation: HealthSyncObservation?
    public private(set) var phasePeriods: [PhasePeriod] = []
    public private(set) var settings = UserSettings(
        currentPhase: .capacity,
        phaseStartDate: LocalDateSupport.string(from: Date())
    )
    /// The shared force-recording list. It is read by the Force tab, History,
    /// and Settings; a fresh account resets it via `resetAccountState()`. The
    /// force-scoped progress revisions and curves live on `ForceModel`; the
    /// cold list-load boundary is duplicated here for History.
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
    /// True while any account-scoped list refresh is in flight, including
    /// silent foreground/realtime refreshes. `isRefreshing` remains the
    /// explicit-spinner state; this separate boundary prevents a silent first
    /// load from being rendered as a retry/empty state (#787).
    public private(set) var isLoadingData = false
    public private(set) var queuedWriteCount = 0
    /// Active queue entries, including the most recent failure class and
    /// backoff. This is intentionally retained separately from the count so a
    /// pending badge never hides the reason an upload is still waiting.
    public private(set) var queuedWriteDiagnostics: [QueuedWriteDiagnostic] = []
    /// Unconfirmed cache rows for direct writes that have no durable replay
    /// after process death (presets, routines, phase/settings, tag metadata).
    /// Kept separate from `queuedWriteCount` so Settings can label them as
    /// unsynced rather than as automatically retried queue work.
    public private(set) var pendingCacheWriteCount = 0
    /// #920: true once this session has read the account's durable queue and
    /// its quarantine list at least once. Before that, a zero
    /// `queuedWriteCount`/`pendingCacheWriteCount` means "not read yet" and
    /// MUST NOT render as "Synced" (#269 honest-states rule).
    public private(set) var hasLoadedPendingWrites = false
    /// #920: the measured outcome of the account's last "Retry Now" pass, so
    /// the sync surface can tell work the button really retries from a residue
    /// the pass proved it cannot upload.
    public private(set) var lastRetryOutcome: MutationRetryOutcome?
    /// #920 AC4: true while a retry pass owns the account's queue. A second
    /// tap coalesces onto the running pass instead of racing a second drain,
    /// and the flag is published once per account so a switch cannot light up
    /// the wrong screen's progress.
    public private(set) var isRetryingQueuedWrites = false
    /// #920 AC4: the identity of the retry pass allowed to clear
    /// `isRetryingQueuedWrites` (account + epoch + token). #935: the RULE lives
    /// with the recovery owner (`MutationRetryGate`); this is the app's copy of
    /// its state.
    private var queuedWritesRetryGate = MutationRetryGate()
    public private(set) var queueBreadcrumbs: [QueueBreadcrumb] = []
    /// #675: entries the server has permanently rejected — retained on device,
    /// excluded from every automatic retry, and recoverable only by the
    /// explicit Retry/Discard actions in Settings. `nil` means the queue has
    /// not been read yet this session; `[]` means genuinely nothing
    /// quarantined. Never default to `[]` where the honest state is "not
    /// known" (#269 honest-states rule — unknown must not render as empty).
    public private(set) var quarantinedWrites: [QuarantinedWrite]?
    public var errorMessage: String?
    /// #964: the classification of the last account-data load failure, kept
    /// apart from `errorMessage` because the banner is dismissible: after the
    /// banner is dismissed (or was never rendered), the Dashboard still needs
    /// a truthful failure state with a retry instead of an empty screen. Only
    /// set by the refresh funnel and only cleared by a refresh that actually
    /// succeeds (or an account reset), so it can never outlive its cause.
    public private(set) var dashboardLoadFailureClass: FriendlyErrorClass?
    /// #923: the scoped failure of the most recent refresh that published some
    /// consistency groups and failed others. A partial failure is not a
    /// blackout, so this — not the global banner — is where its retry lives.
    /// Cleared by a pass where every slice reconciled (or by an account reset).
    public private(set) var lastPartialRefreshFailure: RefreshFailureSummary?
    /// #964: true while the Dashboard should lead with its load-failure state:
    /// the last account-data load failed AND the account has no authoritative
    /// snapshot to render (`hasLoadedSessions` / `hasLoadedRecordings` are the
    /// same last-good-data boundary `ErrorSurfacePolicy` reasons over). A
    /// failure with data on screen belongs to the dismissible banner only.
    public var showsDashboardLoadFailure: Bool {
        dashboardLoadFailureClass != nil
            && !hasLoadedSessions
            && !hasLoadedRecordings
    }
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
    /// True while a release-triggered hands-free pull is being made durable.
    /// The Force fullscreen uses this to show the same save boundary as the
    /// compact card without taking ownership of the persistence flight.
    public private(set) var handsFreeSaveInFlight = false
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
    /// #936: the ONE owner of the manual-workout lifecycle — start, minimize,
    /// resume, the attempt transitions, End and the save it triggers, the
    /// rest/live-card effects that follow it, and the account boundary that
    /// tears it down. It HOLDS the in-progress workout, which is what makes a
    /// recreated `WorkoutView` safe: the view reads the running workout from
    /// here instead of owning it, so recreation can neither recreate it nor
    /// silently terminate it. The owner performs no I/O — every effect it
    /// decides is applied by `applyManualWorkoutLifecycle(_:)`, and the finish's
    /// save still goes through `saveWorkout` → the #935 recovery owner.
    public private(set) var manualWorkoutLifecycle = ManualWorkoutLifecycleCoordinator()
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
    /// #921: the account-agnostic cache handle. It is `nil` until the one
    /// preparation flight has opened and migrated the store, so a cache-backed
    /// read during that window degrades to the network-only path instead of
    /// touching an unready store. `cacheReadiness` is the honest state.
    private var cachedWorkspace: CachedWorkspace?
    /// #921: the one lifetime preparation flight, shared by the auth bootstrap,
    /// the foreground pass and a background app-refresh.
    private let cachePreparation = CachePreparation()
    private let cacheStorageSeams: CacheStorageSeams
    /// #934: the single owner of the workspace refresh/reconciliation rules.
    /// The foreground pass, the background app-refresh and the realtime slice
    /// reconciler all route their SHARED rules through this one coordinator —
    /// no second cache handle, cursor store or competing sync owner. It holds
    /// no app state: the store, the account boundary and the failure reporter
    /// are passed in per call.
    private let workspaceSync: WorkspaceSyncCoordinator
    /// #935: the single owner of the durable mutation recovery rules — drain,
    /// manual/single-item retry, backoff, quarantine and the pass's
    /// acknowledgement. The automatic drain (including the sign-out drain), the
    /// explicit retry pass, the per-item manual retry and the quarantine
    /// lifecycle all route their SHARED rules through this one coordinator — no
    /// second queue, no second persistence format and no competing drain
    /// timer. It holds no app state: the queue, the account boundary and the
    /// uploader are passed in per call.
    private let mutationRecovery = MutationRecoveryCoordinator()
    private let cacheDirectory: URL?
    /// #921: what the app knows about the local cache. `preparing` until the
    /// flight answers; `unavailable` is recoverable and never a success claim.
    public private(set) var cacheReadiness: CacheReadiness = .preparing
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
    /// #942: merged-away session ids whose queued merge has not uploaded yet,
    /// mapped to the account that owns the merge. An authoritative fetch still
    /// returns those rows (the server soft-deletes them only when the RPC
    /// lands), so they are filtered out of every published list until the
    /// merge is applied — otherwise a refresh would resurrect the entries the
    /// user just merged.
    private var pendingMergedAwaySessionIDs: [UUID: UUID] = [:]
    /// Direct WC delivery and `transferUserInfo` can overlap. The gate is
    /// claimed before the first cache write and released only after the whole
    /// adoption path returns; the cache row itself is the relaunch-safe dedupe
    /// record.
    private var watchCompletionAdoption = WatchCompletionAdoptionGate()
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
    /// #916: accounts whose pending cache-only preset/routine rows have been
    /// adopted into the durable queue this process. The adoption is finite and
    /// costs a list fetch per entity type, so it runs from the drain path once
    /// per account rather than on every pass.
    private var migratedDirectWriteAccounts: Set<UUID> = []
    /// #917 AC4: accounts whose pre-#917 phase/settings residue was already
    /// resolved (or proven free of residue) in this process.
    private var recoveredPhaseResidueAccounts: Set<UUID> = []
    /// #918 AC5: accounts whose pre-#918 tag-registry residue was already
    /// resolved (or proven free of residue) in this process.
    private var recoveredTagResidueAccounts: Set<UUID> = []
    /// #919: accounts whose pre-#919 health-metric residue (a pending
    /// cache-only row with no replay intent) was already resolved (or proven
    /// free of residue) in this process.
    private var recoveredHealthResidueAccounts: Set<UUID> = []
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
    /// The optional purge-generation endpoint is rollout-sensitive. Keep its
    /// user-facing report account/epoch scoped and once-per-outage, while
    /// silent/realtime/background callers retain the nil/full-reconcile
    /// fallback without touching the error banner.
    private var purgeGenerationFailurePolicy = PurgeGenerationFailurePolicy()
    private var refreshingOwner: AccountScopedCompletion?
    private var dataRefreshOwners = Set<UUID>()
    private var recomputeGate = ReadinessRecomputeGate()
    /// Freshness the most recent recompute pass reported to the watch (#913):
    /// `.fresh` when the pass wrote a new score, `.cached` when it
    /// deliberately kept the existing one. Read after the pass by a
    /// watch-originated request, which must report what the phone actually did
    /// rather than claim a fresh compute.
    @ObservationIgnored private var lastReadinessPublicationFreshness: ReadinessFreshness = .cached
    /// #661: silent foreground/appear health sync. The policy is pure Core
    /// (`HealthRefreshPolicy`, unit-tested); `lastHealthRefreshStartedAt` is
    /// the monotonic system-uptime time the most recent actual refresh started
    /// (never wall-clock — an NTP step or manual clock change must not suppress
    /// every refresh for the skew, finding 7). The window mirrors the web's
    /// `FOREGROUND_SYNC_COALESCE_MS` (5s).
    private let healthRefreshPolicy = HealthRefreshPolicy(coalescingWindow: 5)
    private var lastHealthRefreshStartedAt: TimeInterval?
    /// Morning HealthKit delivery can arrive before an overnight wearable has
    /// finished writing to Apple Health. One account-scoped owner runs an
    /// immediate pass and persists the two follow-up passes; later lifecycle,
    /// observer, or BGAppRefresh events claim each pass when it is due.
    private let healthMorningRefreshPolicy = HealthMorningRefreshPolicy()
    private var lastMorningRefreshStartedAt: Date?
    private var morningHealthRefreshState = HealthMorningRefreshStateMachine()
    private var morningHealthRefreshOwner: AccountScopedCompletion?
    private static let healthLastSyncedDefaultsPrefix = "sendmeter.native.health-last-synced-at."
    private static let healthMorningStartedDefaultsPrefix = "sendmeter.native.health-morning-started-at."
    private static let healthMorningProgressDefaultsPrefix = "sendmeter.native.health-morning-progress."
    /// #673: the gate that decides whether a scenePhase → `.active`
    /// transition runs the 9-table authoritative `refreshAll`. The policy is
    /// pure Core (`ForegroundRefreshPolicy`, unit-tested); the window is the
    /// no-change grace period — a foreground inside it with data loaded and
    /// realtime healthy issues 0 full-table fetches. `lastListRefreshAt` is
    /// MONOTONIC (`systemUptime`), never wall-clock, so an NTP step or manual
    /// clock change cannot make the delta negative and suppress every refresh.
    private let foregroundRefreshPolicy = ForegroundRefreshPolicy(staleAfter: 60)
    private var lastListRefreshAt: TimeInterval?
    /// #842: decides whether a refresh failure may escalate to the global
    /// error banner. Pure Core (`ErrorSurfacePolicy`, unit-tested); the
    /// refresh call sites pass the source (user-initiated vs background) and
    /// the account's last-good state (`hasLoadedSessions` /
    /// `hasLoadedRecordings`).
    private let errorSurfacePolicy = ErrorSurfacePolicy()
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
        weather: WeatherService? = nil,
        cacheStorageSeams: CacheStorageSeams = .live
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
                    sessionProvider: { try await authRef.ensureFreshSession() },
                    serverClock: authRef.serverClock
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

        // #921: the local cache is prepared OFF the launch path. `init` no
        // longer creates the directory, opens SQLite or runs the schema
        // migrations — all three used to run synchronously on the main actor
        // right here, before the app could present its first frame (see the
        // block this replaced, #747). The one preparation flight now runs on
        // the storage side (`CachePreparation`) and every cache-backed
        // lifecycle entrypoint JOINS it. A store that is slow, missing or
        // broken therefore cannot delay the first frame; the splash
        // presentation policy (#841) owns that window, and its intentional
        // floor is not performance waste.
        self.cacheStorageSeams = cacheStorageSeams
        self.workspaceSync = WorkspaceSyncCoordinator(seams: cacheStorageSeams)
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("SendmeterNative", isDirectory: true)
        self.cacheDirectory = support
        self.cachedWorkspace = nil
        // The durable queue is a small JSON file owned by `DurableQueue`; its
        // read is not the database open this issue moves and is measured in
        // docs/evidence/issue-921/first-frame-timings.txt.
        self.queue = support.flatMap { directory in
            try? DurableQueue(
                directoryURL: directory,
                filename: "pending-writes.json",
                breadcrumbLimit: 10
            )
        }
        // Start the single flight without awaiting it, so opening and
        // migrating the store overlaps the auth round-trip instead of
        // following it. `prepareCacheIfNeeded()` joins this same flight.
        let preparation = self.cachePreparation
        let seams = self.cacheStorageSeams
        Task { _ = await preparation.preparedCache(directory: support, seams: seams) }

        let watch = self.watchService
        let realtime = self.realtime
        let tindeq = self.tindeq
        let auth = self.auth
        let weather = self.weatherService
        let health = self.healthService

        watch.onSessionRequested = { [weak self] in
            await self?.relayValidSessionToWatch(guaranteed: true)
        }
        // #913: the watch's readiness ask runs on the phone's single-flight
        // HealthKit pipeline; the closure returns the typed outcome the watch
        // renders (the bridge owns identity, coalescing, and the fence).
        watch.onReadinessRefresh = { [weak self] _ in
            guard let self else { return .unsupported() }
            return await self.performWatchReadinessRefresh()
        }
        watch.onWorkoutCompletion = { [weak self] completion in
            guard let self else { return false }
            return await self.acceptWatchCompletion(completion)
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

    private func awaitSplashPresentationFloor() async {
        guard !splashPresentationFloorConsumed else { return }
        splashPresentationFloorConsumed = true
        let floor: SplashPresentationFloor
        if let splashPresentationFloor {
            floor = splashPresentationFloor
        } else {
            floor = await withCheckedContinuation { continuation in
                splashPresentationWaiters.append(continuation)
            }
        }
        let remaining = floor.remaining(at: Date())
        guard remaining > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
    }

    func splashPresented(at date: Date) {
        guard splashPresentationFloor == nil else { return }
        splashPresentationDate = date
        let floor = SplashPresentationFloor(coldStartAt: date)
        splashPresentationFloor = floor
        let waiters = splashPresentationWaiters
        splashPresentationWaiters.removeAll()
        waiters.forEach { $0.resume(returning: floor) }
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

    /// Publishes the authoritative readiness, in-memory session load, and
    /// phase state that Dashboard uses. The widget receives no HealthKit or
    /// Supabase credentials; it gets an account/epoch-stamped snapshot only.
    /// Dashboard keeps its historical list ordering, while the widget selects
    /// today's row explicitly so a stale yesterday score cannot appear as
    /// today's score.
    private func publishReadinessWidgetSnapshot() {
        guard let userID = currentUserID else {
            ReadinessWidgetBridge.clear()
            return
        }

        let now = Date()
        let today = ReadinessWidgetTimelinePolicy.localDayString(for: now)
        let todayMetric = healthMetrics.first { $0.date == today }
        let computedACWR = TrainingMetrics.computeACWR(
            sessions: sessions,
            referenceDate: now
        )
        let loadValues: (acute: Double?, chronic: Double?, ratio: Double?)
        if let ratio = computedACWR.ratio,
           computedACWR.acute.isFinite,
           computedACWR.acute >= 0,
           computedACWR.chronic.isFinite,
           computedACWR.chronic >= 0,
           ratio.isFinite,
           ratio >= 0 {
            loadValues = (
                computedACWR.acute,
                computedACWR.chronic,
                ratio
            )
        } else {
            // `ACWRData` uses zeroes for the raw sums when there is no
            // training history. That is useful to Dashboard's math, but a
            // widget must not turn those sentinel values into a claim that a
            // zero acute/chronic load was freshly measured.
            loadValues = (nil, nil, nil)
        }
        let phase = currentPhase
        let blockAge = TrainingMetrics.phaseBlockAge(
            periods: phasePeriods,
            currentPhase: settings.currentPhase,
            fallbackStartDate: settings.phaseStartDate,
            referenceDate: today
        )
        let snapshot = ReadinessWidgetSnapshot(
            accountUserID: userID,
            accountEpoch: accountEpoch,
            day: today,
            capturedAt: now,
            readiness: todayMetric?.readiness,
            readinessZone: todayMetric?.zone,
            readinessComputedAt: todayMetric?.computedAt,
            acute: loadValues.acute,
            chronic: loadValues.chronic,
            acwr: loadValues.ratio,
            phaseID: settings.currentPhase.rawValue,
            phaseName: phase.name,
            phaseColorHex: phase.colorHex,
            phaseWeek: blockAge?.week,
            phaseDay: blockAge?.totalDays
        )
        ReadinessWidgetBridge.publish(snapshot, for: accountScope)
    }

    public var recentSessions: [SendmeterCore.Session] { Array(sessions.prefix(8)) }
    public var latestQueuedWriteFailure: QueuedWriteDiagnostic? {
        queuedWriteDiagnostics
            .filter { $0.lastError != nil || $0.rejectionClass != nil }
            .max {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt < $1.updatedAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    /// #920: the one derivation of the pending/sync status every sync surface
    /// reads. It is built only from acknowledged answers — the queue's own
    /// read (`queuedWriteCount` / `quarantinedWrites`), the cache's pending
    /// row count, and the measured result of the last retry pass — so a local
    /// optimistic write is never presented as a remote sync, and a zero count
    /// that has not been read yet is "not loaded", never "Synced".
    public var mutationSyncStatus: MutationSyncStatus {
        MutationSyncStatus.resolve(
            // #921: a cache that has not answered cannot have read its
            // unsynced rows, so its zero count must never resolve to
            // "Synced" — the gate reports `notLoaded` ("Checking…") instead.
            cacheReadiness.honestSyncInputs(
                MutationSyncStatusInputs(
                    hasLoadedPendingWrites: hasLoadedPendingWrites,
                    queuedCount: queuedWriteCount,
                    unsyncedCacheCount: pendingCacheWriteCount,
                    quarantinedCount: quarantinedWrites?.count,
                    isRetrying: isRetryingQueuedWrites,
                    lastRetryOutcome: lastRetryOutcome
                )
            )
        )
    }

    /// #922: the tag-registry identities on this device that the server has
    /// not confirmed. Every tag mutation — a queued intent or a cache-only
    /// residue from an older app version — writes its optimistic row with the
    /// (trimmed) tag name as the cache identity, so this one set covers both
    /// without counting the same change twice. Manage Exercises names them.
    ///
    /// Published state, not a query: this used to read the cache inside a view
    /// body. It is refreshed at the same boundaries as `pendingCacheWriteCount`
    /// — every cache confirm/write and every publish — so a render never
    /// touches the store.
    public private(set) var pendingTagWriteCount = 0

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

    /// Hide or unhide a tag (#918).
    ///
    /// The visibility change is persisted as a durable intent BEFORE the
    /// optimistic registry row is published: a termination between the local
    /// write and the server's answer then replays the same mutation instead of
    /// leaving a cache-only pending row with no intent behind it. The intent
    /// carries only `name` and `hidden` — the device-local side mode is not part
    /// of it (see `setTagSideMode`), so nothing but the visibility flag can
    /// reach `tindeq_tags` from here.
    public func setTagHidden(name: String, hidden: Bool) async {
        guard let userID = currentUserID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let intent = TagMutationIntent(
            knownNames: [trimmed],
            hidden: hidden
        )
        guard let item = await enqueueDirectWrite(
            .tagMutation(intent),
            capturedBy: accountFetch,
            startUpload: false
        ) else { return }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return }
        let optimistic = TagMetadata(name: trimmed, hidden: hidden)
        if let index = tagMetadata.firstIndex(where: { $0.name == trimmed }) {
            tagMetadata[index] = optimistic
        } else {
            tagMetadata.append(optimistic)
        }
        cacheUpsertLocal(
            optimistic,
            accountUserID: userID,
            entityType: .tagMetadata,
            entityID: CacheEntityID.tagMetadata(optimistic)
        )
        toastMessage = hidden ? "Hid “\(trimmed)”" : "Showing “\(trimmed)”"
        startQueueUpload(item, capturedBy: accountFetch)
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
    ///
    /// #918: the rename is persisted as a durable intent BEFORE anything local
    /// moves, and its two halves are settled together by the replay. A
    /// termination between the optimistic repoint and the server's
    /// acknowledgement therefore leaves a replayable rename instead of
    /// recordings repointed in the cache with nothing to finish the job, and the
    /// intent keeps the name it has to repoint FROM — a later rename of the new
    /// name either replaces this intent (still pending) or replays after it.
    ///
    /// The device-local side mode moves with the tag locally and is never part
    /// of the intent: `tindeq_tags` is only ever written with the visibility flag
    /// (the DB function carries `side_mode` across a rename on its own).
    public func renameTag(oldName: String, newName: String) async {
        guard let userID = currentUserID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        let old = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.isEmpty, !next.isEmpty else { return }
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
        // The references this rename carries: every recording the user will see
        // under the new name once the repoint lands. They are the evidence the
        // replay proves the rename against before it confirms anything.
        let repointedRecordings = optimisticRecordings.filter { $0.tag == next }
        let intent = TagMutationIntent(
            knownNames: [old],
            renamedTo: next,
            recordingIDs: repointedRecordings.map(\.id)
        )
        guard let item = await enqueueDirectWrite(
            .tagMutation(intent),
            capturedBy: accountFetch,
            startUpload: false
        ) else { return }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return }
        let optimisticMetadata = previousMetadata
            .filter { $0.name != old }
            .filter { $0.name != next } + [nextMetadata]
        recordings = optimisticRecordings
        tagMetadata = optimisticMetadata
        for recording in repointedRecordings {
            cacheUpsertLocal(
                recording,
                accountUserID: userID,
                entityType: .recordings,
                entityID: CacheEntityID.recording(recording)
            )
        }
        for metadata in optimisticMetadata {
            cacheUpsertLocal(
                metadata,
                accountUserID: userID,
                entityType: .tagMetadata,
                entityID: CacheEntityID.tagMetadata(metadata)
            )
        }
        if old != next {
            cacheMarkDeletedLocal(
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
        toastMessage = merged
            ? "Merged into “\(next)”"
            : "Renamed to “\(next)”"
        startQueueUpload(item, capturedBy: accountFetch)
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
        guard let userID = currentUserID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        do {
            try await self.auth.registerPasskey()
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            self.toastMessage = "Passkey registered."
            // #712: a registration must be visible as a persistent list entry
            // and count in Settings, not just a transient toast.
            await self.loadPasskeys()
        } catch {
            if accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) {
                surface(error)
            }
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
        guard let userID = currentUserID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        do {
            try await self.auth.deletePasskey(id: id)
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            self.toastMessage = "Passkey removed."
            await self.loadPasskeys()
        } catch {
            if accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) {
                surface(error)
            }
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
            guard let userID = self.currentUserID else {
                try await self.auth.signOut()
                guard self.currentUserID == nil else { return }
                self.watch.relaySession(nil)
                self.resetAccountState()
                self.bootState = .signedOut
                await self.tearDownRealtime()
                return
            }
            let accountFetch = AccountScopedFetch(
                accountUserID: userID,
                accountEpoch: self.accountEpoch
            )
            guard let queue = self.queue else {
                guard accountFetch.canApply(
                    to: self.currentUserID,
                    accountEpoch: self.accountEpoch
                ) else { return }
                try await self.auth.signOut()
                guard accountFetch.canApply(
                    to: self.currentUserID,
                    accountEpoch: self.accountEpoch
                ) else { return }
                self.watch.relaySession(nil)
                self.authSession = nil
                self.didBootstrapUserID = nil
                self.resetAccountState()
                self.bootState = .signedOut
                await self.tearDownRealtime()
                return
            }
            let result = await SignOutQueuePolicy.drainBeforeSignOut(
                userId: userID,
                drain: { accountID in
                    await self.drainQueueForSignOut(
                        accountUserID: accountID,
                        capturedBy: accountFetch
                    )
                },
                countRemaining: { accountID in
                    guard accountFetch.canApply(
                        to: self.currentUserID,
                        accountEpoch: self.accountEpoch
                    ) else { return 0 }
                    let count = await queue.count(for: accountID)
                    guard accountFetch.canApply(
                        to: self.currentUserID,
                        accountEpoch: self.accountEpoch
                    ) else { return 0 }
                    return count
                },
                askAboutRemainder: { count in
                    guard accountFetch.canApply(
                        to: self.currentUserID,
                        accountEpoch: self.accountEpoch
                    ) else { return .cancel }
                    return await self.askAboutSignOutRemainder(count: count)
                },
                signOut: {
                    // The user may have been signed out or replaced while
                    // the bounded drain/prompt was suspended. A no-op here
                    // prevents an old sign-out task from signing out the new
                    // account.
                    guard accountFetch.canApply(
                        to: self.currentUserID,
                        accountEpoch: self.accountEpoch
                    ) else { return }
                    try await self.auth.signOut()
                }
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
            // Auth providers may deliver `.signedOut` asynchronously. Clear
            // the visible model immediately after a successful user action,
            // but only if this is still the same account generation; a newer
            // sign-in must never be reset by an older sign-out completion.
            guard accountFetch.canApply(
                to: self.currentUserID,
                accountEpoch: self.accountEpoch
            ) else { return }
            self.watch.relaySession(nil)
            self.authSession = nil
            self.didBootstrapUserID = nil
            self.resetAccountState()
            self.bootState = .signedOut
            await self.tearDownRealtime()
        }
    }

    /// The sign-out drain: attempt EVERYTHING for the account, not just
    /// backoff-due items — the token is about to die, so a backed-off entry
    /// that never got tried would strand for the whole sign-out for no
    /// reason. (Web parity: the web queue has no per-entry backoff, so its
    /// pre-sign-out drain attempts everything.) Counts what actually
    /// uploaded.
    private func drainQueueForSignOut(
        accountUserID: UUID,
        capturedBy accountFetch: AccountScopedFetch
    ) async -> Int {
        guard let queue else { return 0 }
        // #935: `nil` due date = "active, regardless of backoff", and this pass
        // deliberately skips the residue adopters (the token is about to die —
        // the sign-out path's own policy measures what uploaded). Both facts are
        // the recovery owner's; the pass publishes nothing (the caller reports).
        let report = await mutationRecovery.drain(
            boundary: recoveryBoundary(accountFetch),
            mode: .signOut,
            in: queue,
            upload: { item, itemMode in
                await self.upload(
                    item,
                    mode: itemMode,
                    capturedBy: accountFetch
                )
            },
            acknowledge: {}
        )
        return report.uploaded
    }

    public func updatePassword(_ password: String) async {
        guard let userID = currentUserID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        do {
            try await self.auth.updatePassword(password)
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            self.passwordRecovery = false
            self.toastMessage = "Password updated."
        } catch {
            if accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) {
                surface(error)
            }
        }
    }

    /// #722 (parity with web #542): send a password reset email for the
    /// signed-in user's address. The reset link reopens the app via the
    /// custom scheme; `handleDeepLink` routes it to `PasswordRecoveryView`.
    public func sendPasswordResetEmail() async {
        // Read the address before the await (repo closure-capture rule); the
        // signing-in account is the only one a reset should target.
        guard let userID = currentUserID, let email = currentUserEmail else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        do {
            try await self.auth.resetPassword(email: email)
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            self.toastMessage = "Password reset email sent to \(email)."
        } catch {
            if accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) {
                surface(error)
            }
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

    /// Refresh the nonfatal clock advisory from the live auth service. This is
    /// deliberately separate from destructive recovery: a device clock lead
    /// keeps the session and all account state intact while exposing the
    /// stable Settings copy.
    public func updateAuthClockAdvisory(for session: AuthSession? = nil) {
        let session = session ?? authSession
        authClockAdvisoryMessage = session.flatMap {
            auth.clockAdvisoryMessage(for: $0)
        }
    }

    public func becameActive() async {
        // #674 review F7: clear any guided Live Activity stranded by a
        // force-quit / jetsam BEFORE the auth gate — a killed app never ran
        // the in-process teardown, and relaunch is the only chance to retire
        // the card. No-op while a run is in progress.
        guidedActivity.reconcileOrphans()
        manualWorkoutActivity.reconcileOrphans()
        guard let currentSession = authSession else { return }
        updateAuthClockAdvisory(for: currentSession)
        // #921: a foreground pass is a cache-backed entrypoint, so it joins the
        // one preparation flight before any cache read or write. On the normal
        // launch this is already `.ready` and costs nothing; after a failed
        // open it is the retry that lets the cache recover without a relaunch.
        await prepareCacheIfNeeded()
        // A cache-open/read failure deliberately leaves the WC inbox row in
        // place. Retry it on every foreground pass instead of waiting for a
        // relaunch or an account transition.
        await acceptStoredWatchCompletions()
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
            await refreshAllSilently()
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
        // Foreground is also the normal widget freshness boundary. Publish
        // even when the health coalescing gate kept the read; the score is
        // intentionally frozen for the day, while ACWR/phase may have changed.
        publishReadinessWidgetSnapshot()
        // Last on purpose: the drain's "Saved" toasts above must not clobber
        // the loss notice — the user hearing about the lost rep is the point.
        surfaceLostRecordingNoticeIfAny()
    }

    private func handleAuthEvent(_ event: AuthChangeEvent, session: AuthSession?) async {
        switch event {
        case .initialSession, .signedIn, .tokenRefreshed, .userUpdated, .mfaChallengeVerified:
            guard let incomingSession = session else {
                await teardownGuidedProtocolBeforeAuthRevocation()
                watch.relaySession(nil)
                authSession = nil
                didBootstrapUserID = nil
                resetAccountState()
                await awaitSplashPresentationFloor()
                bootState = .signedOut
                await tearDownRealtime()
                return
            }
            let nativeEvent: NativeAuthEvent
            switch event {
            case .initialSession: nativeEvent = .initialSession
            case .signedIn: nativeEvent = .signedIn
            case .tokenRefreshed: nativeEvent = .tokenRefreshed
            case .userUpdated, .mfaChallengeVerified: nativeEvent = .userUpdated
            default: nativeEvent = .userUpdated
            }
            let session: AuthSession
            do {
                session = try await auth.prepareIncomingSession(
                    incomingSession,
                    event: nativeEvent
                )
            } catch {
                await handleAuthSessionFailure(error)
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
            // #936: captured BEFORE the incoming session replaces it. The
            // account boundary below names the account that owned any
            // in-progress manual workout, so the teardown can never take out a
            // workout that already belongs to the incoming account.
            let outgoingUserID = authSession?.user.id
            async let splashFloor: Void = awaitSplashPresentationFloor()
            if changedUser {
                await teardownGuidedProtocolBeforeAuthRevocation()
            }
            authSession = session
            watch.relaySession(session)
            if changedUser || didBootstrapUserID != session.user.id {
                // #936: the outgoing account's manual workout is torn down
                // under the account that owned it, while the boundary still
                // names it — a stale boundary can never take out a workout that
                // already belongs to the incoming account.
                applyManualWorkoutLifecycle(
                    manualWorkoutLifecycle.accountChanged(
                        previousAccountUserID: outgoingUserID
                    )
                )
                resetAccountState()
                restoreHealthSyncState(for: session.user.id)
                // Claim the same refresh owner that the bootstrap refresh will
                // finish. Otherwise the watch inbox adoption can suspend with
                // an ownerless loading latch between signed-in and refresh.
                let bootstrapRefreshOwner = beginDataRefresh()
                // #921: the cache is opened off the launch path, so the
                // account bootstrap joins the one preparation flight before
                // the first cache-backed adoption. The join SUSPENDS the main
                // actor (it never blocks it), and the splash floor claimed
                // above still holds the first frame: a delayed store moves
                // when this bootstrap finishes, not when the app can draw.
                await prepareCacheIfNeeded()
                // Adopt persisted watch summaries before any network await so
                // a relaunch with a delayed Supabase path still renders the
                // completion in History immediately.
                await acceptStoredWatchCompletions()
                await refreshAll(
                    showSpinner: true,
                    dataRefreshOwner: bootstrapRefreshOwner
                )
                // #712: load the passkey list for the (newly) signed-in user.
                await loadPasskeys()
                didBootstrapUserID = session.user.id
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
            } else {
                switch event {
                case .signedIn, .tokenRefreshed:
                    // A re-authentication can keep the same user id and
                    // therefore skip the cold bootstrap branch. It is still
                    // the recovery boundary for queue entries parked on an
                    // expired token, so force an account-scoped pass with the
                    // newly valid session. Recovery bypasses backoff but does
                    // not re-arm quarantined payloads.
                    await drainQueue(mode: .authRecovery)
                default:
                    break
                }
            }
            await splashFloor
            bootState = .signedIn
            updateAuthClockAdvisory(for: session)
        case .passwordRecovery:
            let preparedSession: AuthSession?
            if let session {
                do {
                    preparedSession = try await auth.prepareIncomingSession(
                        session,
                        event: .passwordRecovery
                    )
                } catch {
                    await handleAuthSessionFailure(error)
                    return
                }
            } else {
                preparedSession = nil
            }
            let currentRecoveryUserID = authSession?.user.id
            let nextRecoveryUserID = preparedSession?.user.id
            let accountChanged = currentRecoveryUserID != nextRecoveryUserID
            if accountChanged || preparedSession == nil {
                await teardownGuidedProtocolBeforeAuthRevocation()
            }
            authSession = preparedSession
            passwordRecovery = true
            await awaitSplashPresentationFloor()
            bootState = preparedSession == nil ? .signedOut : .signedIn
            if accountChanged || preparedSession == nil {
                // Password-recovery callbacks can carry a different session
                // (or nil) without a preceding signedIn/signedOut event.
                // Treat that callback as the same account boundary: advance
                // the epoch, clear visible state, scope the watch, and tear
                // down the old realtime channel before any recovery UI work.
                watch.relaySession(preparedSession)
                didBootstrapUserID = nil
                // #936: the recovery callback is an account boundary too — name
                // the outgoing account so its manual workout is torn down under
                // the account that owned it.
                applyManualWorkoutLifecycle(
                    manualWorkoutLifecycle.accountChanged(
                        previousAccountUserID: accountChanged ? currentRecoveryUserID : nil
                    )
                )
                resetAccountState()
                if let preparedSession {
                    restoreHealthSyncState(for: preparedSession.user.id)
                }
                await tearDownRealtime()
            } else if preparedSession != nil {
                // Some password-recovery flows deliver the replacement token
                // as `.passwordRecovery` without a second `.signedIn` event.
                // The same-account token is still a recovery boundary.
                await drainQueue(mode: .authRecovery)
            }
            updateAuthClockAdvisory(for: preparedSession)
        case .signedOut, .userDeleted:
            await teardownGuidedProtocolBeforeAuthRevocation()
            // #679: sign-out boundary.
            let hadActiveAccount = authSession != nil || bootState != .signedOut
            // A local recovery can clear the model before the SDK delivers its
            // buffered `.signedOut` callback. Do not emit a second boundary
            // diagnostic for that callback; ordinary account deletion remains
            // observable even if the model was already empty.
            if AuthRecoveryEpochPolicy.shouldRecordBoundaryDiagnostic(
                isAccountDeletion: event == .userDeleted,
                hasActiveSession: hadActiveAccount
            ) {
                auth.recordAuthEvent(
                    .signOut,
                    detail: event == .signedOut ? "Signed out" : "Account deleted"
                )
            }
            watch.relaySession(nil)
            authSession = nil
            didBootstrapUserID = nil
            if AuthRecoveryEpochPolicy.shouldResetForSignedOut(
                hasActiveSession: hadActiveAccount
            ) {
                resetAccountState()
            }
            bootState = .signedOut
            await tearDownRealtime()
        }
    }

    /// Auth self-healing is a normal signed-out boundary: clear the visible
    /// model and advance the account epoch, but preserve the exact account's
    /// valid cache/queue for a later fresh sign-in. The AuthService has already
    /// removed a poisoned SDK session locally before this helper is reached.
    private func handleAuthSessionFailure(_ error: Error) async {
        let hasActiveSession = authSession != nil || bootState != .signedOut
        guard AuthRecoveryEpochPolicy.shouldBegin(
            hasActiveSession: hasActiveSession,
            recoveryInProgress: authRecoveryInProgress
        ) else {
            surface(error)
            return
        }
        authRecoveryInProgress = true
        defer { authRecoveryInProgress = false }
        await teardownGuidedProtocolBeforeAuthRevocation()
        // The local sign-out may have emitted `.signedOut` while the teardown
        // above was suspended. Re-check the live actor state before applying
        // the boundary; captured pre-await state is not a guard.
        guard AuthRecoveryEpochPolicy.shouldBegin(
            hasActiveSession: authSession != nil || bootState != .signedOut,
            recoveryInProgress: false
        ) else {
            surface(error)
            return
        }
        watch.relaySession(nil)
        authSession = nil
        didBootstrapUserID = nil
        resetAccountState()
        bootState = .signedOut
        await tearDownRealtime()
        surface(error)
    }

    private func relayValidSessionToWatch(guaranteed: Bool) async {
        // #679: route the watch relay through the single session-freshness
        // guard so a stale relayed token is never handed to the companion.
        guard let userID = currentUserID else {
            watch.relaySession(nil, guaranteed: guaranteed)
            return
        }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        do {
            let valid = try await self.auth.ensureFreshSession()
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ), valid.user.id == userID else { return }
            authSession = valid
            updateAuthClockAdvisory(for: valid)
            watch.setAccountScope(userID)
            watch.relaySession(valid, guaranteed: guaranteed)
        } catch {
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            if error is AuthRecoveryError {
                await handleAuthSessionFailure(error)
                return
            }
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
    ///
    /// #922 (#295/#296 captured state): calling this performs the read on the
    /// storage side, so the account/epoch captured BEFORE that await is
    /// re-checked before a single value is published. A hydration that loses
    /// its account (switch, sign-out, cancellation) publishes nothing —
    /// another account's cache rows can never reach the model.
    ///
    /// The returned read is the hydrated revision itself, so the caller's fetch
    /// plan (cursors) and its publication (collections, pending counts) are
    /// derived from the same point in time instead of re-querying the cache.
    @discardableResult
    private func hydrateCachedWorkspace(
        accountUserID: UUID,
        capturedBy accountFetch: AccountScopedFetch
    ) async -> LocalCacheSnapshotRead? {
        guard let read = await readCoherentCache(accountUserID: accountUserID) else {
            return nil
        }
        guard !Task.isCancelled else { return nil }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return nil }
        let snapshot = read.snapshot
        let sessionsWereSynced = read.hasCompletedSync(.sessions)
        let recordingsWereSynced = read.hasCompletedSync(.recordings)
        sessions = snapshot.sessions
        // Opening/creating SQLite is not a server boundary. Only a
        // persisted cursor or explicit successful-empty marker can make a
        // cached empty list authoritative after a failed refresh.
        hasLoadedSessions = hasLoadedSessions || sessionsWereSynced
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
        let pendingRecordingIDs = read.pendingEntityIDs(.recordings)
        pendingRecordings = PendingRecordingOverlay()
        let recordingsByID = Dictionary(
            uniqueKeysWithValues: snapshot.recordings.map { ($0.id, $0) }
        )
        for pendingID in pendingRecordingIDs {
            guard let id = UUID(uuidString: pendingID),
                  let recording = recordingsByID[id] else { continue }
            pendingRecordings.insert(recording, accountUserID: accountUserID)
        }
        hasLoadedRecordings = hasLoadedRecordings || recordingsWereSynced
        forceModel.hasLoadedRecordings = hasLoadedRecordings
        publishForceProgressInputMutation(.recordings)
        publishPendingCacheWriteCounts(from: read, accountUserID: accountUserID)
        return read
    }

    /// Applies one entity refresh to the cache: a full snapshot on first sync
    /// or after a cursor reset, or a cursor-bounded delta otherwise.
    ///
    /// #934: the rule (and the storage hop) now live in
    /// `WorkspaceSyncCoordinator.reconcileEntity`; this call site supplies the
    /// account's one open store handle and the diagnostics sink. The caller
    /// still re-checks its account/epoch capture after the await.
    private func reconcileEntityRefresh<T: Encodable & Sendable>(
        _ delta: RemoteEntityDelta<T>,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        fullSnapshot: CachedWorkspaceSnapshot?,
        purgeGeneration: Int64? = nil
    ) async {
        guard let workspace = cachedWorkspace else { return }
        await workspaceSync.reconcileEntity(
            in: workspace,
            delta,
            accountUserID: accountUserID,
            entityType: entityType,
            fullSnapshot: fullSnapshot,
            purgeGeneration: purgeGeneration,
            onFailure: recordCacheFailure
        )
    }

    /// #934: the cursor read (and its off-main-actor hop) is the coordinator's;
    /// this call site supplies the account's open store handle.
    private func cacheCursor(
        accountUserID: UUID,
        entityType: LocalCacheEntityType
    ) async -> String? {
        guard let workspace = cachedWorkspace else { return nil }
        return await workspaceSync.cursor(
            in: workspace,
            accountUserID: accountUserID,
            entityType: entityType,
            onFailure: recordCacheFailure
        )
    }

    /// Hard purges leave no row for an `updated_at > cursor` delta to return.
    /// The server generation is account-scoped; a mismatch or unavailable
    /// generation forces both Trash-backed entities through full authoritative
    /// reconciliation while retaining pending-local-write precedence.
    ///
    /// #934: the paired two-entity decision (and its fail-closed read) is the
    /// coordinator's; this call site supplies the account's open store handle.
    private func cacheNeedsPurgeReconcile(
        accountUserID: UUID,
        remoteGeneration: Int64?
    ) async -> Bool {
        guard let workspace = cachedWorkspace else { return true }
        return await workspaceSync.needsPurgeReconcile(
            in: workspace,
            accountUserID: accountUserID,
            remoteGeneration: remoteGeneration,
            onFailure: recordCacheFailure
        )
    }

    /// Re-adopts the reconciled cache values for the collections that do not
    /// carry their own in-memory optimistic overlays.
    ///
    /// Sessions and recordings deliberately stay on `mergeSessions` /
    /// `mergeRecordings`, which also restore RPE/editor overlays and durable
    /// queue rows. The remaining entities only have the cache as their durable
    /// local row, so this is the final authority after an authoritative refresh.
    ///
    /// #922: it publishes from an ALREADY-READ revision. It used to perform its
    /// own full-workspace load, which is how one refresh ended up loading the
    /// whole workspace several times just to republish subsets.
    private func applyCachedNonOverlayLists(
        accountUserID: UUID,
        read: LocalCacheSnapshotRead?
    ) {
        guard let read else { return }
        if let cachedSettings = read.snapshot.settings {
            settings = cachedSettings
        }
        phasePeriods = read.snapshot.phasePeriods
        healthMetrics = read.snapshot.healthMetrics
        presets = read.snapshot.presets
        routines = read.snapshot.routines
        workouts = read.snapshot.workouts
        tagMetadata = read.snapshot.tagMetadata
        publishPendingCacheWriteCounts(from: read, accountUserID: accountUserID)
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
        confirmingLocalRevision: Int? = nil,
        publishPendingCount: Bool = true
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
            if publishPendingCount,
               CachedWorkspace.directWriteEntityTypes.contains(entityType) {
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
        case let .sessionMerge(mergePayload):
            // The survivor takes the merged row; every merged-away session
            // gets its local tombstone confirmed.
            var identities = [mergePayload.survivorID]
            identities.append(
                contentsOf: mergePayload.mergedSessionIDs.filter {
                    $0 != mergePayload.survivorID
                }
            )
            return identities.map {
                CacheEntityIdentity(
                    entityType: .sessions,
                    entityID: $0.uuidString
                )
            }
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
        case let .preset(intent):
            return [
                CacheEntityIdentity(
                    entityType: .presets,
                    entityID: intent.entityID
                )
            ]
        case let .routine(intent):
            return [
                CacheEntityIdentity(
                    entityType: .routinePresets,
                    entityID: intent.entityID
                )
            ]
        case .phaseTransition:
            // A transition writes TWO entity types and its periods include
            // identities it did not name (the server mints a created period's
            // id). The revisions are therefore read from the account cache
            // itself at capture time — see `cacheConfirmationRevisions`.
            return []
        case let .tagMutation(intent):
            // The tag NAME is the registry row's cache identity (both the name
            // a rename retires and the one it leaves behind), and the repointed
            // recordings carry their own ids. Capturing all of them before the
            // first network await is what keeps an older acknowledgement from
            // clearing a newer local revision of any of them.
            var names = [intent.finalName]
            names.append(contentsOf: intent.knownNames.sorted())
            var targets = names.map {
                CacheEntityIdentity(entityType: .tagMetadata, entityID: $0)
            }
            targets.append(contentsOf: intent.recordingIDs.map {
                CacheEntityIdentity(entityType: .recordings, entityID: $0.uuidString)
            })
            return targets
        case let .healthWrite(intent):
            // #919: the row's cache identity is its date, and that is exactly
            // the identity an acknowledgement has to clear. Capturing the
            // revision before the first network await is what keeps an older
            // recovery's answer from clearing (or re-publishing) a newer local
            // pass for the same date.
            return [
                CacheEntityIdentity(
                    entityType: .healthMetrics,
                    entityID: intent.date
                )
            ]
        }
    }

    private func cacheConfirmationRevisions(
        for payload: PendingWrite,
        accountUserID: UUID
    ) -> [CacheEntityIdentity: Int] {
        guard let cachedWorkspace else { return [:] }
        if case .phaseTransition = payload {
            return phaseTransitionRevisions(accountUserID: accountUserID)
        }
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

    /// The local revisions of every pending settings/phase row, captured before
    /// a phase transition's first network await (and re-read by the
    /// confirmation to check the same rows).
    ///
    /// The two entity types have exactly one writer (`switchPhase`), so the
    /// pending rows ARE the transition's optimistic state. A row that appears
    /// after this snapshot was written by a newer local transition: it is not
    /// in the captured map, so this (older) acknowledgement can never clear it.
    private func phaseTransitionRevisions(
        accountUserID: UUID
    ) -> [CacheEntityIdentity: Int] {
        guard let cachedWorkspace else { return [:] }
        var revisions: [CacheEntityIdentity: Int] = [:]
        for entityType in [LocalCacheEntityType.settings, .phasePeriods] {
            let entityIDs = (try? cachedWorkspace.pendingEntityIDs(
                accountUserID: accountUserID,
                entityType: entityType,
                includingDeleted: true
            )) ?? []
            for entityID in entityIDs {
                let identity = CacheEntityIdentity(
                    entityType: entityType,
                    entityID: entityID
                )
                if let revision = try? cachedWorkspace.localRevision(
                    accountUserID: accountUserID,
                    entityType: entityType,
                    entityID: entityID
                ) {
                    revisions[identity] = revision
                }
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

    // MARK: Cache preparation (#921)

    /// Joins the one local-cache preparation flight and publishes its outcome.
    ///
    /// Every cache-backed lifecycle entrypoint calls this: the auth bootstrap,
    /// the foreground pass and a background app-refresh. After a successful
    /// preparation it is a no-op, and while the flight is running a caller
    /// SUSPENDS on it — the main actor is never blocked, and the store is
    /// never opened twice.
    func prepareCacheIfNeeded() async {
        guard !cacheReadiness.isReady else { return }
        let preparation = cachePreparation
        let directory = cacheDirectory
        let seams = cacheStorageSeams
        let result = await preparation.preparedCache(directory: directory, seams: seams)
        applyPreparedCache(result)
    }

    /// #921: how many times the storage opener has actually run. Two
    /// entrypoints that arrive together leave this at one.
    public func cacheOpenAttempts() async -> Int {
        await cachePreparation.openAttempts
    }

    /// #922: how many full-workspace cache reads this app's store handle has
    /// issued. One refresh is exactly two of them (the hydration read and the
    /// post-reconcile publication read) — the number a read-count test pins.
    public var cacheSnapshotReadCount: Int {
        cachedWorkspace?.store.snapshotReadCount ?? 0
    }

    /// #922: whether the most recent full-workspace read ran on the main
    /// thread. `nil` before the first read. This is the assertion that keeps
    /// "the read is off the main actor" from depending on a timing.
    public var lastCacheSnapshotReadOnMainThread: Bool? {
        cachedWorkspace?.store.lastSnapshotReadOnMainThread
    }

    private func applyPreparedCache(
        _ result: Result<PreparedLocalCache, CacheUnavailableReason>
    ) {
        switch result {
        case .success(let prepared):
            if cachedWorkspace == nil {
                cachedWorkspace = prepared.workspace
            }
            cacheReadiness = .ready
            // A cache that recovered may report its own (later) failure again.
            cacheOpenFailureReported = false
        case .failure(let reason):
            // Honest and recoverable: the app keeps running network-only, the
            // failure is visible in the diagnostics ring, and the NEXT
            // lifecycle entrypoint retries the flight (`CachePreparation`
            // drops a failed flight). Nothing here claims local persistence.
            cacheReadiness = .unavailable(reason)
            reportCacheUnavailable(reason)
        }
    }

    /// #921: one diagnostics-ring entry per failed preparation, in the same
    /// shape the pre-#921 inline open used.
    private func reportCacheUnavailable(_ reason: CacheUnavailableReason) {
        guard !cacheOpenFailureReported else { return }
        cacheOpenFailureReported = true
        auth.recordAuthEvent(
            .failure,
            detail: "Local cache unavailable: \(reason.detail)"
        )
    }

    private func recordCacheFailure(_ operation: String, _ error: Error) {
        guard !cacheOpenFailureReported else { return }
        cacheOpenFailureReported = true
        auth.recordAuthEvent(
            .failure,
            detail: "Local cache \(operation): \(error.localizedDescription)"
        )
    }

    /// #922: both published pending counts from ONE query, and both off the
    /// render path. Every cache confirm/write and every publish calls this, so
    /// no view body reads the store (see `pendingTagWriteCount`).
    private func refreshPendingCacheWriteCount(accountUserID: UUID) {
        guard let cachedWorkspace else { return }
        do {
            let counts = try cachedWorkspace.pendingDirectWriteCounts(
                accountUserID: accountUserID
            )
            pendingCacheWriteCount = counts.total
            pendingTagWriteCount = counts.tagMetadata
        } catch {
            recordCacheFailure("cache pending count", error)
        }
    }

    /// #922: the same two counts, from an already-read coherent revision —
    /// no extra query at a boundary that just performed one.
    private func publishPendingCacheWriteCounts(
        from read: LocalCacheSnapshotRead,
        accountUserID: UUID
    ) {
        pendingCacheWriteCount = read.pendingDirectWriteCount
        pendingTagWriteCount = read.pendingEntityIDs(
            .tagMetadata,
            includingDeleted: true
        ).count
    }

    /// #934: the coherent-read rule — the #922 storage-side hop, the injectable
    /// before-read gate and the off-main-actor guarantee — lives in the
    /// coordinator. This call site supplies the account's open store handle, so
    /// the read count stays one observable number
    /// (`cachedWorkspace?.store.snapshotReadCount`).
    private func readCoherentCache(accountUserID: UUID) async -> LocalCacheSnapshotRead? {
        guard let workspace = cachedWorkspace else { return nil }
        return await workspaceSync.readCoherentCache(
            in: workspace,
            accountUserID: accountUserID,
            onFailure: recordCacheFailure
        )
    }

    private func beginDataRefresh() -> UUID {
        let owner = UUID()
        dataRefreshOwners.insert(owner)
        isLoadingData = true
        return owner
    }

    private func endDataRefresh(_ owner: UUID) {
        dataRefreshOwners.remove(owner)
        isLoadingData = !dataRefreshOwners.isEmpty
    }

    /// Keep the cold AppModel boundary and the Force-only progress boundary in
    /// lockstep at a successful cache/network publication. History reads the
    /// former; Force surfaces read the latter.
    private func markRecordingsLoaded() {
        hasLoadedRecordings = true
        forceModel.hasLoadedRecordings = true
    }

    // MARK: Loading

    /// #923: the outcome of one slice fetch. The error travels as data so an
    /// independent entity's failure cannot cancel a sibling slice, and so a
    /// cancellation stays distinguishable from a failure.
    private struct SliceFetch<Value> {
        let value: Value?
        let error: Error?

        static func success(_ value: Value) -> SliceFetch<Value> {
            SliceFetch(value: value, error: nil)
        }

        static func failure(_ error: Error) -> SliceFetch<Value> {
            SliceFetch(value: nil, error: error)
        }
    }

    private func fetchSlice<Value>(
        _ operation: () async throws -> Value
    ) async -> SliceFetch<Value> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    /// The settings slice (#747). The whole first-sync create-default path is
    /// part of the slice, not a step after it: it writes `user_settings` and
    /// re-reads the stamped timestamp, so a failure anywhere in it must keep
    /// the settings/phase group's last-good rows rather than publish half of
    /// the pair (#923 AC2).
    private func fetchSettingsSlice(
        userID: UUID,
        cursor: String?,
        today: String
    ) async throws -> RemoteEntityDelta<UserSettings> {
        let fetched = try await repository.fetchSettingsDelta(since: cursor)
        guard cursor == nil, fetched.activeValues.isEmpty else { return fetched }
        // First sync with no settings row: keep the historical create-default
        // behavior, then read the stamped timestamp so the next refresh can go
        // incremental.
        _ = try await repository.fetchSettings(userID: userID, today: today)
        let afterUpsert = try await repository.fetchSettingsDelta(since: nil)
        guard afterUpsert.activeValues.isEmpty else { return afterUpsert }
        return RemoteEntityDelta(
            changes: [],
            activeValues: [UserSettings(currentPhase: .capacity, phaseStartDate: today)],
            cursor: nil
        )
    }

    /// #923: a pass that reconciled some groups and failed others. It records
    /// the scoped failure an explicit refresh can retry, keeps auth recovery on
    /// every rejected slice, and escalates to the global banner only when
    /// nothing published and the #842 matrix allows it.
    private func recordPartialRefresh(
        outcomes: RefreshSliceOutcomes,
        failures: [RefreshSlice: Error],
        source: ErrorSurfaceSource,
        capturedBy accountFetch: AccountScopedFetch
    ) {
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return }
        let orderedFailures = outcomes.failedSlicesInOrder.compactMap { slice in
            failures[slice].map { (slice, $0) }
        }
        guard let representative = orderedFailures.first else { return }
        let representativeSlice = representative.0
        let representativeError = representative.1
        // #964: the account's last load failure, recorded even when the banner
        // is suppressed so the Dashboard can still explain an empty screen.
        dashboardLoadFailureClass = UserFacingError.classification(for: representativeError)
        let willSurface = errorSurfacePolicy.shouldSurface(
            source: source,
            hasLastGoodData: hasLoadedSessions && forceModel.hasLoadedRecordings,
            publishedAnySlice: outcomes.didPublishAnyGroup
        )
        if willSurface {
            surface(representativeError)
        }
        // #923 AC4: a rejected bearer heals whether or not its slice produced
        // the banner — a suppressed or non-representative 401 must not leave
        // the session poisoned (#842's rule, applied per slice). `surface(_:)`
        // already ran the recovery for the representative error.
        for (slice, error) in orderedFailures
        where !(willSurface && slice == representativeSlice) {
            recoverAuthFrom(error)
        }
        let summary = RefreshFailureSummary(
            accountUserID: accountFetch.accountUserID,
            groups: outcomes.failedGroups,
            reason: UserFacingError.message(for: representativeError),
            source: source,
            occurredAt: Date()
        )
        _ = accountFetch.publishIfCurrent(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) {
            lastPartialRefreshFailure = summary
        }
    }

    public func refreshAll(showSpinner: Bool = true) async {
        await refreshAll(
            showSpinner: showSpinner,
            dataRefreshOwner: nil,
            purgeGenerationContext: .userInitiatedForeground
        )
    }

    private func refreshAll(
        showSpinner: Bool,
        dataRefreshOwner: UUID?,
        purgeGenerationContext: PurgeGenerationRefreshContext = .silent,
        errorSurfaceSource: ErrorSurfaceSource = .userInitiated
    ) async {
        let dataRefreshOwner = dataRefreshOwner ?? beginDataRefresh()
        defer { endDataRefresh(dataRefreshOwner) }
        guard let userID = currentUserID else { return }
        // #921: the store is opened off the launch path, so the local snapshot
        // read joins the one preparation flight first. A caller that arrives
        // while the flight runs suspends here; a cache that cannot be opened
        // leaves `cachedWorkspace` nil and this pass continues network-only.
        await prepareCacheIfNeeded()
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
        // Cold-start / account-switch path: render the account's local
        // snapshot before any network request starts. The returned read is
        // this pass's hydration revision: its cursors plan the fetch below and
        // its collections are what a failed pass republishes.
        let hydrated = await hydrateCachedWorkspace(
            accountUserID: userID,
            capturedBy: accountFetch
        )
        // #922: the most recent coherent revision this pass read. A failure
        // republishes THIS instead of loading the workspace a third time.
        var latestCacheRead: LocalCacheSnapshotRead? = hydrated
        do {
            // #934: the optional generation endpoint and its "a missing
            // generation makes both purge-sensitive entities authoritative"
            // fallback are one rule, owned by the coordinator. The endpoint may
            // lag a staged/older project schema: keep the ordinary refresh
            // alive, report the rollout error through the existing
            // foreground-only policy, and let the plan below force both
            // affected entities through a full reconcile until it recovers.
            let purgeResolution = await workspaceSync.resolvePurgeGeneration {
                try await self.repository.fetchPurgeSyncGeneration()
            }
            if let endpointFailure = purgeResolution.endpointFailure {
                reportPurgeGenerationFailure(
                    endpointFailure,
                    context: purgeGenerationContext,
                    capturedBy: accountFetch
                )
            } else {
                markPurgeGenerationAvailable(capturedBy: accountFetch)
            }
            let remotePurgeGeneration: Int64? = purgeResolution.generation
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            // #922: the purge decision stays a targeted post-fetch check (the
            // generation arrives after the hydration read), but the cursors
            // come from the hydrated revision itself, so the delta this pass
            // fetches is planned against exactly the rows it hydrated.
            let forcePurgeReconcile = await cacheNeedsPurgeReconcile(
                accountUserID: userID,
                remoteGeneration: remotePurgeGeneration
            )
            // #934: the plan — which cursor each entity is fetched with, and
            // which two entities the purge mismatch forces through a full
            // authoritative reconcile — is the coordinator's rule. This call
            // site only reads it.
            let plan = workspaceSync.plan(
                hydrated: hydrated,
                forceFullReconcile: forcePurgeReconcile
            )
            let sessionCursor = plan.cursor(for: .sessions)
            let settingsCursor = plan.cursor(for: .settings)
            let phaseCursor = plan.cursor(for: .phasePeriods)
            let healthCursor = plan.cursor(for: .healthMetrics)
            let recordingCursor = plan.cursor(for: .recordings)
            let presetCursor = plan.cursor(for: .presets)
            let routineCursor = plan.cursor(for: .routinePresets)
            let workoutCursor = plan.cursor(for: .workoutsAndAttempts)
            let tagCursor = plan.cursor(for: .tagMetadata)
            let today = LocalDateSupport.string(from: Date())
            // #923: each slice captures its own outcome instead of throwing
            // into the shared pass. `try await`-ing them in sequence is
            // exactly how an unrelated entity's failure used to cancel a
            // sibling page that had already come back.
            async let sessionsFetch = fetchSlice {
                try await repository.fetchSessionDelta(
                    since: sessionCursor,
                    accountUserID: userID
                )
            }
            async let settingsFetch = fetchSlice {
                try await fetchSettingsSlice(
                    userID: userID,
                    cursor: settingsCursor,
                    today: today
                )
            }
            async let periodsFetch = fetchSlice {
                try await repository.fetchPhasePeriodDelta(since: phaseCursor)
            }
            async let healthFetch = fetchSlice {
                try await repository.fetchHealthMetricDelta(since: healthCursor)
            }
            async let recordingsFetch = fetchSlice {
                try await repository.fetchRecordingDelta(since: recordingCursor)
            }
            async let presetsFetch = fetchSlice {
                try await repository.fetchPresetDelta(since: presetCursor)
            }
            async let routinesFetch = fetchSlice {
                try await repository.fetchRoutineDelta(since: routineCursor)
            }
            async let workoutsFetch = fetchSlice {
                try await repository.fetchWorkoutDelta(since: workoutCursor)
            }
            async let tagsFetch = fetchSlice {
                try await repository.fetchTagMetadataDelta(since: tagCursor)
            }

            let sessionsSlice = await sessionsFetch
            let settingsSlice = await settingsFetch
            let periodsSlice = await periodsFetch
            let healthSlice = await healthFetch
            let recordingsSlice = await recordingsFetch
            let presetsSlice = await presetsFetch
            let routinesSlice = await routinesFetch
            let workoutsSlice = await workoutsFetch
            let tagsSlice = await tagsFetch

            let sliceResults: [(slice: RefreshSlice, error: Error?)] = [
                (slice: .sessions, error: sessionsSlice.error),
                (slice: .recordings, error: recordingsSlice.error),
                (slice: .settings, error: settingsSlice.error),
                (slice: .phasePeriods, error: periodsSlice.error),
                (slice: .healthMetrics, error: healthSlice.error),
                (slice: .presets, error: presetsSlice.error),
                (slice: .routinePresets, error: routinesSlice.error),
                (slice: .workoutsAndAttempts, error: workoutsSlice.error),
                (slice: .tagMetadata, error: tagsSlice.error),
            ]
            // #934: the collection rule — a cancelled pass is not a verdict: it
            // publishes nothing, advances no cursor and reports no failure — is
            // the coordinator's. The caller's own cancellation state is an
            // explicit input here, never something the coordinator infers from
            // a swallowed error.
            let collected = workspaceSync.collectOutcomes(
                sliceResults,
                isCancelled: Task.isCancelled
            )
            let outcomes = collected.outcomes
            let sliceFailures = collected.failures
            if outcomes.wasCancelled { return }
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }

            // #923 AC1/AC2: apply only the groups whose every slice fetched
            // successfully. A failed slice keeps its last-good cache rows
            // (its reconcile never runs, so nothing is overwritten), and a
            // broken pair is not applied at all — a partially authoritative
            // group is never exposed.
            if outcomes.publishes(.sessionsAndRecordings),
               let fetchedSessions = sessionsSlice.value,
               let fetchedRecordings = recordingsSlice.value {
                await reconcileEntityRefresh(
                    fetchedSessions,
                    accountUserID: userID,
                    entityType: .sessions,
                    fullSnapshot: sessionCursor == nil
                        ? CachedWorkspaceSnapshot(sessions: fetchedSessions.activeValues)
                        : nil,
                    purgeGeneration: remotePurgeGeneration
                )
                await reconcileEntityRefresh(
                    fetchedRecordings,
                    accountUserID: userID,
                    entityType: .recordings,
                    fullSnapshot: recordingCursor == nil
                        ? CachedWorkspaceSnapshot(recordings: fetchedRecordings.activeValues)
                        : nil,
                    purgeGeneration: remotePurgeGeneration
                )
            }
            if outcomes.publishes(.settingsAndPhase),
               let fetchedSettings = settingsSlice.value,
               let fetchedPeriods = periodsSlice.value {
                await reconcileEntityRefresh(
                    fetchedSettings,
                    accountUserID: userID,
                    entityType: .settings,
                    fullSnapshot: settingsCursor == nil
                        ? CachedWorkspaceSnapshot(settings: fetchedSettings.activeValues.first)
                        : nil
                )
                await reconcileEntityRefresh(
                    fetchedPeriods,
                    accountUserID: userID,
                    entityType: .phasePeriods,
                    fullSnapshot: phaseCursor == nil
                        ? CachedWorkspaceSnapshot(phasePeriods: fetchedPeriods.activeValues)
                        : nil
                )
            }
            if outcomes.publishes(.healthMetrics),
               let fetchedHealth = healthSlice.value {
                await reconcileEntityRefresh(
                    fetchedHealth,
                    accountUserID: userID,
                    entityType: .healthMetrics,
                    fullSnapshot: healthCursor == nil
                        ? CachedWorkspaceSnapshot(healthMetrics: fetchedHealth.activeValues)
                        : nil
                )
            }
            if outcomes.publishes(.presets),
               let fetchedPresets = presetsSlice.value {
                await reconcileEntityRefresh(
                    fetchedPresets,
                    accountUserID: userID,
                    entityType: .presets,
                    fullSnapshot: presetCursor == nil
                        ? CachedWorkspaceSnapshot(presets: fetchedPresets.activeValues)
                        : nil
                )
            }
            if outcomes.publishes(.routinePresets),
               let fetchedRoutines = routinesSlice.value {
                await reconcileEntityRefresh(
                    fetchedRoutines,
                    accountUserID: userID,
                    entityType: .routinePresets,
                    fullSnapshot: routineCursor == nil
                        ? CachedWorkspaceSnapshot(routines: fetchedRoutines.activeValues)
                        : nil
                )
            }
            if outcomes.publishes(.workoutsAndAttempts),
               let fetchedWorkouts = workoutsSlice.value {
                await reconcileEntityRefresh(
                    fetchedWorkouts,
                    accountUserID: userID,
                    entityType: .workoutsAndAttempts,
                    fullSnapshot: workoutCursor == nil
                        ? CachedWorkspaceSnapshot(workouts: fetchedWorkouts.activeValues)
                        : nil
                )
            }
            if outcomes.publishes(.tagMetadata),
               let fetchedTags = tagsSlice.value {
                await reconcileEntityRefresh(
                    fetchedTags,
                    accountUserID: userID,
                    entityType: .tagMetadata,
                    fullSnapshot: tagCursor == nil
                        ? CachedWorkspaceSnapshot(tagMetadata: fetchedTags.activeValues)
                        : nil
                )
            }

            // #922: the restore's "already on the server" identity is the
            // POST-reconcile active set, derived from this pass's own reads —
            // no third full-workspace load. A row the reconcile tombstoned must
            // NOT be in it: its durable queue overlay is exactly what has to be
            // restored, and suppressing that restore is how a locally saved row
            // that the server's authoritative snapshot does not carry would
            // disappear from the published list.
            let hydratedSessions = hydrated?.snapshot.sessions ?? []
            let hydratedRecordings = hydrated?.snapshot.recordings ?? []
            let fetchedSessions = sessionsSlice.value?.activeValues ?? []
            let fetchedRecordings = recordingsSlice.value?.activeValues ?? []
            let pendingSessionIDs = Set(
                (hydrated?.pendingRows ?? [])
                    .filter { $0.entityType == .sessions }
                    .compactMap { UUID(uuidString: $0.entityID) }
            )
            let pendingRecordingIDs = Set(
                (hydrated?.pendingRows ?? [])
                    .filter { $0.entityType == .recordings }
                    .compactMap { UUID(uuidString: $0.entityID) }
            )
            let fetchedSessionIDs = Set(fetchedSessions.map(\.id))
            let fetchedRecordingIDs = Set(fetchedRecordings.map(\.id))
            // A cache row the server snapshot did not carry and that is not a
            // pending local write is tombstoned by the reconcile — the same
            // rule `CachedWorkspace.reconcile` applies.
            let tombstonedSessionIDs = Set(
                hydratedSessions.map(\.id).filter {
                    !fetchedSessionIDs.contains($0) && !pendingSessionIDs.contains($0)
                }
            )
            let tombstonedRecordingIDs = Set(
                hydratedRecordings.map(\.id).filter {
                    !fetchedRecordingIDs.contains($0) && !pendingRecordingIDs.contains($0)
                }
            )
            let publishedSessionIDs = Set(hydratedSessions.map(\.id))
                .subtracting(tombstonedSessionIDs)
                .union(fetchedSessionIDs)
            let publishedRecordingIDs = Set(hydratedRecordings.map(\.id))
                .subtracting(tombstonedRecordingIDs)
                .union(fetchedRecordingIDs)
            await restorePendingWrites(
                accountFetch: accountFetch,
                userID: userID,
                remoteSessionIDs: publishedSessionIDs,
                remoteRecordingIDs: publishedRecordingIDs
            )
            // #922: the publication reads the workspace ONCE, immediately
            // before the synchronous publication closure. That ordering is
            // load-bearing: an optimistic local write that landed while this
            // pass was suspended in `restorePendingWrites` must be part of the
            // revision that publishes, and must never be overwritten by an
            // older one. Together with the hydration read, one refresh is
            // exactly TWO full-workspace loads.
            let publicationRead = await readCoherentCache(accountUserID: userID)
            latestCacheRead = publicationRead
            let publishedSnapshot = publicationRead?.snapshot
            // #923: a failed slice's published list is its last-good value —
            // the untouched cache row, or the in-memory list with its pending
            // local overlays still on top.
            let sessionsGroupPublished = outcomes.publishes(.sessionsAndRecordings)
            let publishedSessions = publishedSnapshot?.sessions
                ?? sessionsSlice.value?.activeValues
                ?? sessions.filter { !$0.pending }
            let publishedRecordings = publishedSnapshot?.recordings
                ?? recordingsSlice.value?.activeValues
                ?? recordings
            let publishedLists = accountFetch.publishIfCurrent(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) {
                // The cache is the reconciled source after either a full or a
                // delta refresh: re-adopt it so a pending local
                // preset/routine/settings/tag row is not hidden by the remote
                // snapshot in the published collections (sessions/recordings
                // keep their richer overlays below). A group whose slices
                // failed was never reconciled, so its cache rows are still the
                // last-good ones.
                //
                // #922: re-adopted from the ONE post-reconcile read above.
                applyCachedNonOverlayLists(accountUserID: userID, read: publicationRead)
                // #923: the successful slices publish ONCE, in this one
                // MainActor publication. A failed group publishes nothing, so
                // its sessions/recordings keep last-good data and their
                // pending local overlays instead of being replaced by a
                // half-authoritative pair.
                if sessionsGroupPublished {
                    mergeSessions(remote: publishedSessions)
                    // This is the explicit authoritative refresh boundary. A
                    // server sample blob can change without metadata changing,
                    // so refreshAll is allowed to invalidate every fit;
                    // realtime rep reconciliation below stays key-scoped.
                    invalidateTagCurveCache()
                    mergeRecordings(remote: publishedRecordings)
                    // The sample rows are fetched later by the curve request
                    // and may have changed without any recording metadata
                    // change. Publish this authoritative refresh boundary so a
                    // scoped progress task restarts even when the metadata
                    // snapshot is equal.
                    publishForceProgressInputMutation(.recordings)
                    markRecordingsLoaded()
                }
            }
            guard publishedLists else { return }
            await refreshQueueCount(for: accountFetch)
            guard accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch) else {
                return
            }
            if outcomes.didFullyRefresh {
                // #673: the authoritative sweep succeeded AND is still for the
                // current account — this is the freshness timestamp the
                // foreground gate reasons over. Bumped only here (not by the
                // realtime slice reconciler, which is a targeted refresh that
                // intentionally leaves the non-watched tables untouched).
                //
                // #923 AC3: it is also bumped only for a pass where EVERY
                // slice reconciled. A partial pass leaves the account-wide
                // stamp stale (so the next foreground retries the sweep)
                // while the slices that did reconcile keep their own cursor,
                // and no surface can read this stamp as "everything is fresh".
                lastListRefreshAt = ProcessInfo.processInfo.systemUptime
                // #964: a refresh that actually succeeded retires the
                // Dashboard's load-failure state — the screen has
                // authoritative data again.
                dashboardLoadFailureClass = nil
                lastPartialRefreshFailure = nil
                warmTagCurvesIfMissing(capturedBy: accountFetch)
            } else {
                recordPartialRefresh(
                    outcomes: outcomes,
                    failures: sliceFailures,
                    source: errorSurfaceSource,
                    capturedBy: accountFetch
                )
            }
            // This is deliberately inside the private refresh path so cold
            // bootstrap, foreground refresh, and mutation follow-ups all
            // have one guaranteed publication point after authoritative data
            // has successfully crossed the account/epoch guard.
            publishReadinessWidgetSnapshot()
        } catch {
            if accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch) {
                // Some slices may have already been published before the
                // failure. Put the last-known cache snapshot back so a partial
                // fetch cannot hide a pending local write. #922: the last read
                // of this pass is that snapshot.
                applyCachedNonOverlayLists(accountUserID: userID, read: latestCacheRead)
                // #964: record the failure for the Dashboard before deciding
                // whether it also deserves the dismissible banner. The banner
                // is transient; this state lasts until a refresh succeeds, so
                // dismissing the banner cannot leave a blank Dashboard with no
                // explanation or retry.
                dashboardLoadFailureClass = UserFacingError.classification(for: error)
                // #842: a background/partial refresh failure must not claim
                // total offline while the last-good dataset is already on
                // screen (History rendered, banner claiming a blackout). The
                // suppressed failure still heals a rejected bearer — auth
                // account state is not banner copy.
                if errorSurfacePolicy.shouldSurface(
                    source: errorSurfaceSource,
                    hasLastGoodData: hasLoadedSessions && forceModel.hasLoadedRecordings
                ) {
                    surface(error)
                } else if let postgRESTError = error as? PostgRESTError {
                    recoverAuthFrom(postgRESTError)
                }
            }
        }
    }

    /// Internal refreshes (foreground lifecycle, mutation follow-ups, and
    /// realtime convergence) must not turn the optional generation rollout
    /// check into a user-facing error. The public entry point is reserved for
    /// an explicit foreground retry/pull-to-refresh.
    private func refreshAllSilently() async {
        await refreshAll(
            showSpinner: false,
            dataRefreshOwner: nil,
            purgeGenerationContext: .silent,
            errorSurfaceSource: .background
        )
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
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        let id = UUID()
        let pending = pendingSession(
            id: id,
            draft: draft,
            accountUserID: userID
        )
        pendingSessions[id] = pending
        mergeSessions(remote: sessions.filter { !$0.pending })
        let enqueued = await enqueueSession(
            draft: draft,
            id: id,
            capturedBy: accountFetch
        )
        if !enqueued {
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return nil }
            // #632: the session is lost — see the notice write in
            // `saveForceSummary`.
            LostRecordingStore.note(reason: "session", in: .standard)
            pendingSessions.removeValue(forKey: id)
            mergeSessions(remote: sessions.filter { !$0.pending })
            return nil
        }
        // The enqueue may have suspended while auth changed. Do not hand a
        // receipt for the old account to a newly signed-in UI.
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return nil }
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
        groupID: UUID? = nil,
        capturedBy capturedAccountFetch: AccountScopedFetch? = nil
    ) async -> Bool {
        guard let userID = currentUserID else { return false }
        let accountFetch = capturedAccountFetch ?? AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return false }
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
        let enqueued = await enqueueAndUpload(item, capturedBy: accountFetch)
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
                publishReadinessWidgetSnapshot()
            }
            surface(error)
        }
    }

    public func deleteSession(_ session: SendmeterCore.Session) async {
        guard let userID = currentUserID else { return }
        // A pending row has no server record to soft-delete yet. Reuse the
        // durable Undo path so the local upsert is canceled transactionally,
        // the delete intent survives refresh/relaunch, and an in-flight
        // insert cannot publish the row after the user's delete gesture.
        let currentSession = sessions.first { $0.id == session.id }
        let isPending = session.pending
            || currentSession?.pending == true
            || pendingSessions[session.id] != nil
        if isPending {
            let workoutSource = currentSession?.workoutSource
                ?? pendingSessions[session.id]?.workoutSource
                ?? session.workoutSource
            let deleteKind: PendingSessionDeleteKind =
                workoutSource == .phone ? .manualWorkout : .session
            await undoSession(
                SessionLogReceipt(sessionID: session.id, accountUserID: userID),
                successMessage: PendingSessionDeletePolicy.successMessage(for: deleteKind)
            )
            return
        }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        let previous = sessions.first { $0.id == session.id }
        pendingSessions.removeValue(forKey: session.id)
        sessions.removeAll { $0.id == session.id }
        publishReadinessWidgetSnapshot()
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
        await undoSession(receipt, successMessage: "Routine undone")
    }

    private func undoSession(
        _ receipt: SessionLogReceipt,
        successMessage: String
    ) async {
        guard let queue else {
            surface(NSError(
                domain: "SendmeterNative",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "On-device delete queue is unavailable."]
            ))
            return
        }
        guard let liveUserID = currentUserID,
              liveUserID == receipt.accountUserID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: liveUserID,
            accountEpoch: accountEpoch
        )
        guard routineUndo.claim(receipt, currentUserID: liveUserID) else { return }
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

        // The intent gets its own queue identity. Reusing the session/workout
        // insert's
        // id would let an in-flight insert remove the delete intent when both
        // operations overlap.
        let deleteItem = DurableQueueItem(
            id: UUID(),
            accountUserID: accountUserID,
            payload: PendingWrite.sessionDelete(
                SessionDeleteQueuePayload(sessionID: sessionID)
            )
        )
        // Capture the matching upsert revision before the queue transaction.
        // If an older upload is still in flight, the conditional removal will
        // leave a newer replacement intact; the delete upload waits for that
        // request before touching the server.
        let pendingInsert = await queue.item(
            id: sessionID,
            accountUserID: accountUserID
        )
        guard accountFetch.canApply(
            to: self.currentUserID,
            accountEpoch: accountEpoch
        ) else { return }
        let cancelingInserts = pendingInsert.map {
            DurableQueueRemoval(
                id: $0.id,
                accountUserID: $0.accountUserID,
                expectedRevision: $0.revision
            )
        }.map { [$0] } ?? []
        do {
            guard try await queue.enqueueReplacing(
                deleteItem,
                canceling: cancelingInserts
            ) else {
                throw NSError(
                    domain: "SendmeterNative",
                    code: 12,
                    userInfo: [NSLocalizedDescriptionKey: "The session delete was already completed."]
                )
            }
            guard accountFetch.canApply(
                to: self.currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            await refreshQueueCount(for: accountFetch)
            let result = await upload(deleteItem, capturedBy: accountFetch)
            guard accountFetch.canApply(
                to: self.currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            if result.uploaded { toastMessage = successMessage }
        } catch {
            // The optimistic hide is not durable until the delete intent has
            // been persisted. Roll it back only for the account that made the
            // receipt; a sign-out/user switch must never refresh old-account
            // data into the new account's model.
            let currentAccount = self.currentUserID
            _ = routineUndo.rollbackClaim(receipt, currentUserID: currentAccount)
            guard accountFetch.canApply(
                to: currentAccount,
                accountEpoch: accountEpoch
            ) else { return }
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
            await refreshAllSilently()
            guard accountFetch.canApply(
                to: self.currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            surface(error)
        }
    }

    public func restoreSession(_ session: SendmeterCore.Session) async {
        guard let userID = currentUserID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        do {
            try await self.repository.restoreSession(id: session.id)
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            self.cacheConfirmServerUpsert(
                session,
                accountUserID: userID,
                entityType: .sessions,
                entityID: CacheEntityID.session(session)
            )
            self.deletedSessions.removeAll { $0.id == session.id }
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            await self.refreshAllSilently()
        } catch {
            if accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) {
                surface(error)
            }
        }
    }

    public func purgeSession(_ session: SendmeterCore.Session) async {
        guard let userID = currentUserID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        _ = cacheMarkDeletedLocal(
            accountUserID: userID,
            entityType: .sessions,
            entityID: CacheEntityID.session(session)
        )
        do {
            try await self.repository.purgeSession(id: session.id)
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            self.cacheConfirmServerDelete(
                accountUserID: userID,
                entityType: .sessions,
                entityID: CacheEntityID.session(session)
            )
            self.deletedSessions.removeAll { $0.id == session.id }
        } catch {
            if accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) {
                surface(error)
            }
        }
    }

    // MARK: Phase

    /// Switches the training block (#917).
    ///
    /// A transition is not one row: it writes the phase periods AND the
    /// `user_settings` row that has to keep pointing at the canonical open
    /// period. The whole transition is therefore persisted as ONE
    /// account-scoped intent BEFORE anything is presented as accepted, so a
    /// termination before the request, between the related writes, or after the
    /// server's write but before the local acknowledgement leaves a replayable
    /// intent instead of a partly-applied block history.
    ///
    /// When the intent cannot be persisted nothing local changes and the
    /// failure is surfaced (retryable, never reported as saved). Every later
    /// failure keeps the optimistic state and the durable intent: it is
    /// retried, and stays visible as queued/unsynced work.
    public func switchPhase(to phase: PhaseID) async {
        guard let userID = currentUserID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        let previousPeriods = phasePeriods
        let today = LocalDateSupport.string(from: Date())
        let preview = localPhaseTransition(
            periods: previousPeriods,
            newPhase: phase,
            today: today
        )
        let intent = PhaseTransitionIntent(
            targetPhase: phase,
            intendedToday: today,
            previousPeriods: previousPeriods,
            settings: preview.settings
        )
        guard let item = await enqueueDirectWrite(
            .phaseTransition(intent),
            capturedBy: accountFetch,
            startUpload: false
        ) else {
            // Nothing was written locally: this transition is not accepted, so
            // it must not be presented as one.
            surfaceDirectWriteNotPersisted()
            return
        }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return }
        phasePeriods = preview.periods
        settings = preview.settings
        publishReadinessWidgetSnapshot()
        let previewIDs = Set(preview.periods.map(\.id))
        for period in previousPeriods where !previewIDs.contains(period.id) {
            cacheMarkDeletedLocal(
                accountUserID: userID,
                entityType: .phasePeriods,
                entityID: period.id.uuidString
            )
        }
        for period in preview.periods {
            cacheUpsertLocal(
                period,
                accountUserID: userID,
                entityType: .phasePeriods,
                entityID: period.id.uuidString
            )
        }
        cacheUpsertLocal(
            preview.settings,
            accountUserID: userID,
            entityType: .settings,
            entityID: CacheEntityID.settings
        )
        refreshPendingCacheWriteCount(accountUserID: userID)
        startQueueUpload(item, capturedBy: accountFetch)
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

    // MARK: Manual workout lifecycle (#936)

    /// Apply one lifecycle outcome: the rest/live-card effects in the order the
    /// owner decided them, then the durable save it handed over.
    ///
    /// The save is the app's ONE workout path (`saveWorkout` → the durable
    /// queue → the #935 recovery owner); the owner never writes a second
    /// persistence format. Its completion is reported back with the ticket, so
    /// only the finish that is actually in flight can release the save latch.
    @discardableResult
    private func applyManualWorkoutLifecycle(
        _ outcome: ManualWorkoutLifecycleOutcome
    ) -> ManualWorkoutLifecycleOutcome {
        for effect in outcome.effects {
            switch effect {
            case let .syncActivity(workout, restTarget):
                manualWorkoutActivity.sync(engine: workout, restTarget: restTarget)
            case let .syncRest(workout, restTarget):
                manualWorkoutRest.update(engine: workout, restTarget: restTarget)
            case .discardActivityEvents:
                manualWorkoutActivity.discardPendingEvents()
            case .requestRestNotificationPermission:
                // #936: the owner decides WHEN the one user-initiated ask
                // happens; the adapter owns how.
                Task { await manualWorkoutRest.requestNotificationPermissionIfNeeded() }
            }
        }
        guard case let .persist(draft, ticket) = outcome.decision else { return outcome }
        Task { @MainActor in
            await saveWorkout(draft)
            applyManualWorkoutLifecycle(manualWorkoutLifecycle.saveDidComplete(ticket: ticket))
        }
        return outcome
    }

    /// Start the user's manual workout. Ignored while one is already in progress
    /// or while the previous finish is still saving — a re-created view can
    /// never replace the workout the user is in the middle of.
    @discardableResult
    public func startManualWorkout(
        at date: Date = Date(),
        asksForRestNotificationPermission: Bool = true
    ) -> ManualWorkoutLifecycleOutcome {
        guard let userID = currentUserID else { return .ignored }
        return applyManualWorkoutLifecycle(
            manualWorkoutLifecycle.start(
                accountUserID: userID,
                phase: settings.currentPhase,
                at: date,
                asksForRestNotificationPermission: asksForRestNotificationPermission
            )
        )
    }

    /// The workout surface (re)appeared. Resumes the workout the owner holds —
    /// it never creates one and never terminates one.
    @discardableResult
    public func resumeManualWorkout() -> ManualWorkoutLifecycleOutcome {
        applyManualWorkoutLifecycle(manualWorkoutLifecycle.resume())
    }

    /// Minimize the full-screen presentation. The workout keeps running.
    @discardableResult
    public func minimizeManualWorkout() -> ManualWorkoutLifecycleOutcome {
        applyManualWorkoutLifecycle(manualWorkoutLifecycle.minimize())
    }

    /// The boulder control. The engine's own guards throw on an invalid
    /// transition; the caller presents that error where it always did.
    @discardableResult
    public func toggleManualWorkoutAttempt(
        at date: Date = Date()
    ) throws -> ManualWorkoutLifecycleOutcome {
        try applyManualWorkoutLifecycle(manualWorkoutLifecycle.toggleAttempt(at: date))
    }

    @discardableResult
    public func setManualWorkoutRPE(_ rpe: Double) -> ManualWorkoutLifecycleOutcome {
        applyManualWorkoutLifecycle(manualWorkoutLifecycle.setRPE(rpe))
    }

    @discardableResult
    public func setManualWorkoutRestTarget(_ target: Int) -> ManualWorkoutLifecycleOutcome {
        applyManualWorkoutLifecycle(manualWorkoutLifecycle.setRestTarget(target))
    }

    /// The End control: refused with the #926 explanation when no attempt was
    /// completed, otherwise EXACTLY ONE draft is handed to `saveWorkout`.
    @discardableResult
    public func endManualWorkout(at date: Date = Date()) -> ManualWorkoutLifecycleOutcome {
        applyManualWorkoutLifecycle(manualWorkoutLifecycle.end(at: date))
    }

    /// Replay the lock-screen intents the Live Activity adapter queued for the
    /// workout the owner holds. A drained batch for a workout that is gone is
    /// discarded — the adapter's own identity contract, kept intact here.
    @discardableResult
    public func drainManualWorkoutActivityEvents() -> ManualWorkoutLifecycleOutcome {
        let events = manualWorkoutActivity.drainPendingEvents(
            forWorkoutStartedAt: manualWorkoutLifecycle.workoutStartedAt
        )
        return applyManualWorkoutLifecycle(
            manualWorkoutLifecycle.applyActivityEvents(events)
        )
    }

    #if DEBUG
    /// #926/#936 harness: arm the REAL manual workout for the signed-out
    /// simulator fixtures — the production lifecycle owner, engine, effects and
    /// End path, with a synthetic account. Only the notification-permission ask
    /// stays off (its system prompt would cover the surface under capture).
    @discardableResult
    public func startManualWorkoutFixture() -> ManualWorkoutLifecycleOutcome {
        applyManualWorkoutLifecycle(
            manualWorkoutLifecycle.start(
                accountUserID: UUID(),
                phase: settings.currentPhase,
                at: Date(),
                asksForRestNotificationPermission: false
            )
        )
    }
    #endif

    // MARK: Workout

    public func saveWorkout(_ draft: WorkoutDraft) async {
        guard let userID = currentUserID, draft.accountUserID == userID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
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
        if !(await enqueueAndUpload(item, capturedBy: accountFetch)) {
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
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
        guard let userID = currentUserID else { return ForceTargetPlan(targets: [:]) }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        // #901 mirror of `ForceProtocolSidePolicy.scheduleWorkSides`: the
        // selected (fallback) side decides the per-side target set — a
        // Left/Right selection resolves ONLY that side's bands; the preset's
        // `alternateSides` flag only widens a Both/unspecified selection
        // into the alternating pair. `fallbackSide` is the normalized side
        // selection at every call site (launch boundary + context-card
        // resolution).
        let sides = ForceProtocolSidePolicy.planWorkSides(
            selectedSide: fallbackSide,
            presetAlternates: preset.alternateSides,
            startingSide: startingSide
        )

        var targets: [ForceTargetKey: ForceTargetBand] = [:]
        let needsCurve = preset.targetFromCurve
            || (preset.targetPercentage != nil && preset.percentageBasis == .criticalForce)
            // #902: a suggested-zone preset resolves its band from the
            // side-scoped curve (maxF / CF / hill F60), so the references
            // fetch must include the fitted curve.
            || preset.zoneQuality != nil

        for targetSide in sides {
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return ForceTargetPlan(targets: [:]) }
            let references = await forceReferences(
                tag: tag,
                side: targetSide,
                needsCurve: needsCurve,
                capturedBy: accountFetch
            )
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return ForceTargetPlan(targets: [:]) }
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
        let enqueued = await enqueueAndUpload(item, capturedBy: accountFetch)
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
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return .stale }
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
        guard let userID = currentUserID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        // #613: wait for any in-flight rep save to become durable + locally
        // published BEFORE claiming the end — a disconnect's interrupted
        // save lands after the status change (the guided view's tick
        // preserves the partial rep), and a late rep must join THIS group,
        // not mint a new one. Bounded by local persistence, never the
        // network. The claim after the wait still precedes any await of the
        // insert, so concurrent end paths still log exactly once.
        await gaugeSessionSaveGate.waitForIdle()
        guard expectedScope == nil || accountScope == expectedScope,
              accountFetch.canApply(
                  to: currentUserID,
                  accountEpoch: accountEpoch
              ) else { return }
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
            groupID: ended.groupID,
            capturedBy: accountFetch
        )
        guard expectedScope == nil || accountScope == expectedScope,
              accountFetch.canApply(
                  to: currentUserID,
                  accountEpoch: accountEpoch
              ) else { return }
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
        handsFreeSaveInFlight = true
        Task {
            defer { handsFreeSaveInFlight = false }
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
        needsCurve: Bool,
        capturedBy accountFetch: AccountScopedFetch
    ) async -> ForceReferences {
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return .empty }
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

        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return .empty }

        let references = await Task.detached(priority: .userInitiated) {
            // #651: `metadata` here is EFFORT-only (PR/trend keep a recovered
            // blob's valid peakKg), while `sampleSets` came from
            // curve-fit candidates — a salvage blob's inflated duration /
            // deflated avg never reaches the CF/W′ regression. Web #486
            // asymmetry preserved.
            ForceCurveEngine.references(metadata: metadata, sampleSets: sampleSets)
        }.value
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return .empty }
        return references
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
            await refreshAllSilently()
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
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        _ = cacheMarkDeletedLocal(
            accountUserID: userID,
            entityType: .recordings,
            entityID: CacheEntityID.recording(recording)
        )
        do {
            try await repository.purgeRecording(id: recording.id)
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            cacheConfirmServerDelete(
                accountUserID: userID,
                entityType: .recordings,
                entityID: CacheEntityID.recording(recording)
            )
            deletedRecordings.removeAll { $0.id == recording.id }
        } catch {
            // Keep the optimistic tombstone on failure: purge is a terminal
            // intent and the queued delete path already owns retrying it.
            if accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) {
                surface(error)
            }
        }
    }

    public func linkRecordings(_ recordings: [TindeqRecording], to session: SendmeterCore.Session) async {
        guard let userID = currentUserID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        let unlinked = recordings.filter { $0.groupID == nil }
        guard !unlinked.isEmpty else { return }
        do {
            let result = try await self.repository.linkRecordingsToSession(
                sessionID: session.id,
                recordingIDs: unlinked.map(\.id)
            )
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
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
        } catch {
            if accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) {
                surface(error)
            }
        }
    }

    /// #942: the merge plan for a selection — nil when the selection is not
    /// eligible. Uses the same cached curves as the merge itself, so the
    /// History confirm sheet previews exactly what will be applied.
    public func mergePreview(
        _ sessions: [SendmeterCore.Session]
    ) -> TindeqSessionMergePlan? {
        mergeContext(sessions)?.plan
    }

    /// The plan plus the local recordings it owns — the two things both the
    /// preview and the merge need.
    private func mergeContext(
        _ sessions: [SendmeterCore.Session]
    ) -> (plan: TindeqSessionMergePlan, recordings: [TindeqRecording])? {
        let selectedGroupIDs = Set(sessions.compactMap(\.groupID))
        let selectedRecordings = recordings.filter { recording in
            guard let groupID = recording.groupID else { return false }
            return selectedGroupIDs.contains(groupID)
        }
        guard let plan = TindeqSessionMergePlanner.plan(
            sessions: sessions,
            recordings: recordings,
            curves: cachedCurves(for: selectedRecordings)
        ) else { return nil }
        return (plan, selectedRecordings)
    }

    /// #942: merge same-day Tindeq sessions into ONE entry (History's
    /// "Merge with…").
    ///
    /// The plan is pure (`TindeqSessionMergePlanner`) and the server applies
    /// it in ONE transaction (`merge_tindeq_sessions`), so every local
    /// mutation below is only ever an optimistic mirror of a single atomic
    /// server write. The write goes through the same durable queue as every
    /// other session write: offline it uploads on reconnect, and a relaunch
    /// rebuilds the merged entry from the queue payload.
    ///
    /// Returns false when the selection is not eligible or could not be made
    /// durable — nothing is left half-applied then.
    @discardableResult
    public func mergeTindeqSessions(_ selection: [SendmeterCore.Session]) async -> Bool {
        guard let userID = currentUserID else { return false }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        guard let context = mergeContext(selection),
              let survivor = selection.first(where: { $0.id == context.plan.survivorID }) else {
            return false
        }
        let plan = context.plan
        let selectedRecordings = context.recordings
        let previousSurvivor = self.sessions.first { $0.id == plan.survivorID } ?? survivor
        let mergedAwayIDs = plan.mergedSessionIDs.filter { $0 != plan.survivorID }
        // Snapshots for the rollback below: the local rows before the merge.
        let recordingsBefore = selectedRecordings

        // 1. The survivor becomes the merged row (optimistically pending).
        var optimistic = plan.merged(survivor: survivor)
        optimistic.pending = true
        optimistic.rejected = false
        optimistic.accountUserID = userID
        pendingSessions[plan.survivorID] = optimistic
        let optimisticRevision = cacheUpsertLocal(
            optimistic,
            accountUserID: userID,
            entityType: .sessions,
            entityID: CacheEntityID.session(optimistic)
        )

        // 2. The merged-away sessions leave the list and the local cache, and
        //    stay hidden while the merge is queued (an authoritative fetch
        //    still returns them until the RPC lands).
        for sessionID in mergedAwayIDs {
            pendingSessions.removeValue(forKey: sessionID)
            pendingMergedAwaySessionIDs[sessionID] = userID
            _ = cacheMarkDeletedLocal(
                accountUserID: userID,
                entityType: .sessions,
                entityID: sessionID.uuidString
            )
        }

        // 3. The merged recordings move under the surviving group locally,
        //    exactly as the RPC will move them server-side.
        for recording in selectedRecordings {
            guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else {
                continue
            }
            recordings[index].groupID = plan.groupID
            cacheUpsertServer(
                recordings[index],
                accountUserID: userID,
                entityType: .recordings,
                entityID: CacheEntityID.recording(recordings[index])
            )
        }

        // The survivor's pre-merge row must leave the list too: the optimistic
        // merged row now owns that id in `pendingSessions`, and publishing the
        // stale row through `mergeSessions(remote:)` would wipe the overlay
        // (it drops every pending id that also appears in the remote list).
        sessions.removeAll { $0.id == plan.survivorID || mergedAwayIDs.contains($0.id) }
        mergeSessions(remote: sessions.filter { !$0.pending })

        let item = DurableQueueItem(
            id: plan.survivorID,
            accountUserID: userID,
            payload: PendingWrite.sessionMerge(
                SessionMergeQueuePayload(
                    survivorID: plan.survivorID,
                    mergedSessionIDs: plan.mergedSessionIDs,
                    recordingIDs: plan.recordingIDs,
                    groupID: plan.groupID,
                    draft: plan.draft,
                    rpeConfirmed: plan.rpeConfirmed
                )
            )
        )
        let enqueued = await enqueueAndUpload(item, capturedBy: accountFetch)
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return enqueued }
        guard enqueued else {
            // The merge is not durable, so nothing may stay merged: restore
            // the survivor, the merged-away rows and the recordings, and let
            // the caller report the failure. (The cache tombstones written
            // above are republished by the next authoritative fetch.)
            pendingSessions.removeValue(forKey: plan.survivorID)
            for sessionID in mergedAwayIDs {
                pendingMergedAwaySessionIDs.removeValue(forKey: sessionID)
            }
            cacheConfirmServerUpsert(
                previousSurvivor,
                accountUserID: userID,
                entityType: .sessions,
                entityID: CacheEntityID.session(previousSurvivor),
                confirmingLocalRevision: optimisticRevision
            )
            for recording in recordingsBefore {
                guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else {
                    continue
                }
                recordings[index] = recording
                cacheUpsertServer(
                    recordings[index],
                    accountUserID: userID,
                    entityType: .recordings,
                    entityID: CacheEntityID.recording(recordings[index])
                )
            }
            // Put the pre-merge rows back exactly as they were, so the user's
            // history is never left with a hole after a failed enqueue.
            sessions.removeAll {
                $0.id == plan.survivorID || mergedAwayIDs.contains($0.id)
            }
            sessions.append(previousSurvivor)
            sessions.append(
                contentsOf: selection.filter { mergedAwayIDs.contains($0.id) }
            )
            mergeSessions(remote: sessions.filter { !$0.pending })
            return false
        }
        toastMessage = "Sessions merged."
        return true
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

    /// Persists one preset save (#916). The intended mutation — account, entity
    /// identity, operation and content — is durable in the existing
    /// `DurableQueue` before this returns, so a termination between the
    /// optimistic row and the server acknowledgement leaves a replayable intent
    /// instead of a pending cache-only row with no intent at all. Returns false
    /// when the intent could not be persisted: nothing is written locally and
    /// the failure is surfaced, never reported as a saved state.
    @discardableResult
    public func savePreset(_ preset: TindeqPreset, isNew: Bool) async -> Bool {
        guard let userID = currentUserID else { return false }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        let intent = DirectWriteIntent(
            entityID: CacheEntityID.preset(preset),
            operation: isNew ? .create : .update,
            mutation: preset
        )
        guard let item = await enqueueDirectWrite(
            .preset(intent),
            capturedBy: accountFetch,
            startUpload: false
        ) else { return false }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return false }
        cacheUpsertLocal(
            preset,
            accountUserID: userID,
            entityType: .presets,
            entityID: CacheEntityID.preset(preset)
        )
        presets.removeAll { $0.id == preset.id }
        presets.insert(preset, at: 0)
        startQueueUpload(item, capturedBy: accountFetch)
        return true
    }

    /// Deletes one preset through the durable queue (#916): the delete intent
    /// carries the entity identity and the pre-delete row, and it is persisted
    /// before the row leaves the list. A termination mid-delete therefore
    /// replays the removal instead of leaving the entity behind, and a
    /// completed delete terminalizes the identity so no later write can
    /// resurrect it. Returns false (nothing changed locally, failure surfaced)
    /// when the intent could not be persisted.
    @discardableResult
    public func deletePreset(_ preset: TindeqPreset) async -> Bool {
        guard let userID = currentUserID else { return false }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        let previous = presets.first { $0.id == preset.id }
        let intent = DirectWriteIntent(
            entityID: CacheEntityID.preset(preset),
            operation: .delete,
            mutation: previous ?? preset
        )
        guard let item = await enqueueDirectWrite(
            .preset(intent),
            capturedBy: accountFetch,
            startUpload: false
        ) else { return false }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return false }
        presets.removeAll { $0.id == preset.id }
        cacheMarkDeletedLocal(
            accountUserID: userID,
            entityType: .presets,
            entityID: CacheEntityID.preset(preset)
        )
        startQueueUpload(item, capturedBy: accountFetch)
        return true
    }

    // MARK: Routines

    /// Persists one routine save (#916) with the same durability contract as
    /// `savePreset`: the intent (identity + operation + immutable content) is
    /// queued before the optimistic row is reported as accepted, so process
    /// death between the local row and the acknowledgement replays the write
    /// instead of leaving an unreplayable pending row.
    @discardableResult
    public func saveRoutine(_ routine: RoutinePreset, isNew: Bool) async -> Bool {
        guard let userID = currentUserID else { return false }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        let intent = DirectWriteIntent(
            entityID: CacheEntityID.routine(routine),
            operation: isNew ? .create : .update,
            mutation: routine
        )
        guard let item = await enqueueDirectWrite(
            .routine(intent),
            capturedBy: accountFetch,
            startUpload: false
        ) else { return false }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return false }
        cacheUpsertLocal(
            routine,
            accountUserID: userID,
            entityType: .routinePresets,
            entityID: CacheEntityID.routine(routine)
        )
        routines.removeAll { $0.id == routine.id }
        routines.insert(routine, at: 0)
        startQueueUpload(item, capturedBy: accountFetch)
        return true
    }

    /// Deletes one routine through the durable queue (#916), exactly as
    /// `deletePreset` does: the removal is durable before the row leaves the
    /// list, and it terminalizes the identity once it lands.
    @discardableResult
    public func deleteRoutine(_ routine: RoutinePreset) async -> Bool {
        guard let userID = currentUserID else { return false }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        let previous = routines.first { $0.id == routine.id }
        let intent = DirectWriteIntent(
            entityID: CacheEntityID.routine(routine),
            operation: .delete,
            mutation: previous ?? routine
        )
        guard let item = await enqueueDirectWrite(
            .routine(intent),
            capturedBy: accountFetch,
            startUpload: false
        ) else { return false }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return false }
        routines.removeAll { $0.id == routine.id }
        cacheMarkDeletedLocal(
            accountUserID: userID,
            entityType: .routinePresets,
            entityID: CacheEntityID.routine(routine)
        )
        startQueueUpload(item, capturedBy: accountFetch)
        return true
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
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        do {
            if requestAuthorization {
                try await self.health.requestAuthorization()
                guard !Task.isCancelled, accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else { return }
                UserDefaults.standard.set(true, forKey: "sendmeter.native.health-authorized")
            }
            guard !Task.isCancelled, accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            self.lastHealthRefreshStartedAt = ProcessInfo.processInfo.systemUptime
            let passTimeZone = TimeZone.current
            guard let result = try await self.computeAndPublishReadiness(
                userID: userID,
                trigger: .manual,
                capturedBy: accountFetch,
                timeZone: passTimeZone
            ) else { return }
            let observation = result.observation
            guard !Task.isCancelled, accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            recordHealthSync(
                observation,
                capturedBy: accountFetch
            )
            if !Task.isCancelled, let message = observation.manualMessage {
                self.toastMessage = message
            }
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled, accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) {
                recordHealthSyncFailure(capturedBy: accountFetch)
                surface(error)
            }
        }
    }

    /// #661: the silent refresh trigger for Dashboard appear and app
    /// foreground (and a manual pull-to-refresh). Runs the recompute ONLY
    /// when the coalescing policy says so. The last reading is always kept on
    /// failure — a throwing query or a successful-but-empty read never blanks
    /// a scored today row and never fabricates a score (see
    /// `ReadinessSyncPolicy`). A failure is recorded in health-sync state, not
    /// surfaced through auth diagnostics or an error banner: this is a
    /// background-quality refresh (web `runForegroundSync` parity), so a
    /// HealthKit hiccup must not interrupt the last reading.
    /// `.manual` maps to the authoritative #109 trigger and so may surface the
    /// honest empty state; appear/foreground/background are automatic.
    public func silentHealthRefresh(trigger: HealthRefreshTrigger) async {
        guard !Task.isCancelled,
              UserDefaults.standard.bool(forKey: "sendmeter.native.health-authorized")
        else { return }
        let monotonicNow = ProcessInfo.processInfo.systemUptime
        guard healthRefreshPolicy.shouldRefresh(
            trigger: trigger,
            lastStartedAt: lastHealthRefreshStartedAt,
            now: monotonicNow
        ) else { return }
        guard let userID = currentUserID else { return }
        let wallNow = Date()
        let passTimeZone = TimeZone.current
        let passCalendar = LocalDateSupport.calendar(timeZone: passTimeZone)
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )

        if trigger != .manual {
            var persistedProgress = loadMorningHealthProgress(for: userID)
            if let progress = persistedProgress,
               progress.accountUserID != userID
                || !healthMorningRefreshPolicy.isCurrentLocalDay(
                    progress,
                    at: wallNow,
                    calendar: passCalendar
                )
                || progress.nextPass < 0
                || progress.nextPass >= healthMorningRefreshPolicy.passCount {
                clearMorningHealthProgress(for: userID)
                persistedProgress = nil
            }
            if let progress = persistedProgress {
                // A completed pass is durable state, not an instruction to
                // run immediately. The next pass is claimed only when a
                // later supported lifecycle/observer/BGAppRefresh event
                // arrives after its persisted eligibility time. This is a
                // resume claim even for pass 0: the new-window once/day gate
                // must not reject a persisted retry after cancellation.
                if let pass = healthMorningRefreshPolicy.duePass(
                    for: progress,
                    at: wallNow
                ) {
                    let owner = claimMorningHealthRefresh(
                        now: wallNow,
                        startedAt: progress.startedAt,
                        pass: pass,
                        accountFetch: accountFetch,
                        calendar: passCalendar,
                        mode: .resumePersisted,
                        progress: progress
                    )
                    let route = HealthMorningRefreshRoute.afterClaim(
                        pass: pass,
                        didClaim: owner != nil
                    )
                    if case .morning = route, let owner {
                        await runMorningHealthRefreshPass(
                            owner,
                            progress: progress,
                            pass: pass,
                            timeZone: passTimeZone
                        )
                        return
                    }
                }
            }
            if healthMorningRefreshPolicy.isMorning(at: wallNow, calendar: passCalendar) {
                // A completed morning window is represented by the persisted
                // start marker and the absence of progress. A concurrent
                // owner cannot create a duplicate window; this failed claim
                // falls through to the ordinary automatic refresh below.
                let owner = claimMorningHealthRefresh(
                    now: wallNow,
                    startedAt: wallNow,
                    pass: 0,
                    accountFetch: accountFetch,
                    calendar: passCalendar,
                    mode: .newWindow,
                    progress: nil
                )
                let route = HealthMorningRefreshRoute.afterClaim(
                    pass: 0,
                    didClaim: owner != nil
                )
                if case .morning = route, let owner {
                    let progress = HealthMorningRefreshProgress(
                        accountUserID: userID,
                        startedAt: wallNow,
                        timeZoneIdentifier: passTimeZone.identifier
                    )
                    if !Task.isCancelled,
                       persistMorningHealthProgress(progress) {
                        await runMorningHealthRefreshPass(
                            owner,
                            progress: progress,
                            pass: 0,
                            timeZone: passTimeZone
                        )
                        return
                    }
                    if !Task.isCancelled {
                        clearMorningHealthProgress(for: userID)
                        recordHealthSyncFailure(capturedBy: accountFetch)
                    }
                    finishMorningHealthRefresh(owner: owner)
                }
            }
        }

        guard !Task.isCancelled else { return }
        lastHealthRefreshStartedAt = monotonicNow
        do {
            guard let result = try await computeAndPublishReadiness(
                userID: userID,
                trigger: trigger.syncTrigger,
                capturedBy: accountFetch,
                timeZone: passTimeZone
            ) else { return }
            let observation = result.observation
            guard !Task.isCancelled else { return }
            recordHealthSync(
                observation,
                capturedBy: accountFetch
            )
            // #844: only a user-initiated sync confirms with a toast;
            // automatic appear/foreground/background refreshes update
            // state only.
            if trigger.isUserInitiated, let message = observation.manualMessage {
                self.toastMessage = message
            }
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            // Keep the last reading and expose a failed health state without
            // turning a background HealthKit/transport problem into an auth
            // diagnostic or a disruptive error banner.
            if !Task.isCancelled, accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) {
                recordHealthSyncFailure(capturedBy: accountFetch)
            }
        }
    }

    /// A background HealthKit observer fire uses the same observable automatic
    /// path as foreground refresh. The morning branch performs one pass before
    /// returning to HealthKit's observer completion; persisted later passes
    /// are picked up by a subsequent supported event.
    private func handleHealthBackgroundUpdate() async {
        await silentHealthRefresh(trigger: .background)
    }

    private func claimMorningHealthRefresh(
        now: Date,
        startedAt: Date,
        pass: Int,
        accountFetch: AccountScopedFetch,
        calendar: Calendar,
        mode: HealthMorningRefreshClaimMode,
        progress: HealthMorningRefreshProgress?
    ) -> AccountScopedCompletion? {
        guard !Task.isCancelled, accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ), morningHealthRefreshState.claim(
            mode: mode,
            pass: pass,
            at: now,
            currentUserID: currentUserID,
            accountUserID: accountFetch.accountUserID,
            lastStartedAt: lastMorningRefreshStartedAt,
            progress: progress,
            policy: healthMorningRefreshPolicy,
            calendar: calendar
        )
        else { return nil }

        // These are all synchronous MainActor mutations before the first
        // HealthKit/repository await. The account owner and dedupe marker can
        // therefore reject every later callback from this window. The start
        // marker survives relaunch so a completed window is still once/day.
        let owner = AccountScopedCompletion(fetch: accountFetch)
        if mode == .newWindow {
            lastMorningRefreshStartedAt = startedAt
            UserDefaults.standard.set(
                startedAt.timeIntervalSince1970,
                forKey: healthMorningStartedDefaultsKey(for: accountFetch.accountUserID)
            )
        }
        morningHealthRefreshOwner = owner
        lastHealthRefreshStartedAt = ProcessInfo.processInfo.systemUptime
        return owner
    }

    private func runMorningHealthRefreshPass(
        _ owner: AccountScopedCompletion,
        progress initialProgress: HealthMorningRefreshProgress,
        pass: Int,
        timeZone: TimeZone
    ) async {
        var progress = initialProgress
        do {
            guard !Task.isCancelled else {
                finishMorningHealthRefresh(owner: owner)
                return
            }
            guard let result = try await computeAndPublishReadiness(
                userID: owner.fetch.accountUserID,
                trigger: .automatic,
                capturedBy: owner.fetch,
                timeZone: timeZone
            ) else {
                // The recompute gate may already have an owner. The durable
                // progress remains at this pass so a later lifecycle event
                // retries it after the competing work has settled.
                finishMorningHealthRefresh(owner: owner)
                return
            }
            guard !Task.isCancelled else {
                finishMorningHealthRefresh(owner: owner)
                return
            }
            progress.add(
                result.observation,
                acknowledgedReconciledDates: result.acknowledgedReconciledDates
            )
            guard !Task.isCancelled else {
                finishMorningHealthRefresh(owner: owner)
                return
            }
            recordHealthSync(
                result.observation,
                capturedBy: owner.fetch
            )
        } catch is CancellationError {
            finishMorningHealthRefresh(owner: owner)
            return
        } catch let error as URLError where error.code == .cancelled {
            finishMorningHealthRefresh(owner: owner)
            return
        } catch {
            guard !Task.isCancelled else {
                finishMorningHealthRefresh(owner: owner)
                return
            }
            progress.markFailure()
            guard !Task.isCancelled else {
                finishMorningHealthRefresh(owner: owner)
                return
            }
            recordHealthSyncFailure(capturedBy: owner.fetch)
        }

        let ownerIsCurrent = owner.owns(
            currentUserID: currentUserID,
            accountEpoch: accountEpoch,
            activeOwner: morningHealthRefreshOwner
        )
        guard morningHealthRefreshState.continueAfterResult(
            isCancelled: Task.isCancelled,
            ownerIsCurrent: ownerIsCurrent
        ) else {
            // A cancelled/stale continuation must release its active owner;
            // the Core decision only releases the gate when this owner is
            // still current, so an older completion cannot clear a newer one.
            finishMorningHealthRefresh(owner: owner)
            return
        }

        guard !Task.isCancelled else {
            finishMorningHealthRefresh(owner: owner)
            return
        }
        progress.nextPass = pass + 1
        guard progress.nextPass < healthMorningRefreshPolicy.passCount else {
            guard !Task.isCancelled else {
                finishMorningHealthRefresh(owner: owner)
                return
            }
            clearMorningHealthProgress(for: owner.fetch.accountUserID)
            guard !Task.isCancelled else {
                finishMorningHealthRefresh(owner: owner)
                return
            }
            finishMorningHealthRefresh(owner: owner, progress: progress)
            return
        }

        guard !Task.isCancelled else {
            finishMorningHealthRefresh(owner: owner)
            return
        }
        guard persistMorningHealthProgress(progress) else {
            guard !Task.isCancelled else {
                finishMorningHealthRefresh(owner: owner)
                return
            }
            clearMorningHealthProgress(for: owner.fetch.accountUserID)
            guard !Task.isCancelled else {
                finishMorningHealthRefresh(owner: owner)
                return
            }
            recordHealthSyncFailure(capturedBy: owner.fetch)
            finishMorningHealthRefresh(owner: owner)
            return
        }
        guard !Task.isCancelled else {
            finishMorningHealthRefresh(owner: owner)
            return
        }
        scheduleMorningHealthProgress(progress, now: Date())
        guard !Task.isCancelled else {
            finishMorningHealthRefresh(owner: owner)
            return
        }
        finishMorningHealthRefresh(owner: owner)
    }

    private func scheduleMorningHealthProgress(
        _ progress: HealthMorningRefreshProgress,
        now: Date
    ) {
        guard let delay = healthMorningRefreshPolicy.delay(
            forPass: progress.nextPass
        ) else { return }
        let dueAt = progress.startedAt.addingTimeInterval(delay)
        let remaining = max(60, dueAt.timeIntervalSince(now))
        // BGAppRefresh is only an eligibility request. The actual pass still
        // re-checks the persisted due time when a supported event reaches the
        // app, so this call never owns a timer or a completion.
        BackgroundSyncService.schedule(minimumInterval: remaining)
    }

    private func finishMorningHealthRefresh(
        owner: AccountScopedCompletion,
        progress: HealthMorningRefreshProgress? = nil
    ) {
        guard morningHealthRefreshOwner == owner else { return }
        // Releasing the owner/gate is cancellation cleanup. A completion
        // observation, however, is a visible state mutation and must never be
        // published after an expired BG task has cancelled this pass.
        if !Task.isCancelled, let observation = progress?.finalObservation {
            if observation == .failed {
                recordHealthSyncFailure(capturedBy: owner.fetch)
            } else {
                recordHealthSync(
                    observation,
                    capturedBy: owner.fetch
                )
            }
        }
        morningHealthRefreshOwner = nil
        morningHealthRefreshState.release()
    }

    /// One watch-originated readiness request (#913), executed on the same
    /// single-flight pipeline a foreground or background trigger uses — so
    /// #802's dual-source precedence and the #109 freeze remain the only write
    /// rules, and a watch ask can never introduce a second writer.
    ///
    /// Every exit is a typed, user-facing outcome; the watch's own result gate
    /// owns late/duplicate application. A pass that was coalesced behind an
    /// in-flight owner (`nil`) still answers with the phone's current
    /// published reading rather than an error, because the phone does have a
    /// score to show.
    private func performWatchReadinessRefresh() async -> ReadinessRefreshOutcome {
        guard let userID = currentUserID else { return .authRequired() }
        // The same authorization flag the automatic foreground/background
        // paths gate on: without Health access the phone cannot refresh, and
        // only opening the phone app can change that.
        guard UserDefaults.standard.bool(forKey: "sendmeter.native.health-authorized") else {
            return .healthUnavailable()
        }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        let passTimeZone = TimeZone.current
        do {
            let result = try await computeAndPublishReadiness(
                userID: userID,
                trigger: .automatic,
                capturedBy: accountFetch,
                timeZone: passTimeZone
            )
            guard !Task.isCancelled, accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return .cancelled() }
            if let result {
                recordHealthSync(result.observation, capturedBy: accountFetch)
            }
            guard let metric = readiness else {
                // The phone has no published reading (an empty HealthKit
                // read, or a pass owned by another flight). Nothing is
                // blanked: the watch keeps the score it already shows.
                return .success(freshness: .cached, snapshot: nil)
            }
            return .success(
                freshness: lastReadinessPublicationFreshness,
                snapshot: SendLogWatchCore.ReadinessSnapshot(
                    date: metric.date,
                    readiness: metric.readiness,
                    zone: metric.zone,
                    computedAt: metric.computedAt.map(\.timeIntervalSince1970)
                )
            )
        } catch is CancellationError {
            return .cancelled()
        } catch {
            return .failed()
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
    private func computeAndPublishReadiness(
        userID: UUID,
        trigger: SyncTrigger,
        capturedBy capturedAccountFetch: AccountScopedFetch? = nil,
        timeZone: TimeZone
    ) async throws -> HealthSyncPassResult? {
        let accountFetch = capturedAccountFetch ?? AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        guard !Task.isCancelled, accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return nil }
        guard recomputeGate.request() == .start else { return nil }
        var acknowledgedReconciledDates = Set<String>()
        var sourceDataCount = 0
        do {
            while true {
                guard !Task.isCancelled else {
                    recomputeGate.cancel()
                    return nil
                }
                let now = Date()
                let passTimeZone = timeZone
                let localCalendar = LocalDateSupport.calendar(timeZone: passTimeZone)
                // The full existing window is required for historical
                // insert-if-missing reconciliation. A failed fetch aborts the
                // pass rather than risking duplicate or destructive writes.
                let existing = try await repository.fetchHealthMetrics(
                    limit: HealthMetricReadWindow.candidateDays
                )
                guard !Task.isCancelled, accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else {
                    recomputeGate.cancel()
                    return nil
                }
                let today = LocalDateSupport.string(
                    from: now,
                    timeZone: localCalendar.timeZone
                )
                let existingToday = existing.first { $0.date == today }
                let allowOverwrite = ReadinessWritePolicy.shouldOverwriteReadiness(
                    existingReadiness: existingToday?.readiness,
                    existingRowDate: existingToday?.date,
                    now: now,
                    trigger: trigger,
                    calendar: localCalendar
                )
                let acwrByDate = try await serverACWRSeries(
                    referenceDate: now,
                    timeZone: passTimeZone
                )
                guard !Task.isCancelled, accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else {
                    recomputeGate.cancel()
                    return nil
                }
                guard !Task.isCancelled else {
                    recomputeGate.cancel()
                    return nil
                }
                let fresh = try await health.computeMetrics(
                    acwrByDate: acwrByDate,
                    timeZone: passTimeZone
                )
                guard !Task.isCancelled, accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else {
                    recomputeGate.cancel()
                    return nil
                }
                let plan = HealthMetricReconciliationPolicy.plan(
                    freshMetrics: fresh,
                    existingMetrics: existing,
                    today: today,
                    allowTodayReadinessOverwrite: allowOverwrite,
                    timeZone: passTimeZone
                )
                guard !Task.isCancelled, accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else {
                    recomputeGate.cancel()
                    return nil
                }

                for upsert in plan.upserts {
                    guard !Task.isCancelled, accountFetch.canApply(
                        to: currentUserID,
                        accountEpoch: accountEpoch
                    ) else {
                        recomputeGate.cancel()
                        return nil
                    }
                    let operation = HealthMetricWritePolicy.operation(
                        for: upsert.date,
                        today: today
                    )
                    if operation == .historicalInsert {
                        do {
                            guard !Task.isCancelled else {
                                recomputeGate.cancel()
                                return nil
                            }
                            let inserted = try await repository
                                .insertHealthMetricIfMissing(
                                    upsert,
                                    userID: userID
                                )
                            guard !Task.isCancelled else {
                                recomputeGate.cancel()
                                return nil
                            }
                            let stillCurrent = accountFetch.canApply(
                                to: currentUserID,
                                accountEpoch: accountEpoch
                            )
                            if inserted {
                                guard !Task.isCancelled else {
                                    recomputeGate.cancel()
                                    return nil
                                }
                                // This is an acknowledged server row, not a
                                // local pending write. Keep it in the durable
                                // account cache, but publish only to the
                                // account/epoch that initiated the request.
                                cacheUpsertServer(
                                    upsert,
                                    accountUserID: userID,
                                    entityType: .healthMetrics,
                                    entityID: CacheEntityID.healthMetric(upsert)
                                )
                                guard !Task.isCancelled, stillCurrent else {
                                    recomputeGate.cancel()
                                    return nil
                                }
                                publishHealthMetric(upsert)
                                guard !Task.isCancelled else {
                                    recomputeGate.cancel()
                                    return nil
                                }
                                acknowledgedReconciledDates.insert(upsert.date)
                            }
                            guard !Task.isCancelled, stillCurrent else {
                                recomputeGate.cancel()
                                return nil
                            }
                        } catch {
                            if Task.isCancelled {
                                recomputeGate.cancel()
                                return nil
                            }
                            if accountFetch.canApply(
                                to: currentUserID,
                                accountEpoch: accountEpoch
                            ) {
                                throw error
                            }
                            recomputeGate.cancel()
                            return nil
                        }
                        continue
                    }

                    let publishedMetric = plan.relayMetric ?? upsert
                    let previousMetric = healthMetrics.first {
                        $0.date == upsert.date
                    }
                    guard !Task.isCancelled else {
                        recomputeGate.cancel()
                        return nil
                    }
                    let healthIntent = HealthWriteIntent(
                        date: upsert.date,
                        payload: upsert,
                        trigger: HealthWriteTrigger(trigger)
                    )
                    // #919 AC1: the intended write is durable BEFORE the
                    // optimistic row exists. A termination between the cache
                    // write, the remote write and its acknowledgement then
                    // leaves an intent the recovery resolves deterministically,
                    // instead of a cache-only row that nothing can ever
                    // distinguish from synced state.
                    guard let healthIntentItem = await enqueueDirectWrite(
                        .healthWrite(healthIntent),
                        capturedBy: accountFetch,
                        startUpload: false
                    ) else {
                        // No durable intent means no replay: the pass fails
                        // honestly rather than leaving an unreplayable row.
                        surfaceDirectWriteNotPersisted()
                        recomputeGate.cancel()
                        return nil
                    }
                    guard !Task.isCancelled, accountFetch.canApply(
                        to: currentUserID,
                        accountEpoch: accountEpoch
                    ) else {
                        recomputeGate.cancel()
                        return nil
                    }
                    let optimisticRevision = cacheUpsertLocal(
                        publishedMetric,
                        accountUserID: userID,
                        entityType: .healthMetrics,
                        entityID: CacheEntityID.healthMetric(publishedMetric)
                    )
                    do {
                        guard !Task.isCancelled else {
                            recomputeGate.cancel()
                            return nil
                        }
                        // #802 AC4: today's write goes through the server-side
                        // precedence RPC (atomic decide against the live row).
                        _ = try await repository.upsertHealthMetricWithPrecedence(
                            upsert,
                            userID: userID
                        )
                        guard !Task.isCancelled else {
                            recomputeGate.cancel()
                            return nil
                        }
                        let stillCurrent = accountFetch.canApply(
                            to: currentUserID,
                            accountEpoch: accountEpoch
                        )
                        guard !Task.isCancelled else {
                            recomputeGate.cancel()
                            return nil
                        }
                        // The server accepted this exact A-owned revision. Even
                        // if the user switched accounts while the request was
                        // suspended, acknowledge A's durable cache row; only
                        // visible-memory publication is fenced by the epoch.
                        cacheConfirmServerUpsert(
                            publishedMetric,
                            accountUserID: userID,
                            entityType: .healthMetrics,
                            entityID: CacheEntityID.healthMetric(publishedMetric),
                            confirmingLocalRevision: optimisticRevision,
                            publishPendingCount: stillCurrent
                        )
                        guard !Task.isCancelled, stillCurrent else {
                            recomputeGate.cancel()
                            return nil
                        }
                        acknowledgedReconciledDates.insert(upsert.date)
                        // #919: the server accepted this exact revision, so the
                        // durable intent is complete. A newer pass that replaced
                        // it while this request was in flight keeps its own
                        // intent (and its own acknowledgement).
                        await completeHealthWriteIntent(
                            healthIntentItem,
                            intent: healthIntent,
                            capturedBy: accountFetch
                        )
                    } catch {
                        if Task.isCancelled {
                            recomputeGate.cancel()
                            return nil
                        }
                        if accountFetch.canApply(
                            to: currentUserID,
                            accountEpoch: accountEpoch
                        ) {
                            if let previousMetric {
                                cacheConfirmServerUpsert(
                                    previousMetric,
                                    accountUserID: userID,
                                    entityType: .healthMetrics,
                                    entityID: CacheEntityID.healthMetric(previousMetric),
                                    confirmingLocalRevision: optimisticRevision
                                )
                            } else {
                                cacheConfirmServerDelete(
                                    accountUserID: userID,
                                    entityType: .healthMetrics,
                                    entityID: CacheEntityID.healthMetric(publishedMetric),
                                    confirmingLocalRevision: optimisticRevision
                                )
                            }
                            throw error
                        }
                        recomputeGate.cancel()
                        return nil
                    }
                    guard !Task.isCancelled else {
                        recomputeGate.cancel()
                        return nil
                    }
                    publishHealthMetric(publishedMetric)
                }

                guard !Task.isCancelled else {
                    recomputeGate.cancel()
                    return nil
                }
                if !plan.sourceDataDates.isEmpty {
                    sourceDataCount += plan.sourceDataDates.count
                }
                guard !Task.isCancelled, accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else {
                    recomputeGate.cancel()
                    return nil
                }
                if let relayMetric = plan.relayMetric {
                    guard !Task.isCancelled else {
                        recomputeGate.cancel()
                        return nil
                    }
                    publishHealthMetric(relayMetric)
                    guard !Task.isCancelled else {
                        recomputeGate.cancel()
                        return nil
                    }
                    // #913: the phone's readiness push is a typed result, and
                    // the freshness it reports is this pass's own decision. The
                    // upsert split is exactly that decision — the kept
                    // branches re-upsert the biometrics with readiness nil.
                    lastReadinessPublicationFreshness = plan.upserts.contains {
                        $0.date == relayMetric.date && $0.readiness != nil
                    } ? .fresh : .cached
                    watch.publishReadiness(
                        relayMetric,
                        freshness: lastReadinessPublicationFreshness
                    )
                }
                // Health reconciliation can touch the complete 28-day
                // candidate window. Publish once after the pass, rather than
                // once per historical row, so a single refresh causes one
                // App Group write and one WidgetKit reload.
                publishReadinessWidgetSnapshot()
                guard !Task.isCancelled else {
                    recomputeGate.cancel()
                    return nil
                }
                guard recomputeGate.complete() == .rerun else {
                    let observation = HealthSyncObservation.successful(
                        reconciledCount: acknowledgedReconciledDates.count,
                        sourceDataCount: sourceDataCount
                    )
                    return HealthSyncPassResult(
                        observation: observation,
                        acknowledgedReconciledDates: acknowledgedReconciledDates
                    )
                }
            }
        } catch {
            recomputeGate.cancel()
            throw error
        }
    }

    private func publishHealthMetric(_ metric: HealthMetric) {
        healthMetrics.removeAll { $0.date == metric.date }
        healthMetrics.append(metric)
        healthMetrics.sort { $0.date > $1.date }
    }

    /// ACWR ratios from server session loads for every date in the HealthKit
    /// window. The oldest health date needs its own 90-day EWMA history, so the
    /// server read extends beyond the current-day lookback.
    private func serverACWRSeries(
        referenceDate: Date,
        timeZone: TimeZone
    ) async throws -> [String: Double] {
        let days = TrainingMetrics.ewmaLookbackDays
            + HealthMetricReadWindow.candidateDays - 1
        let loads = try await repository.fetchSessionLoads(days: days)
        var loadByDate: [String: Double] = [:]
        for load in loads {
            guard let date = LocalDateSupport.canonicalDayKey(
                load.date,
                timeZone: timeZone
            ) else { continue }
            loadByDate[date, default: 0] += load.load
        }
        var result: [String: Double] = [:]
        for targetOffset in HealthMetricReadWindow.candidateOffsets {
            let targetDate = LocalDateSupport.daysAgo(
                targetOffset,
                from: referenceDate,
                timeZone: timeZone
            )
            var dailyLoads: [Double] = []
            dailyLoads.reserveCapacity(TrainingMetrics.ewmaLookbackDays)
            for historyOffset in stride(
                from: TrainingMetrics.ewmaLookbackDays - 1,
                through: 0,
                by: -1
            ) {
                let date = LocalDateSupport.daysAgo(
                    targetOffset + historyOffset,
                    from: referenceDate,
                    timeZone: timeZone
                )
                dailyLoads.append(loadByDate[date] ?? 0)
            }
            if let ratio = TrainingMetrics.acwrRatio(dailyLoads: dailyLoads) {
                result[targetDate] = ratio
            }
        }
        return result
    }

    private func healthLastSyncedDefaultsKey(for userID: UUID) -> String {
        "\(Self.healthLastSyncedDefaultsPrefix)\(userID.uuidString)"
    }

    private func healthMorningStartedDefaultsKey(for userID: UUID) -> String {
        "\(Self.healthMorningStartedDefaultsPrefix)\(userID.uuidString)"
    }

    private func healthMorningProgressDefaultsKey(for userID: UUID) -> String {
        "\(Self.healthMorningProgressDefaultsPrefix)\(userID.uuidString)"
    }

    private func loadMorningHealthProgress(
        for userID: UUID
    ) -> HealthMorningRefreshProgress? {
        let key = healthMorningProgressDefaultsKey(for: userID)
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return nil
        }
        do {
            let progress = try JSONDecoder().decode(
                HealthMorningRefreshProgress.self,
                from: data
            )
            guard progress.accountUserID == userID else {
                UserDefaults.standard.removeObject(forKey: key)
                return nil
            }
            return progress
        } catch {
            // Corrupt progress cannot safely be attributed to a new pass. Drop
            // only this account's malformed marker; the next supported event
            // can start a fresh window subject to the normal day gate.
            UserDefaults.standard.removeObject(forKey: key)
            if currentUserID == userID {
                lastHealthSyncObservation = .failed
            }
            return nil
        }
    }

    private func persistMorningHealthProgress(
        _ progress: HealthMorningRefreshProgress
    ) -> Bool {
        do {
            let data = try JSONEncoder().encode(progress)
            UserDefaults.standard.set(
                data,
                forKey: healthMorningProgressDefaultsKey(
                    for: progress.accountUserID
                )
            )
            return true
        } catch {
            return false
        }
    }

    private func clearMorningHealthProgress(for userID: UUID) {
        UserDefaults.standard.removeObject(
            forKey: healthMorningProgressDefaultsKey(for: userID)
        )
    }

    private func restoreHealthSyncState(for userID: UUID) {
        let key = healthLastSyncedDefaultsKey(for: userID)
        if let timestamp = UserDefaults.standard.object(forKey: key) as? Double {
            lastHealthSyncedAt = Date(timeIntervalSince1970: timestamp)
        } else {
            lastHealthSyncedAt = nil
        }
        let morningKey = healthMorningStartedDefaultsKey(for: userID)
        if let timestamp = UserDefaults.standard.object(forKey: morningKey) as? Double {
            lastMorningRefreshStartedAt = Date(timeIntervalSince1970: timestamp)
        } else {
            lastMorningRefreshStartedAt = nil
        }
        lastHealthSyncObservation = nil
    }

    /// Records a completed sync in state (lastHealthSyncedAt, persisted
    /// marker, lastHealthSyncObservation) without touching the toast: the
    /// trigger→toast decision belongs to the caller (#844).
    private func recordHealthSync(
        _ observation: HealthSyncObservation,
        capturedBy accountFetch: AccountScopedFetch
    ) {
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return }
        let now = Date()
        lastHealthSyncedAt = now
        UserDefaults.standard.set(
            now.timeIntervalSince1970,
            forKey: healthLastSyncedDefaultsKey(for: accountFetch.accountUserID)
        )
        lastHealthSyncObservation = observation
    }

    private func recordHealthSyncFailure(
        capturedBy accountFetch: AccountScopedFetch
    ) {
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return }
        lastHealthSyncObservation = .failed
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
        do {
            try await self.repository.deleteAccount()
            try await self.queue?.discardAll(accountUserID: userID, reason: "account-deleted")
            if let cachedWorkspace = self.cachedWorkspace {
                do {
                    try cachedWorkspace.store.deleteAccount(userID)
                } catch {
                    self.recordCacheFailure("cache delete account", error)
                }
            }
            // The watch completion inbox is a separate durable transport
            // store. Delete only this account's adopted/parked completions;
            // normal sign-out never reaches this path, and legacy ownerless
            // quarantine remains for explicit recovery/diagnostics.
            self.watch.discardStoredCompletions(for: userID)
            guard purgeBoundary.canApply(
                to: self.currentUserID,
                accountEpoch: self.accountEpoch
            ) else { return }
            self.pendingCacheWriteCount = 0
            self.pendingTagWriteCount = 0
            try await self.auth.signOut()
            guard purgeBoundary.canApply(
                to: self.currentUserID,
                accountEpoch: self.accountEpoch
            ) else { return }
            // Auth providers usually emit `.userDeleted`/`.signedOut`, but
            // the local boundary must not wait for that callback to remove a
            // deleted account from the visible workspace.
            self.watch.relaySession(nil)
            self.authSession = nil
            self.didBootstrapUserID = nil
            self.resetAccountState()
            self.bootState = .signedOut
            await self.tearDownRealtime()
        } catch {
            // If a newer account has already taken over, this is an old
            // deletion result/error and must not surface in its UI.
            if purgeBoundary.canApply(
                to: self.currentUserID,
                accountEpoch: self.accountEpoch
            ) {
                self.surface(error)
            }
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

    public func drainQueue(mode: QueueUploadMode = .automatic) async {
        guard let userID = currentUserID, let queue else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        // #935: the pass sequence (adopt the legacy residues, snapshot the
        // mode's due set from the ONE durable queue, attempt each item, then
        // acknowledge) is the recovery owner's. This body is composition only.
        _ = await mutationRecovery.drain(
            boundary: recoveryBoundary(accountFetch),
            mode: mode,
            in: queue,
            isCancelled: { Task.isCancelled },
            adoptResidues: {
                await self.adoptLegacyResidues(
                    userID: userID,
                    capturedBy: accountFetch
                )
            },
            upload: { item, itemMode in
                await self.upload(
                    item,
                    mode: itemMode,
                    capturedBy: accountFetch
                )
            },
            acknowledge: { await self.refreshQueueCount(for: accountFetch) }
        )
    }

    /// #935: the explicit account boundary of every recovery pass — the same
    /// `WorkspaceAccountBoundary` #934's workspace coordinator takes, so the app
    /// has ONE account fence rather than a second one for queue work.
    private func recoveryBoundary(_ accountFetch: AccountScopedFetch) -> WorkspaceAccountBoundary {
        WorkspaceAccountBoundary(fetch: accountFetch) { [weak self] in
            guard let self else { return false }
            return accountFetch.canApply(
                to: self.currentUserID,
                accountEpoch: self.accountEpoch
            )
        }
    }

    /// #920 AC2: the residue adopters, in the drain's load-bearing order. A
    /// cache-only row from an older app version carries no replay intent, so
    /// iterating the durable queue alone could never address it — which is
    /// exactly why the visible "Retry Now" has to run the same adopters the
    /// drain does. Extracted verbatim from `drainQueue` so both entry points
    /// share one implementation instead of two that can drift.
    private func adoptLegacyResidues(
        userID: UUID,
        capturedBy accountFetch: AccountScopedFetch
    ) async -> Bool {
        guard await migrateLegacyRecordingEdits(
            userID: userID,
            capturedBy: accountFetch
        ) != nil,
              accountFetch.canApply(
                  to: currentUserID,
                  accountEpoch: accountEpoch
              ) else { return false }
        // #916 AC4: a pending cache-only preset/routine row predates the
        // replay envelope; adopt it into this same queue before the pass
        // snapshots the due items, so the row is no longer intent-less.
        guard await migrateLegacyDirectWrites(
            userID: userID,
            capturedBy: accountFetch
        ),
              accountFetch.canApply(
                  to: currentUserID,
                  accountEpoch: accountEpoch
              ) else { return false }
        // #917 AC4: the phase/settings residue gets the same once-per-account
        // treatment (its only writer is a transition).
        guard await recoverLegacyPhaseResidues(
            userID: userID,
            capturedBy: accountFetch
        ),
              accountFetch.canApply(
                  to: currentUserID,
                  accountEpoch: accountEpoch
              ) else { return false }
        // #918 AC5: tag-registry residue (pending cache-only rows with no
        // intent) is resolved the same way — by the server's own answer only.
        guard await recoverLegacyTagResidues(
            userID: userID,
            capturedBy: accountFetch
        ),
              accountFetch.canApply(
                  to: currentUserID,
                  accountEpoch: accountEpoch
              ) else { return false }
        // #919: a pending cache-only health row predates the health replay
        // envelope. It is adopted into this same queue only when the server's
        // own answer leaves it provably writable (and the recovery revalidates
        // the payload again before anything is sent); anything else stays
        // visibly unsynced instead of being cleared on a guess.
        guard await recoverLegacyHealthResidues(
            userID: userID,
            capturedBy: accountFetch
        ),
              accountFetch.canApply(
                  to: currentUserID,
                  accountEpoch: accountEpoch
              ) else { return false }
        return true
    }

    public func retryAllQueuedWrites() async {
        guard let userID = currentUserID, let queue else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        // #920 AC4 / #935: one retry pass per account. A second tap while a
        // pass is in flight coalesces onto it (the pass's progress is already
        // published) instead of racing a second drain against the same queue.
        // The gate owns that rule; this body is composition only.
        guard let owner = queuedWritesRetryGate.claim(accountFetch) else { return }
        isRetryingQueuedWrites = true
        defer {
            // Only the pass that owns the flag may clear it, and only while its
            // account/epoch is still live: an account switch cannot finish the
            // next account's progress (#920 AC4).
            if queuedWritesRetryGate.finish(
                owner,
                isCurrent: accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                )
            ) {
                isRetryingQueuedWrites = false
            }
        }
        // Measure both acknowledged answers BEFORE the pass so the published
        // outcome is a real before/after rather than a guess.
        refreshPendingCacheWriteCount(accountUserID: userID)
        let unsyncedBefore = pendingCacheWriteCount
        // #920 AC2 / #935: Retry Now addresses the SAME residue set the drain
        // does, and each identity goes through the owner's manual-retry loop
        // (wait for an in-flight owner, re-read the durable item, then bypass
        // ordinary backoff but never quarantine).
        guard let report = await mutationRecovery.retryAll(
            boundary: recoveryBoundary(accountFetch),
            in: queue,
            adoptResidues: {
                await self.adoptLegacyResidues(
                    userID: userID,
                    capturedBy: accountFetch
                )
            },
            isClaimed: { [weak self] key in
                self?.inFlightUploadClaims.isClaimed(key) ?? false
            },
            waitForOwner: { [weak self] key in
                guard let self else { return }
                await self.waitForQueueUpload(key)
            },
            upload: { item, itemMode in
                await self.upload(
                    item,
                    mode: itemMode,
                    capturedBy: accountFetch
                )
            },
            acknowledge: { await self.refreshQueueCount(for: accountFetch) }
        ) else { return }
        let outcome = MutationRetryOutcome(
            accountUserID: userID,
            queuedBefore: report.queuedBefore,
            queuedAfter: queuedWriteCount,
            unsyncedBefore: unsyncedBefore,
            unsyncedAfter: pendingCacheWriteCount,
            quarantinedAfter: quarantinedWrites?.count
        )
        _ = accountFetch.publishIfCurrent(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) {
            lastRetryOutcome = outcome
        }
    }


    /// The BGTask body: drain the durable queue, then reconcile every cache
    /// entity through its cursor delta. Account scope and cancellation are
    /// re-checked after each await by `BackgroundSyncEngine`, so an account
    /// switch or sign-out while the task is suspended cannot write into the
    /// wrong account or advance a cursor after partial work.
    public func runBackgroundSync() async -> BackgroundSyncOutcome {
        guard let userID = currentUserID else { return .accountChanged }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        // The app-refresh task is another supported lifecycle signal for the
        // HealthKit path. Run its first pass before the cache engine so a
        // background wake can reconcile Apple Health even when no local cache
        // workspace is available; delayed morning re-polls are scheduled by
        // the same account-scoped window owner.
        if UserDefaults.standard.bool(forKey: "sendmeter.native.health-authorized") {
            await silentHealthRefresh(trigger: .background)
        }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else {
            return .accountChanged
        }
        guard !Task.isCancelled else { return .cancelled }
        // #921: a background app-refresh is the third cache-backed entrypoint
        // and joins the SAME preparation flight the bootstrap and the
        // foreground pass use — it never opens (or migrates) a second handle.
        // A cache that is still opening delays this pass, never the first
        // frame, and a failed open is retried here.
        await prepareCacheIfNeeded()
        guard let workspace = cachedWorkspace else {
            await drainQueue()
            return .failed
        }
        // Keep the existing drain-before-reconcile ordering, then take the
        // bounded server generation that decides whether the two
        // hard-delete-backed entities need an authoritative pass. The engine
        // still owns the per-entity account/cancellation guards; its drain is
        // a no-op here because this preflight has already drained exactly once.
        await drainQueue()
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else {
            return .accountChanged
        }
        guard !Task.isCancelled else { return .cancelled }
        // #934: the optional rollout endpoint and its "a missing generation
        // forces both purge-sensitive entities through a full reconcile"
        // fallback are the coordinator's rule. A background pass stays quiet
        // about a rollout error — the public foreground refresh reports it.
        let purgeResolution = await workspaceSync.resolvePurgeGeneration {
            try await self.repository.fetchPurgeSyncGeneration()
        }
        if purgeResolution.isAvailable {
            markPurgeGenerationAvailable(capturedBy: accountFetch)
        } else if Task.isCancelled {
            return .cancelled
        }
        let remotePurgeGeneration: Int64? = purgeResolution.generation
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else {
            return .accountChanged
        }
        guard !Task.isCancelled else { return .cancelled }
        let forcePurgeReconcile = await cacheNeedsPurgeReconcile(
            accountUserID: userID,
            remoteGeneration: remotePurgeGeneration
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
            drain: {},
            operations: makeBackgroundSyncOperations(
                accountUserID: userID,
                workspace: workspace,
                forcePurgeReconcile: forcePurgeReconcile,
                purgeGeneration: remotePurgeGeneration
            )
        )
        let outcome = await BackgroundSyncEngine.run(run)
        if case .completed = outcome {
            await publishBackgroundSyncSnapshot(
                accountUserID: userID,
                capturedBy: accountFetch
            )
        }
        return outcome
    }

    /// #934: composition only — one entry per workspace entity, naming the
    /// repository fetch and the full-snapshot shape. The shared rule (cursor
    /// read, full-vs-delta reconcile, purge generation, the storage hop) is the
    /// coordinator's `backgroundOperation`, so the background pass and the
    /// realtime slice reconciler stay one rule.
    private func makeBackgroundSyncOperations(
        accountUserID: UUID,
        workspace: CachedWorkspace,
        forcePurgeReconcile: Bool,
        purgeGeneration: Int64?
    ) -> [BackgroundSyncOperation] {
        let repository = repository
        return [
            workspaceSync.backgroundOperation(
                in: workspace,
                entityType: .sessions,
                accountUserID: accountUserID,
                forceFullReconcile: forcePurgeReconcile,
                purgeGeneration: purgeGeneration,
                fetch: { cursor in
                    try await repository.fetchSessionDelta(
                        since: cursor,
                        accountUserID: accountUserID
                    )
                },
                fullSnapshot: { CachedWorkspaceSnapshot(sessions: $0.activeValues) }
            ),
            workspaceSync.backgroundOperation(
                in: workspace,
                entityType: .settings,
                accountUserID: accountUserID,
                fetch: { cursor in
                    try await repository.fetchSettingsDelta(since: cursor)
                },
                fullSnapshot: { CachedWorkspaceSnapshot(settings: $0.activeValues.first) }
            ),
            workspaceSync.backgroundOperation(
                in: workspace,
                entityType: .phasePeriods,
                accountUserID: accountUserID,
                fetch: { cursor in
                    try await repository.fetchPhasePeriodDelta(since: cursor)
                },
                fullSnapshot: { CachedWorkspaceSnapshot(phasePeriods: $0.activeValues) }
            ),
            workspaceSync.backgroundOperation(
                in: workspace,
                entityType: .healthMetrics,
                accountUserID: accountUserID,
                fetch: { cursor in
                    try await repository.fetchHealthMetricDelta(since: cursor)
                },
                fullSnapshot: { CachedWorkspaceSnapshot(healthMetrics: $0.activeValues) }
            ),
            workspaceSync.backgroundOperation(
                in: workspace,
                entityType: .recordings,
                accountUserID: accountUserID,
                forceFullReconcile: forcePurgeReconcile,
                purgeGeneration: purgeGeneration,
                fetch: { cursor in
                    try await repository.fetchRecordingDelta(since: cursor)
                },
                fullSnapshot: { CachedWorkspaceSnapshot(recordings: $0.activeValues) }
            ),
            workspaceSync.backgroundOperation(
                in: workspace,
                entityType: .presets,
                accountUserID: accountUserID,
                fetch: { cursor in
                    try await repository.fetchPresetDelta(since: cursor)
                },
                fullSnapshot: { CachedWorkspaceSnapshot(presets: $0.activeValues) }
            ),
            workspaceSync.backgroundOperation(
                in: workspace,
                entityType: .routinePresets,
                accountUserID: accountUserID,
                fetch: { cursor in
                    try await repository.fetchRoutineDelta(since: cursor)
                },
                fullSnapshot: { CachedWorkspaceSnapshot(routines: $0.activeValues) }
            ),
            workspaceSync.backgroundOperation(
                in: workspace,
                entityType: .workoutsAndAttempts,
                accountUserID: accountUserID,
                fetch: { cursor in
                    try await repository.fetchWorkoutDelta(since: cursor)
                },
                fullSnapshot: { CachedWorkspaceSnapshot(workouts: $0.activeValues) }
            ),
            workspaceSync.backgroundOperation(
                in: workspace,
                entityType: .tagMetadata,
                accountUserID: accountUserID,
                fetch: { cursor in
                    try await repository.fetchTagMetadataDelta(since: cursor)
                },
                fullSnapshot: { CachedWorkspaceSnapshot(tagMetadata: $0.activeValues) }
            )
        ]
    }

    private func publishBackgroundSyncSnapshot(
        accountUserID: UUID,
        capturedBy accountFetch: AccountScopedFetch
    ) async {
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return }
        // #922: ONE coherent read on the storage side serves the whole
        // publication — the collections, the two sync boundaries and the
        // non-overlay lists. It used to be a load plus two boundary reads plus
        // a second full-workspace load inside the re-adoption.
        guard let read = await readCoherentCache(accountUserID: accountUserID) else { return }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return }
        let snapshot = read.snapshot
        let sessionsWereSynced = read.hasCompletedSync(.sessions)
        let recordingsWereSynced = read.hasCompletedSync(.recordings)
        applyCachedNonOverlayLists(accountUserID: accountUserID, read: read)
        mergeSessions(
            remote: snapshot.sessions,
            markLoaded: sessionsWereSynced
        )
        hasLoadedSessions = hasLoadedSessions || sessionsWereSynced
        mergeRecordings(remote: snapshot.recordings)
        hasLoadedRecordings = hasLoadedRecordings || recordingsWereSynced
        forceModel.hasLoadedRecordings = hasLoadedRecordings
        warmTagCurvesIfMissing(capturedBy: accountFetch)
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
                editorBatchAccepted = try await queue.enqueue(items)
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

    /// #675 N1 / #935: the classification + diagnostic one failed attempt
    /// recorded, so the recovery owner can decide whether a manual retry
    /// replaces the prior rejection stamp or restores it verbatim. These are
    /// the OWNER's types (`Sources/Core/MutationRecoveryCoordinator.swift`);
    /// the aliases keep this file's call sites reading the same and there is
    /// exactly ONE upload-outcome shape in the app.
    private typealias UploadFailure = MutationUploadFailure
    private typealias UploadResult = MutationUploadOutcome

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

    private func pendingSessionInsert(for payload: PendingWrite) -> PendingSessionInsert? {
        switch payload {
        case let .session(insert):
            return .loggedSession(sessionID: insert.id)
        case let .workout(draft):
            return .manualWorkout(sessionID: draft.sessionID)
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

    // MARK: Direct-write replay (#916)

    /// The repository mutations one direct-write entity kind exposes, plus its
    /// authoritative list. Keeps the replay below shared between presets and
    /// routines (and the later direct-write slices that adopt the envelope).
    private struct DirectWriteRemote<Value> {
        let fetch: () async throws -> [Value]
        let insert: (Value) async throws -> Value
        let update: (Value) async throws -> Value
        let delete: (UUID) async throws -> Void
    }

    /// What one replayed direct-write intent did to the server.
    private enum DirectWriteOutcome<Value> {
        /// The intended mutation is on the server: inserted, patched, or
        /// already there after a lost acknowledgement (adopted as-is).
        case saved(Value)
        /// The entity is gone: the delete landed, or the server had provably
        /// nothing to delete. `removedEntityID` is the identity a
        /// server-minted row was removed by, when that differed from the
        /// identity the intent carried.
        case deleted(removedEntityID: String?)
    }

    /// Replays one durable direct-write intent against the server.
    ///
    /// `create` asks the authoritative list first: `tindeq_presets` and
    /// `routine_presets` mint their own row id and the insert payload carries
    /// none, so a blind retry after a lost acknowledgement would insert a
    /// SECOND row — an active row that already carries the intended content IS
    /// that acknowledgement. `update` is a PATCH by identity, idempotent by
    /// construction. `delete` resolves its target the same way before removing
    /// it, so a create that landed with a server-minted id is removed rather
    /// than resurrected, and a delete of something the server no longer has is
    /// provably a no-op instead of a guessed write.
    private func applyDirectWriteIntent<Value: DirectWriteEntityValue>(
        _ intent: DirectWriteIntent<Value>,
        remote: DirectWriteRemote<Value>
    ) async throws -> DirectWriteOutcome<Value> {
        switch intent.operation {
        case .create:
            guard let intended = intent.mutation else {
                // The write paths always persist the intended row, so this is
                // reachable only from a corrupt queue file. It must not be
                // invented from later state: the intent is parked as a failure
                // (and quarantined after its bounded attempts) instead.
                throw DirectWriteReplayError.missingIntendedMutation
            }
            if let alreadyApplied = DirectWriteReplayPolicy.alreadyApplied(
                intended: intended,
                serverValues: try await remote.fetch()
            ) {
                return .saved(alreadyApplied)
            }
            return .saved(try await remote.insert(intended))
        case .update:
            guard let intended = intent.mutation else {
                throw DirectWriteReplayError.missingIntendedMutation
            }
            return .saved(try await remote.update(intended))
        case .delete:
            let serverValues = try await remote.fetch()
            let target = serverValues.first {
                $0.directWriteID.uuidString.lowercased() == intent.entityID.lowercased()
            } ?? intent.mutation.flatMap { mutation in
                DirectWriteReplayPolicy.alreadyApplied(
                    intended: mutation,
                    serverValues: serverValues
                )
            }
            guard let target else {
                // Provably nothing to delete: no row under the intended
                // identity and none carrying the intended content.
                return .deleted(removedEntityID: nil)
            }
            try await remote.delete(target.directWriteID)
            return .deleted(removedEntityID: target.directWriteID.uuidString)
        }
    }

    /// Reconciles one saved direct-write entity into the account cache.
    ///
    /// The identity is unchanged on the server, so the ordinary revision-fenced
    /// confirmation applies: an older acknowledgement therefore cannot clear a
    /// newer pending local revision. When the server minted a DIFFERENT row id
    /// (an insert without a client id), the local optimistic identity can never
    /// receive a confirmation: it is retired rather than left pending for ever,
    /// and the server row is stored as clean server state.
    ///
    /// - Returns: whether this acknowledgement is still the newest local
    ///   revision for the entity. `false` means a newer local edit replaced the
    ///   acknowledged one while the request was in flight, so the caller must
    ///   not publish the (older) server row over it.
    @discardableResult
    private func confirmDirectWriteSaved<Value: DirectWriteEntityValue>(
        _ saved: Value,
        intent: DirectWriteIntent<Value>,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        cacheRevisions: [CacheEntityIdentity: Int]
    ) -> Bool {
        let savedEntityID = saved.directWriteID.uuidString
        if savedEntityID.lowercased() == intent.entityID.lowercased() {
            let captured = cacheConfirmationRevision(
                cacheRevisions,
                entityType: entityType,
                entityID: savedEntityID
            )
            let current: Int? = try? cachedWorkspace?.localRevision(
                accountUserID: accountUserID,
                entityType: entityType,
                entityID: savedEntityID
            )
            guard captured == current else { return false }
            cacheConfirmServerUpsert(
                saved,
                accountUserID: accountUserID,
                entityType: entityType,
                entityID: savedEntityID,
                confirmingLocalRevision: captured
            )
            return true
        }
        cacheUpsertServer(
            saved,
            accountUserID: accountUserID,
            entityType: entityType,
            entityID: savedEntityID
        )
        cacheConfirmServerDelete(
            accountUserID: accountUserID,
            entityType: entityType,
            entityID: intent.entityID,
            confirmingLocalRevision: cacheConfirmationRevision(
                cacheRevisions,
                entityType: entityType,
                entityID: intent.entityID
            )
        )
        return true
    }

    /// Retires the local rows for one completed direct-write delete: the
    /// identity the intent carried, plus the identity a server-minted row was
    /// removed by when the two differ (the create's row, adopted by content).
    private func retireDirectWriteLocalRows<Value: DirectWriteEntityValue>(
        intent: DirectWriteIntent<Value>,
        removedEntityID: String?,
        accountUserID: UUID,
        entityType: LocalCacheEntityType,
        cacheRevisions: [CacheEntityIdentity: Int]
    ) {
        var entityIDs = [intent.entityID]
        if let removedEntityID,
           removedEntityID.lowercased() != intent.entityID.lowercased() {
            entityIDs.append(removedEntityID)
        }
        for entityID in entityIDs {
            cacheConfirmServerDelete(
                accountUserID: accountUserID,
                entityType: entityType,
                entityID: entityID,
                confirmingLocalRevision: cacheConfirmationRevision(
                    cacheRevisions,
                    entityType: entityType,
                    entityID: entityID
                )
            )
        }
    }

    /// Records one completed direct-write delete as terminal for its entity:
    /// the queue item (and any other item for that identity) leaves in the same
    /// durable transaction as the marker, so a later write for the identity
    /// cannot enqueue and cannot resurrect what the user removed. Returns false
    /// when a newer intent replaced the claimed one — that replacement stays
    /// durable for a later retry.
    @discardableResult
    private func terminalizeDirectWrite(
        _ item: DurableQueueItem<PendingWrite>,
        entityID: UUID,
        operationID: UUID,
        reason: String,
        capturedBy accountFetch: AccountScopedFetch
    ) async -> Bool {
        guard let queue else { return false }
        do {
            return try await queue.completeTerminalDelete(
                id: item.id,
                accountUserID: item.accountUserID,
                expectedRevision: item.revision,
                terminalKey: entityID,
                operationID: operationID,
                reason: reason
            )
        } catch {
            if accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch) {
                surface(error)
            }
            return false
        }
    }

    /// Starts the single-flight upload for one freshly persisted direct-write
    /// item. Separate from the enqueue so the optimistic local row exists
    /// before a request can claim it: a fast acknowledgement would otherwise
    /// have no row to confirm and would leave it pending for ever.
    private func startQueueUpload(
        _ item: DurableQueueItem<PendingWrite>,
        capturedBy accountFetch: AccountScopedFetch
    ) {
        Task { [weak self] in
            _ = await self?.upload(item, capturedBy: accountFetch)
        }
    }

    /// Persists one direct-write intent for an entity, coalescing it onto the
    /// pending intent of the same entity when there is one.
    ///
    /// Returns the durable queue item, or `nil` when the intent was NOT
    /// persisted — an unavailable queue, a persistence error, an account
    /// change, or an identity whose delete is already terminal. The caller must
    /// then report the write as failed instead of accepted: this call is the
    /// durability boundary, and without a persisted intent there is no replay.
    private func enqueueDirectWrite(
        _ payload: PendingWrite,
        capturedBy accountFetch: AccountScopedFetch,
        startUpload: Bool
    ) async -> DurableQueueItem<PendingWrite>? {
        guard let queue,
              let incomingEntityID = payload.directWriteEntityID(
                  accountUserID: accountFetch.accountUserID
              ) else { return nil }
        for _ in 0..<3 {
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return nil }
            // #918: a tag's pending intent is resolved by the NAME the mutation
            // is authored against — its own, or the one a still-pending rename
            // moved the tag to — because that is the identity the newer mutation
            // has to replace. Every other payload is keyed by its own identity.
            let existing: DurableQueueItem<PendingWrite>?
            if case let .tagMutation(intent) = payload {
                existing = await pendingTagMutation(
                    named: intent.tagName,
                    accountUserID: accountFetch.accountUserID
                )
            } else {
                existing = await queue.item(
                    id: incomingEntityID,
                    accountUserID: accountFetch.accountUserID
                )
            }
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return nil }

            let queuedPayload: PendingWrite
            if payload.replacesPendingWithNewest {
                // #917: the phase transition's plan already carries the older
                // transition's local effects, so the newest intent replaces the
                // pending one wholesale — there is no create/update/delete
                // vocabulary to coalesce.
                queuedPayload = payload
            } else if case let .tagMutation(incoming) = payload {
                // #918: the pending tag intent keeps the names it may still have
                // to repoint from and the rename it carries; the newest mutation
                // contributes its own name and its visibility. The composed
                // intent keeps the ORIGIN name's queue identity, so it replaces
                // the pending item instead of racing it.
                if case let .tagMutation(pending)? = existing?.payload {
                    queuedPayload = .tagMutation(
                        TagMutationReplayPolicy.replacing(
                            pending: pending,
                            incoming: incoming
                        )
                    )
                } else {
                    queuedPayload = payload
                }
            } else {
                guard let incoming = payload.directWriteOperation else { return nil }
                let operation: DirectWriteOperation
                if let pendingOperation = existing?.payload.directWriteOperation {
                    guard let coalesced = DirectWriteReplayPolicy.coalesce(
                        pending: pendingOperation,
                        incoming: incoming
                    ) else {
                        // The entity's removal is already the newest word for this
                        // identity; persisting the write would resurrect it.
                        surfaceDirectWriteNotPersisted()
                        return nil
                    }
                    operation = coalesced
                } else {
                    operation = incoming
                }
                guard let relabeled = payload.relabeled(with: operation) else {
                    return nil
                }
                queuedPayload = relabeled
            }
            guard let entityID = queuedPayload.directWriteEntityID(
                accountUserID: accountFetch.accountUserID
            ) else { return nil }
            let item = DurableQueueItem(
                id: entityID,
                accountUserID: accountFetch.accountUserID,
                terminalKey: entityID,
                payload: queuedPayload
            )
            do {
                let installed = try await queue.enqueueIfCurrent(
                    item,
                    expectedRevision: existing?.revision
                )
                guard installed else {
                    if await queue.terminalizedKeys(
                        for: accountFetch.accountUserID
                    ).contains(entityID) {
                        surfaceDirectWriteNotPersisted()
                        return nil
                    }
                    // A concurrent producer replaced the intent between the read
                    // and the write: re-read and coalesce onto the newest one.
                    continue
                }
            } catch {
                if accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) {
                    surface(error)
                }
                await refreshQueueCount(for: accountFetch)
                return nil
            }
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return nil }
            await refreshQueueCount(for: accountFetch)
            if startUpload {
                startQueueUpload(item, capturedBy: accountFetch)
            }
            return item
        }
        surfaceDirectWriteNotPersisted()
        return nil
    }

    /// The still-pending tag intent a newer mutation for `name` has to replace:
    /// the intent authored against that name, or the one a still-pending rename
    /// moved the tag to (#918). The queue holds at most ONE intent per tag, so
    /// this is the only lookup the tag write path needs.
    private func pendingTagMutation(
        named name: String,
        accountUserID: UUID
    ) async -> DurableQueueItem<PendingWrite>? {
        guard let queue else { return nil }
        let queued = await queue.items(for: accountUserID, includeQuarantined: true)
        return queued.first { item in
            guard case let .tagMutation(intent) = item.payload else { return false }
            // The user's next mutation is authored against the name the tag has
            // LOCALLY — which is a still-pending rename's target until it lands.
            return intent.tagName == name || intent.renamedTo == name
        }
    }

    /// The tag names with a durable intent in the queue — any state, including
    /// quarantined, because a quarantined intent is still the user's own unsynced
    /// data and the residue sweep must not resolve the row it owns (#918).
    private func queueItemsTagNames(userID: UUID) async -> [String] {
        guard let queue else { return [] }
        return await queue.items(for: userID, includeQuarantined: true).compactMap { item in
            guard case let .tagMutation(intent) = item.payload else { return nil }
            return intent.tagName
        }
    }

    /// The user-facing failure for a write that could not become durable. The
    /// queue is the durability boundary, so this is reported as a failure the
    /// user can retry — never as a saved or synced state.
    private func surfaceDirectWriteNotPersisted() {
        surface(NSError(
            domain: "SendmeterNative",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey: "This change couldn't be saved on this device.",
            ]
        ))
    }

    /// #916 AC4: adopts pending CACHE-ONLY rows for one direct-write entity
    /// type into the durable queue.
    ///
    /// These rows are the pre-#916 residue: an optimistic row whose upload
    /// never confirmed, left with no replay intent after process death. The row
    /// itself is the evidence (`DirectWriteReplayPolicy.legacyOperation`) and
    /// the operation it carries is resolved against the authoritative list
    /// before anything is sent, so nothing is guessed and nothing is cleared:
    /// a row whose payload cannot be decoded stays in the unsynced count for
    /// the user to act on, and the row is only retired when the server's own
    /// answer proves it is resolved.
    private func adoptLegacyDirectWrites<Value: DirectWriteEntityValue & Codable>(
        entityType: LocalCacheEntityType,
        accountUserID: UUID,
        capturedBy accountFetch: AccountScopedFetch,
        decode: (String) -> Value?,
        fetchServerValues: () async throws -> [Value],
        wrap: (DirectWriteIntent<Value>) -> PendingWrite
    ) async -> Bool {
        guard let queue, let workspace = cachedWorkspace else { return true }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return false }
        let queuedIDs = Set(await queue.items(
            for: accountUserID,
            includeQuarantined: true
        ).compactMap {
            $0.payload.directWriteEntityID(accountUserID: accountUserID)?.uuidString.lowercased()
        })
        guard let allPending = try? workspace.pendingEntityIDs(
            accountUserID: accountUserID,
            entityType: entityType,
            includingDeleted: true
        ) else { return false }
        let livePending = (try? workspace.pendingEntityIDs(
            accountUserID: accountUserID,
            entityType: entityType
        )) ?? []
        let liveIDs = Set(livePending.map { $0.lowercased() })
        let legacyIDs = allPending.filter { !queuedIDs.contains($0.lowercased()) }
        guard !legacyIDs.isEmpty else { return true }
        // Only a live legacy row needs the authoritative list (to tell an
        // update from a create). Tombstones are resolved by the list too, so
        // one fetch covers both; a failed fetch defers the whole migration
        // rather than guessing an operation.
        let serverValues: [Value]
        do {
            serverValues = try await fetchServerValues()
        } catch {
            guard !Task.isCancelled else { return false }
            return false
        }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return false }
        for entityID in legacyIDs {
            let isTombstoned = !liveIDs.contains(entityID.lowercased())
            let decoded = isTombstoned ? nil : decode(entityID)
            if !isTombstoned, decoded == nil {
                // Undecodable payload: it cannot be replayed and must not be
                // cleared. It keeps counting as unsynced (needs attention).
                continue
            }
            let operation = DirectWriteReplayPolicy.legacyOperation(
                isTombstoned: isTombstoned,
                serverHasEntity: decoded.map { value in
                    serverValues.contains { $0.directWriteID == value.directWriteID }
                } ?? false
            )
            guard await enqueueDirectWrite(
                wrap(
                    DirectWriteIntent(
                        entityID: entityID,
                        operation: operation,
                        mutation: decoded
                    )
                ),
                capturedBy: accountFetch,
                startUpload: false
            ) != nil else { return false }
        }
        return true
    }

    /// The drain-path entry point for the #916 AC4 adoption, once per account
    /// per process: the legacy residue is finite and adopting it costs one list
    /// fetch per entity type, not one per drain.
    private func migrateLegacyDirectWrites(
        userID: UUID,
        capturedBy capturedAccountFetch: AccountScopedFetch? = nil
    ) async -> Bool {
        guard queue != nil else { return true }
        guard !migratedDirectWriteAccounts.contains(userID) else { return true }
        let accountFetch = capturedAccountFetch ?? AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        let presetsAdopted = await adoptLegacyDirectWrites(
            entityType: .presets,
            accountUserID: userID,
            capturedBy: accountFetch,
            decode: { entityID in
                try? self.cachedWorkspace?.store.loadOne(
                    TindeqPreset.self,
                    accountUserID: userID,
                    entityType: .presets,
                    entityID: entityID
                )
            },
            fetchServerValues: { [repository] in try await repository.fetchPresets() },
            wrap: { .preset($0) }
        )
        guard presetsAdopted else { return false }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return false }
        let routinesAdopted = await adoptLegacyDirectWrites(
            entityType: .routinePresets,
            accountUserID: userID,
            capturedBy: accountFetch,
            decode: { entityID in
                try? self.cachedWorkspace?.store.loadOne(
                    RoutinePreset.self,
                    accountUserID: userID,
                    entityType: .routinePresets,
                    entityID: entityID
                )
            },
            fetchServerValues: { [repository] in try await repository.fetchRoutinePresets() },
            wrap: { .routine($0) }
        )
        guard routinesAdopted else { return false }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return false }
        migratedDirectWriteAccounts.insert(userID)
        return true
    }

    /// #917 AC4: resolves the pre-#917 phase/settings residue — pending
    /// cache-only rows for the two entity types a transition writes, left with
    /// no replay intent at all by an interrupted older build.
    ///
    /// Only PROVABLE outcomes are resolved, and nothing is reconstructed from a
    /// local row alone (a period is only ever written through a transition, and
    /// a locally created period's id is never the server's):
    ///
    /// * a live pending row the server already serves with the same content IS
    ///   the write, so the server row is adopted and the optimistic identity
    ///   retired;
    /// * a pending tombstone whose identity the server no longer serves is a
    ///   delete that is already effective — there is nothing left to remove;
    /// * the settings row, a per-account singleton upserted by user id, is
    ///   retired when the server already serves exactly the pending value.
    ///
    /// Everything else stays exactly where it is and keeps counting as unsynced
    /// (the Settings "unsynced" surface): no local change is lost, and none is
    /// invented.
    private func recoverLegacyPhaseResidues(
        userID: UUID,
        capturedBy accountFetch: AccountScopedFetch
    ) async -> Bool {
        guard let queue, let workspace = cachedWorkspace else { return true }
        guard !recoveredPhaseResidueAccounts.contains(userID) else { return true }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return false }
        let queued = await queue.items(for: userID, includeQuarantined: true)
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return false }
        guard !queued.contains(where: { $0.id == PhaseTransitionIntent.queueItemID }) else {
            // A durable transition owns both entity types: there is no
            // intent-less residue to resolve, and the intent is the account's
            // newest word for them.
            recoveredPhaseResidueAccounts.insert(userID)
            return true
        }
        let pendingPeriodIDs = (try? workspace.pendingEntityIDs(
            accountUserID: userID,
            entityType: .phasePeriods,
            includingDeleted: true
        )) ?? []
        let livePeriodIDs = Set((try? workspace.pendingEntityIDs(
            accountUserID: userID,
            entityType: .phasePeriods
        )) ?? [])
        let pendingSettingsIDs = (try? workspace.pendingEntityIDs(
            accountUserID: userID,
            entityType: .settings,
            includingDeleted: true
        )) ?? []
        guard !pendingPeriodIDs.isEmpty || !pendingSettingsIDs.isEmpty else {
            recoveredPhaseResidueAccounts.insert(userID)
            return true
        }
        let periods: [PhasePeriod]
        let settings: UserSettings?
        do {
            periods = try await repository.fetchPhasePeriods()
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return false }
            settings = try await repository.fetchSettingsDelta(since: nil)
                .activeValues
                .first
        } catch {
            // A failed authoritative read defers the whole sweep rather than
            // resolving anything on a guess.
            return false
        }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return false }
        let serverIDs = Set(periods.map { $0.id.uuidString.lowercased() })
        for entityID in pendingPeriodIDs {
            guard let revision = try? workspace.localRevision(
                accountUserID: userID,
                entityType: .phasePeriods,
                entityID: entityID
            ) else { continue }
            if !livePeriodIDs.contains(entityID) {
                // A tombstone. When the server no longer serves the identity,
                // the removal the user asked for is already effective. When it
                // still does, removing a period needs a transition (and a
                // target block), so it keeps counting as unsynced.
                guard !serverIDs.contains(entityID.lowercased()) else { continue }
                cacheConfirmServerDelete(
                    accountUserID: userID,
                    entityType: .phasePeriods,
                    entityID: entityID,
                    confirmingLocalRevision: revision
                )
                continue
            }
            guard let local = try? workspace.store.loadOne(
                PhasePeriod.self,
                accountUserID: userID,
                entityType: .phasePeriods,
                entityID: entityID
            ), let adopted = periods.first(where: {
                $0.phase == local.phase
                    && $0.startedOn == local.startedOn
                    && $0.endedOn == local.endedOn
            }) else { continue }
            if adopted.id.uuidString.lowercased() == entityID.lowercased() {
                // The server serves the identical row under the same id: the
                // write is confirmed, not retired.
                cacheConfirmServerUpsert(
                    adopted,
                    accountUserID: userID,
                    entityType: .phasePeriods,
                    entityID: entityID,
                    confirmingLocalRevision: revision
                )
            } else {
                // The server minted its own id for the period this row
                // created: adopt the server row and retire the local identity.
                cacheConfirmServerDelete(
                    accountUserID: userID,
                    entityType: .phasePeriods,
                    entityID: entityID,
                    confirmingLocalRevision: revision
                )
                cacheUpsertServer(
                    adopted,
                    accountUserID: userID,
                    entityType: .phasePeriods,
                    entityID: adopted.id.uuidString
                )
            }
        }
        for entityID in pendingSettingsIDs {
            guard let revision = try? workspace.localRevision(
                accountUserID: userID,
                entityType: .settings,
                entityID: entityID
            ), let local = try? workspace.store.loadOne(
                UserSettings.self,
                accountUserID: userID,
                entityType: .settings,
                entityID: entityID
            ) else { continue }
            // The settings row is the same singleton (`user_id` upsert) the
            // transition writes, so the server serving exactly the pending
            // value is proof that the write landed. A settings row that
            // DISAGREES with the authoritative periods cannot be replayed
            // without inventing a transition — it stays counted as unsynced.
            guard local == settings else { continue }
            cacheConfirmServerUpsert(
                local,
                accountUserID: userID,
                entityType: .settings,
                entityID: entityID,
                confirmingLocalRevision: revision
            )
        }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return false }
        recoveredPhaseResidueAccounts.insert(userID)
        refreshPendingCacheWriteCount(accountUserID: userID)
        return true
    }

    /// #918 AC5: resolves the pre-#918 tag residue — pending cache-only
    /// `.tagMetadata` rows left by an interrupted older build, with no replay
    /// intent behind them.
    ///
    /// A registry row is `name` + `hidden` and nothing else, so a rename can
    /// never be reconstructed from one and nothing is invented here. Only the
    /// server's own answer resolves a row:
    ///
    /// * a live pending row the server already serves with the same flag IS the
    ///   write, so it is confirmed;
    /// * a pending tombstone whose name the server no longer serves is a removal
    ///   that already took effect (that is exactly what a rename leaves behind).
    ///
    /// Everything else stays where it is and keeps counting as unsynced — the
    /// Settings surface shows it and the user's next action on that tag (a new
    /// hide/rename intent) is what resolves it. Nothing is dropped on a guess.
    private func recoverLegacyTagResidues(
        userID: UUID,
        capturedBy accountFetch: AccountScopedFetch
    ) async -> Bool {
        guard queue != nil, let workspace = cachedWorkspace else { return true }
        guard !recoveredTagResidueAccounts.contains(userID) else { return true }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return false }
        let pendingIDs = (try? workspace.pendingEntityIDs(
            accountUserID: userID,
            entityType: .tagMetadata,
            includingDeleted: true
        )) ?? []
        guard !pendingIDs.isEmpty else {
            recoveredTagResidueAccounts.insert(userID)
            return true
        }
        let queuedNames = Set(await queueItemsTagNames(userID: userID))
        let residueIDs = pendingIDs.filter { !queuedNames.contains($0) }
        guard !residueIDs.isEmpty else {
            recoveredTagResidueAccounts.insert(userID)
            return true
        }
        let serverTags: [TagMetadata]
        do {
            serverTags = try await repository.fetchTagMetadata()
        } catch {
            // A failed authoritative read defers the whole sweep rather than
            // resolving anything on a guess.
            return false
        }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return false }
        for entityID in residueIDs {
            guard let revision = try? workspace.localRevision(
                accountUserID: userID,
                entityType: .tagMetadata,
                entityID: entityID
            ) else { continue }
            if let local = try? workspace.store.loadOne(
                TagMetadata.self,
                accountUserID: userID,
                entityType: .tagMetadata,
                entityID: entityID
            ) {
                guard serverTags.contains(where: {
                    $0.name == local.name && $0.hidden == local.hidden
                }) else { continue }
                cacheConfirmServerUpsert(
                    local,
                    accountUserID: userID,
                    entityType: .tagMetadata,
                    entityID: entityID,
                    confirmingLocalRevision: revision
                )
            } else {
                guard !serverTags.contains(where: { $0.name == entityID }) else { continue }
                cacheConfirmServerDelete(
                    accountUserID: userID,
                    entityType: .tagMetadata,
                    entityID: entityID,
                    confirmingLocalRevision: revision
                )
            }
        }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return false }
        recoveredTagResidueAccounts.insert(userID)
        refreshPendingCacheWriteCount(accountUserID: userID)
        return true
    }

    // MARK: Health write recovery (#919)

    /// The authoritative state one replayed health write settled in: the
    /// server's own row for the date.
    private struct HealthWriteOutcome {
        let row: HealthMetric
    }

    /// Resolves one durable health write intent against the server (#919).
    ///
    /// Nothing is replayed blindly. The server's CURRENT row is read first and
    /// `HealthWriteReplayPolicy` decides whether the queued payload is already
    /// applied (a lost acknowledgement), is superseded by fresher server data,
    /// or must still be written under the current write policy. When it must,
    /// the payload the policy re-derived is what gets sent — today through the
    /// #802 precedence RPC, a date that has since become past through the
    /// atomic insert-if-missing — and the server's own answer is read back as
    /// the confirmation.
    ///
    /// Deliberately no HealthKit call happens here: recovery replays the
    /// persisted payload and never re-runs biometric work to invent evidence.
    private func applyHealthWriteIntent(
        _ intent: HealthWriteIntent,
        userID: UUID
    ) async throws -> HealthWriteOutcome {
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        let decision = HealthWriteReplayPolicy.decide(
            intent: intent,
            serverRow: try await fetchServerHealthRow(date: intent.date),
            now: Date(),
            timeZone: TimeZone.current
        )
        switch decision {
        case let .alreadyApplied(serverRow), let .superseded(serverRow):
            return HealthWriteOutcome(row: serverRow)
        case let .send(payload, operation):
            switch operation {
            case .historicalInsert:
                _ = try await repository.insertHealthMetricIfMissing(
                    payload,
                    userID: userID
                )
            case .todayMerge:
                _ = try await repository.upsertHealthMetricWithPrecedence(
                    payload,
                    userID: userID
                )
            }
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else {
                throw CancellationError()
            }
            // The confirmation is the server's own row, never the request we
            // just sent: a request that was applied-but-unacknowledged must not
            // be reported as complete from our own side of the wire.
            guard let confirmed = try await fetchServerHealthRow(date: intent.date) else {
                throw HealthWriteReplayError.unconfirmedWrite
            }
            return HealthWriteOutcome(row: confirmed)
        }
    }

    /// The server's current row for one date, or `nil` when it serves none.
    private func fetchServerHealthRow(date: String) async throws -> HealthMetric? {
        try await repository.fetchHealthMetrics(limit: healthWriteConfirmationWindow)
            .first { $0.date == date }
    }

    /// How many recent health rows one recovery read may scan. The window is
    /// the reconciliation window's own read plus headroom for an intent whose
    /// date aged while the device was offline; a row outside it stays
    /// unresolved (and visible) rather than guessed.
    private var healthWriteConfirmationWindow: Int {
        max(HealthMetricReadWindow.candidateDays, 60)
    }

    /// Reconciles one replayed health write into the account cache and the
    /// published reading.
    ///
    /// The identity is the row's date, so the ordinary revision-fenced
    /// confirmation applies: an older recovery's answer therefore cannot clear
    /// (or overwrite) a newer local pass for the same date. A row that no
    /// longer exists locally is not synthesized — a late answer must never
    /// recreate cache state — but the server's own row is still published,
    /// because that is the honest current reading.
    ///
    /// - Returns: whether this answer is still the newest local revision for
    ///   the date. `false` means a newer local pass replaced it while the
    ///   request was in flight, so the caller must not treat the row as synced.
    @discardableResult
    private func settleHealthWrite(
        _ outcome: HealthWriteOutcome,
        intent: HealthWriteIntent,
        accountUserID: UUID,
        cacheRevisions: [CacheEntityIdentity: Int]
    ) -> Bool {
        let entityID = CacheEntityID.healthMetric(outcome.row)
        let captured = cacheConfirmationRevision(
            cacheRevisions,
            entityType: .healthMetrics,
            entityID: entityID
        )
        let current: Int? = (try? cachedWorkspace?.localRevision(
            accountUserID: accountUserID,
            entityType: .healthMetrics,
            entityID: entityID
        )) ?? nil
        guard captured == current else {
            // A newer local pass owns this date now: its own intent (and its
            // own acknowledgement) decides what that row becomes.
            return false
        }
        if let captured {
            cacheConfirmServerUpsert(
                outcome.row,
                accountUserID: accountUserID,
                entityType: .healthMetrics,
                entityID: entityID,
                confirmingLocalRevision: captured
            )
        } else {
            // The optimistic row never landed (termination before the cache
            // write, or a rebuilt cache): record the server's own row as clean
            // server state instead of synthesizing an unconfirmed write.
            cacheUpsertServer(
                outcome.row,
                accountUserID: accountUserID,
                entityType: .healthMetrics,
                entityID: entityID
            )
        }
        publishHealthMetric(outcome.row)
        return true
    }

    /// Completes one health intent the pass itself acknowledged (#919).
    ///
    /// The queue item is removed only while it is still THIS intent: a newer
    /// pass that replaced it while the request was in flight keeps its own
    /// durable intent, and its own acknowledgement is what completes it. A
    /// removal that fails leaves the intent durable, which is harmless — the
    /// next replay re-reads the server and finds the write already applied.
    private func completeHealthWriteIntent(
        _ item: DurableQueueItem<PendingWrite>,
        intent: HealthWriteIntent,
        capturedBy accountFetch: AccountScopedFetch
    ) async {
        guard let queue else { return }
        guard let current = await queue.item(
            id: item.id,
            accountUserID: item.accountUserID
        ),
              current.revision == item.revision,
              case let .healthWrite(queued) = current.payload,
              queued.operationID == intent.operationID else {
            await refreshQueueCount(for: accountFetch)
            return
        }
        do {
            try await queue.remove(
                id: item.id,
                accountUserID: item.accountUserID,
                reason: "health-write-acknowledged"
            )
        } catch let error as DurableQueueError where error == .itemNotFound {
            // Already gone: that is the terminal state this call wanted.
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

    /// The health dates with a durable intent in the queue — any state,
    /// including quarantined, because a quarantined intent is still the user's
    /// own unsynced data and the residue sweep must not resolve the row it owns.
    private func queueItemsHealthDates(userID: UUID) async -> [String] {
        guard let queue else { return [] }
        return await queue.items(for: userID, includeQuarantined: true).compactMap { item in
            guard case let .healthWrite(intent) = item.payload else { return nil }
            return intent.date
        }
    }

    /// #919: resolves the pre-#919 health residue — pending cache-only rows
    /// left with no replay intent at all by an interrupted older build.
    ///
    /// Only PROVABLE outcomes are resolved, and nothing is reconstructed from a
    /// local row alone (a queued write has to carry the payload the pass
    /// decided, its trigger and its authoring time; none of those are
    /// recoverable from a bare cache row):
    ///
    /// * a live pending row the server already serves exactly is adopted — the
    ///   write landed and only its acknowledgement was lost;
    /// * a live pending row for a date the server serves NOTHING for is adopted
    ///   into a durable intent and replayed through the same revalidation, so
    ///   it cannot clobber anything (it is the only writer for that date);
    /// * a pending tombstone whose date the server no longer serves is a
    ///   confirmed delete; one whose date the server DOES serve adopts that
    ///   authoritative row instead.
    ///
    /// Everything else stays exactly where it is and keeps counting as unsynced
    /// — a residue whose date the server already moved on from is not silently
    /// cleared, and no write is invented to make it disappear.
    private func recoverLegacyHealthResidues(
        userID: UUID,
        capturedBy accountFetch: AccountScopedFetch
    ) async -> Bool {
        guard queue != nil, let workspace = cachedWorkspace else { return true }
        guard !recoveredHealthResidueAccounts.contains(userID) else { return true }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return false }
        let pendingIDs = (try? workspace.pendingEntityIDs(
            accountUserID: userID,
            entityType: .healthMetrics,
            includingDeleted: true
        )) ?? []
        guard !pendingIDs.isEmpty else {
            recoveredHealthResidueAccounts.insert(userID)
            return true
        }
        let queuedDates = Set(await queueItemsHealthDates(userID: userID))
        let residueIDs = pendingIDs.filter { !queuedDates.contains($0) }
        guard !residueIDs.isEmpty else {
            recoveredHealthResidueAccounts.insert(userID)
            return true
        }
        let serverRows: [HealthMetric]
        do {
            serverRows = try await repository.fetchHealthMetrics(
                limit: healthWriteConfirmationWindow
            )
        } catch {
            // A failed authoritative read defers the whole sweep rather than
            // resolving anything on a guess.
            return false
        }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return false }
        for entityID in residueIDs {
            guard let revision = (try? workspace.localRevision(
                accountUserID: userID,
                entityType: .healthMetrics,
                entityID: entityID
            )) ?? nil else { continue }
            let serverRow = serverRows.first { $0.date == entityID }
            guard let local = try? workspace.store.loadOne(
                HealthMetric.self,
                accountUserID: userID,
                entityType: .healthMetrics,
                entityID: entityID
            ) else {
                // A tombstone: the row was never confirmed server-side.
                if let serverRow {
                    cacheConfirmServerUpsert(
                        serverRow,
                        accountUserID: userID,
                        entityType: .healthMetrics,
                        entityID: entityID,
                        confirmingLocalRevision: revision
                    )
                } else {
                    cacheConfirmServerDelete(
                        accountUserID: userID,
                        entityType: .healthMetrics,
                        entityID: entityID,
                        confirmingLocalRevision: revision
                    )
                }
                continue
            }
            if let serverRow {
                let intent = HealthWriteIntent(
                    date: local.date,
                    payload: local,
                    trigger: .automatic
                )
                guard intent.isSatisfied(by: serverRow) else { continue }
                cacheConfirmServerUpsert(
                    serverRow,
                    accountUserID: userID,
                    entityType: .healthMetrics,
                    entityID: entityID,
                    confirmingLocalRevision: revision
                )
                continue
            }
            // No server row for the date: adopting the residue costs one
            // revalidation (the drain replays it through the same policy), and
            // the adopted intent is the only writer for that date.
            guard await enqueueDirectWrite(
                .healthWrite(
                    HealthWriteIntent(
                        date: local.date,
                        payload: local,
                        trigger: .automatic
                    )
                ),
                capturedBy: accountFetch,
                startUpload: false
            ) != nil else { return false }
        }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return false }
        recoveredHealthResidueAccounts.insert(userID)
        refreshPendingCacheWriteCount(accountUserID: userID)
        return true
    }

    // MARK: Phase transition replay (#917)

    /// The authoritative state one replayed phase transition ended in.
    private struct PhaseTransitionOutcome {
        let periods: [PhasePeriod]
        let settings: UserSettings
    }

    /// Replays one durable phase transition intent against the server (#917).
    ///
    /// The transition's two halves are the phase periods and the
    /// `user_settings` row that must point at the canonical open period, and
    /// this is the single place they are settled together:
    ///
    /// * the server's own state is read first. When it already leaves the
    ///   intended block open (a `create` that landed, or a transition that was
    ///   a no-op) the mutation must NOT be re-sent — `phase_periods` mints its
    ///   own row id, so "apply it again" would insert a SECOND open period.
    ///   Only the settings half is completed if it is the one that was lost.
    /// * otherwise the planner re-derives the transition from the state it was
    ///   authored against (or, when that view is no longer anchored on the
    ///   server's rows, from the server's own authoritative state), and the
    ///   result has to show the intended open block before the transition is
    ///   allowed to confirm.
    private func applyPhaseTransitionIntent(
        _ intent: PhaseTransitionIntent,
        userID: UUID
    ) async throws -> PhaseTransitionOutcome {
        let serverPeriods = try await repository.fetchPhasePeriods()
        if PhaseTransitionReplayPolicy.isApplied(
            intent: intent,
            serverPeriods: serverPeriods
        ) {
            let serverSettings = try await repository.fetchSettingsDelta(since: nil)
                .activeValues
                .first
            if serverSettings != intent.settings {
                try await repository.updateSettings(intent.settings, userID: userID)
            }
            return PhaseTransitionOutcome(
                periods: serverPeriods,
                settings: intent.settings
            )
        }
        let result = try await repository.switchPhase(
            to: intent.targetPhase,
            currentPeriods: PhaseTransitionReplayPolicy.planInput(
                intent: intent,
                serverPeriods: serverPeriods
            ),
            today: intent.intendedToday,
            userID: userID
        )
        guard PhaseTransitionReplayPolicy.isComplete(
            intent: intent,
            resultPeriods: result.periods
        ) else {
            // The writes ran but the server does not show the intended open
            // block. Keep the intent (retryable; surfaced as needs-attention
            // once the bounded attempts run out) instead of confirming a
            // transition that did not complete.
            throw PhaseTransitionReplayError.incompleteTransition
        }
        if result.settings != intent.settings {
            // Completeness is the two halves agreeing: the periods say the
            // intended block is open, so the settings row has to point at it
            // even when its own write is the one that was lost.
            try await repository.updateSettings(intent.settings, userID: userID)
        }
        return PhaseTransitionOutcome(periods: result.periods, settings: intent.settings)
    }

    /// Settles one completed phase transition into the account cache and the
    /// published block state — the settings/phase analogue of
    /// `confirmDirectWriteSaved`.
    ///
    /// Every row is revision-fenced against the snapshot taken before the first
    /// network await: a newer local transition that bumped a row while this
    /// (older) request was in flight owns that row, so this acknowledgement
    /// must neither clear it nor publish its own older values over it. A local
    /// period identity the server never minted is retired only once the
    /// server's own row for it is identifiable by content — otherwise it stays
    /// pending and keeps counting as unsynced.
    ///
    /// - Returns: whether this acknowledgement is still the newest local state
    ///   for the transition.
    @discardableResult
    private func confirmPhaseTransition(
        _ outcome: PhaseTransitionOutcome,
        intent: PhaseTransitionIntent,
        accountUserID: UUID,
        cacheRevisions: [CacheEntityIdentity: Int]
    ) -> Bool {
        guard let workspace = cachedWorkspace else { return true }
        var isNewest = true
        let serverIDs = Set(outcome.periods.map { $0.id.uuidString.lowercased() })
        let pendingIDs = (try? workspace.pendingEntityIDs(
            accountUserID: accountUserID,
            entityType: .phasePeriods,
            includingDeleted: true
        )) ?? []
        let liveIDs = Set((try? workspace.pendingEntityIDs(
            accountUserID: accountUserID,
            entityType: .phasePeriods
        )) ?? [])
        for entityID in pendingIDs where !serverIDs.contains(entityID.lowercased()) {
            let captured = cacheConfirmationRevision(
                cacheRevisions,
                entityType: .phasePeriods,
                entityID: entityID
            )
            let current = try? workspace.localRevision(
                accountUserID: accountUserID,
                entityType: .phasePeriods,
                entityID: entityID
            )
            guard captured == current else {
                // A newer local transition owns this row.
                isNewest = false
                continue
            }
            if !liveIDs.contains(entityID) {
                // A tombstone: the transition's own plan removed this identity
                // (a same-day switch-back deletes the period it just created),
                // so the removal is confirmed rather than left counted as
                // unsynced for ever.
                cacheConfirmServerDelete(
                    accountUserID: accountUserID,
                    entityType: .phasePeriods,
                    entityID: entityID,
                    confirmingLocalRevision: captured ?? 0
                )
                continue
            }
            guard let local = try? workspace.store.loadOne(
                PhasePeriod.self,
                accountUserID: accountUserID,
                entityType: .phasePeriods,
                entityID: entityID
            ), let adopted = outcome.periods.first(where: {
                $0.phase == local.phase
                    && $0.startedOn == local.startedOn
                    && $0.endedOn == local.endedOn
            }) else {
                // No provable server row for this optimistic identity: it stays
                // pending (still counted as unsynced) instead of being cleared
                // on a guess.
                isNewest = false
                continue
            }
            // The server minted its own row id for the period this local row
            // created: adopt the server row under its own identity and retire
            // the optimistic one.
            cacheConfirmServerDelete(
                accountUserID: accountUserID,
                entityType: .phasePeriods,
                entityID: entityID,
                confirmingLocalRevision: captured ?? 0
            )
            cacheUpsertServer(
                adopted,
                accountUserID: accountUserID,
                entityType: .phasePeriods,
                entityID: adopted.id.uuidString
            )
        }
        for period in outcome.periods {
            let entityID = period.id.uuidString
            if pendingIDs.contains(entityID) && !liveIDs.contains(entityID) {
                // The server still serves a row this account deleted locally:
                // the local delete is the newer word and is replayed by its own
                // transition, so the row is never resurrected here.
                isNewest = false
                continue
            }
            guard let captured = cacheConfirmationRevision(
                cacheRevisions,
                entityType: .phasePeriods,
                entityID: entityID
            ) else {
                // A server row with no local counterpart (the period the
                // previous block closed): stored as clean server state.
                cacheUpsertServer(
                    period,
                    accountUserID: accountUserID,
                    entityType: .phasePeriods,
                    entityID: entityID
                )
                continue
            }
            let current = try? workspace.localRevision(
                accountUserID: accountUserID,
                entityType: .phasePeriods,
                entityID: entityID
            )
            guard captured == current else {
                isNewest = false
                continue
            }
            cacheConfirmServerUpsert(
                period,
                accountUserID: accountUserID,
                entityType: .phasePeriods,
                entityID: entityID,
                confirmingLocalRevision: captured
            )
        }
        // The settings row last: it is the half that has to point at whatever
        // open period the transition actually left behind.
        let settingsID = CacheEntityID.settings
        let settingsCaptured = cacheConfirmationRevision(
            cacheRevisions,
            entityType: .settings,
            entityID: settingsID
        )
        let settingsCurrent = try? workspace.localRevision(
            accountUserID: accountUserID,
            entityType: .settings,
            entityID: settingsID
        )
        if settingsCaptured == settingsCurrent {
            cacheConfirmServerUpsert(
                outcome.settings,
                accountUserID: accountUserID,
                entityType: .settings,
                entityID: settingsID,
                confirmingLocalRevision: settingsCaptured ?? 0
            )
        } else {
            isNewest = false
        }
        return isNewest
    }

    // MARK: Tag registry replay (#918)

    /// The authoritative state one replayed tag mutation ended in.
    private struct TagMutationOutcome {
        let tags: [TagMetadata]
        let recordings: [TindeqRecording]
    }

    /// Replays one durable tag-registry mutation against the server (#918).
    ///
    /// The mutation's two halves are the recording repoint and the registry row,
    /// and this is the single place they are settled together:
    ///
    /// * the server's own state is read first. When it already shows the
    ///   intended end state — a rename whose acknowledgement was lost, a
    ///   visibility flag that landed, a rename that was a no-op — nothing is
    ///   re-sent.
    /// * otherwise the rename is re-anchored on whichever name the server still
    ///   serves (the older name while the rename has not run, a newer one when
    ///   an earlier arrow of a chained rename already landed), and the
    ///   visibility upsert is applied last. That upsert carries `name` and
    ///   `hidden` and nothing else: the device-local side mode is never uploaded
    ///   and no other setting is read or written here.
    /// * the result has to show the intended end state before the mutation is
    ///   allowed to confirm — a rename that would leave one of the user's
    ///   recording references behind keeps its durable intent (and stays
    ///   retryable) instead of being reported as done.
    private func applyTagMutationIntent(
        _ intent: TagMutationIntent
    ) async throws -> TagMutationOutcome {
        // A visibility-only mutation never looks at the recordings: the upsert
        // carries `name` + `hidden` and nothing else.
        let needsRecordings = intent.renamedTo != nil || !intent.recordingIDs.isEmpty
        var tags = try await repository.fetchTagMetadata()
        var recordings = needsRecordings ? try await repository.fetchRecordings() : []
        if TagMutationReplayPolicy.isApplied(
            intent: intent,
            serverTags: tags,
            serverRecordings: recordings
        ) {
            return TagMutationOutcome(tags: tags, recordings: recordings)
        }
        if let finalName = intent.renamedTo,
           let source = TagMutationReplayPolicy.repointSource(
               intent: intent,
               serverTags: tags,
               serverRecordings: recordings
           ),
           source != finalName {
            try await repository.renameTag(oldName: source, newName: finalName)
            tags = try await repository.fetchTagMetadata()
            recordings = try await repository.fetchRecordings()
        }
        if let hidden = intent.hidden {
            try await repository.setTagHidden(name: intent.finalName, hidden: hidden)
            tags = try await repository.fetchTagMetadata()
        }
        guard TagMutationReplayPolicy.isComplete(
            intent: intent,
            serverTags: tags,
            serverRecordings: recordings
        ) else {
            throw TagMutationReplayError.incompleteTagMutation
        }
        return TagMutationOutcome(tags: tags, recordings: recordings)
    }

    /// Settles one completed tag mutation into the account cache and the
    /// published tag/recording state — the registry analogue of
    /// `confirmDirectWriteSaved`.
    ///
    /// Every row is revision-fenced against the snapshot taken before the first
    /// network await: a newer mutation that bumped a row while this (older)
    /// request was in flight owns that row, so this acknowledgement may neither
    /// clear it nor publish its own older values over it. Two rules keep the
    /// registry exact: every name the mutation retires is confirmed-removed
    /// locally, and a final name the server does not serve gets NO local row —
    /// the optimistic row was a guess (a rename only carries a registry row
    /// across when the old name had one) and leaving it pending would count as
    /// unsynced for ever.
    ///
    /// - Returns: whether this acknowledgement is still the newest local state
    ///   for the tag.
    @discardableResult
    private func settleTagMutation(
        _ outcome: TagMutationOutcome,
        intent: TagMutationIntent,
        accountUserID: UUID,
        cacheRevisions: [CacheEntityIdentity: Int]
    ) -> Bool {
        guard let workspace = cachedWorkspace else { return true }
        var isNewest = true
        for name in intent.retiredNames.sorted() {
            guard let captured = cacheConfirmationRevision(
                cacheRevisions,
                entityType: .tagMetadata,
                entityID: name
            ) else { continue }
            let current = try? workspace.localRevision(
                accountUserID: accountUserID,
                entityType: .tagMetadata,
                entityID: name
            )
            guard captured == current else {
                // A newer local mutation owns this name.
                isNewest = false
                continue
            }
            cacheConfirmServerDelete(
                accountUserID: accountUserID,
                entityType: .tagMetadata,
                entityID: name,
                confirmingLocalRevision: captured
            )
            tagMetadata.removeAll { $0.name == name }
        }
        let finalName = intent.finalName
        if let capturedFinal = cacheConfirmationRevision(
            cacheRevisions,
            entityType: .tagMetadata,
            entityID: finalName
        ) {
            let currentFinal = try? workspace.localRevision(
                accountUserID: accountUserID,
                entityType: .tagMetadata,
                entityID: finalName
            )
            if capturedFinal == currentFinal {
                if let row = outcome.tags.first(where: { $0.name == finalName }) {
                    cacheConfirmServerUpsert(
                        row,
                        accountUserID: accountUserID,
                        entityType: .tagMetadata,
                        entityID: finalName,
                        confirmingLocalRevision: capturedFinal
                    )
                    publishTagMetadata(row)
                } else {
                    cacheConfirmServerDelete(
                        accountUserID: accountUserID,
                        entityType: .tagMetadata,
                        entityID: finalName,
                        confirmingLocalRevision: capturedFinal
                    )
                    tagMetadata.removeAll { $0.name == finalName }
                }
            } else {
                isNewest = false
            }
        }
        for recording in outcome.recordings where intent.recordingIDs.contains(recording.id) {
            let entityID = recording.id.uuidString
            guard let captured = cacheConfirmationRevision(
                cacheRevisions,
                entityType: .recordings,
                entityID: entityID
            ) else { continue }
            let current = try? workspace.localRevision(
                accountUserID: accountUserID,
                entityType: .recordings,
                entityID: entityID
            )
            guard captured == current else {
                isNewest = false
                continue
            }
            cacheConfirmServerUpsert(
                recording,
                accountUserID: accountUserID,
                entityType: .recordings,
                entityID: entityID,
                confirmingLocalRevision: captured
            )
            if let index = recordings.firstIndex(where: { $0.id == recording.id }),
               recordings[index].tag != recording.tag {
                recordings[index].tag = recording.tag
            }
        }
        if intent.renamedTo != nil {
            // The rename RPC hard-deletes the stale registry row (and only
            // creates the new one when the old name had one). Deltas cannot
            // observe either, so the tag cursor is reset and the next reconcile
            // re-reads the whole registry.
            do {
                try workspace.resetCursor(
                    accountUserID: accountUserID,
                    entityType: .tagMetadata
                )
            } catch {
                recordCacheFailure("cache cursor reset", error)
            }
        }
        return isNewest
    }

    /// Publishes one registry row into the account's tag list, replacing the
    /// row for the same name (the name IS the identity).
    private func publishTagMetadata(_ row: TagMetadata) {
        if let index = tagMetadata.firstIndex(where: { $0.name == row.name }) {
            tagMetadata[index] = row
        } else {
            tagMetadata.append(row)
        }
    }

    @discardableResult
    private func upload(
        _ item: DurableQueueItem<PendingWrite>,
        mode: QueueUploadMode = .automatic,
        capturedBy capturedAccountFetch: AccountScopedFetch? = nil,
        waitForSessionInsert: Bool = true
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
            var finishedSessionInsert: PendingSessionInsert?
            var completedDeleteReceipt: SessionLogReceipt?
            var suppressSavedToast = false
            switch item.payload {
            case let .session(payload):
                finishedSessionInsert = .loggedSession(sessionID: payload.id)
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
                // A delete intent can be created while the matching session or
                // workout insert is awaiting the server. The queue entry is
                // the durable dependency: leave the delete due until that
                // insert has
                // either completed (and left the queue) or been skipped
                // because Undo claimed it. Soft-deleting first is a no-op on
                // many backends and would let the later insert resurrect the
                // exact row Undo removed.
                if waitForSessionInsert {
                    await waitForQueueUpload(
                        QueueUploadKey(
                            itemID: deletePayload.sessionID,
                            accountUserID: item.accountUserID
                        )
                    )
                    guard accountFetch.canApply(
                        to: currentUserID,
                        accountEpoch: accountEpoch
                    ) else {
                        return UploadResult(uploaded: false, failure: nil)
                    }
                }
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
                    guard let insert = pendingSessionInsert(for: queued.payload) else {
                        return false
                    }
                    return PendingSessionDeletePolicy.matches(
                        insert: insert,
                        deleteSessionID: deletePayload.sessionID
                    )
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
            case let .sessionMerge(payload):
                suppressSavedToast = true
                let merged = try await self.repository.mergeTindeqSessions(
                    sessionIDs: payload.mergedSessionIDs,
                    survivorID: payload.survivorID,
                    rpe: payload.draft.rpe,
                    rpeConfirmed: payload.rpeConfirmed
                )
                guard accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else {
                    // Leave the durable merge for its owning account.
                    return UploadResult(uploaded: false, failure: nil)
                }
                // The server recomputes duration and note from the recordings
                // it actually moved, so a row built from a stale local set
                // reconciles here (the RPC is the authority on what the merged
                // session contains).
                if let merged,
                   let base = pendingSessions[payload.survivorID]
                       ?? self.sessions.first(where: { $0.id == payload.survivorID }) {
                    var reconciled = base
                    reconciled.durationMinutes = merged.durationMinutes ?? base.durationMinutes
                    reconciled.note = merged.note ?? base.note
                    reconciled.groupID = merged.groupID ?? base.groupID
                    reconciled.pending = false
                    reconciled.load = RecordingEditCoordinator.optimisticLoad(
                        durationMinutes: reconciled.durationMinutes,
                        rpe: reconciled.rpe
                    )
                    pendingSessions.removeValue(forKey: payload.survivorID)
                    replaceSession(reconciled)
                    cacheConfirmServerUpsert(
                        reconciled,
                        accountUserID: item.accountUserID,
                        entityType: .sessions,
                        entityID: CacheEntityID.session(reconciled),
                        confirmingLocalRevision: cacheConfirmationRevision(
                            cacheRevisions,
                            entityType: .sessions,
                            entityID: payload.survivorID.uuidString
                        )
                    )
                }
                let mergedAwayIDs = payload.mergedSessionIDs.filter {
                    $0 != payload.survivorID
                }
                sessions.removeAll { mergedAwayIDs.contains($0.id) }
                for sessionID in mergedAwayIDs {
                    pendingMergedAwaySessionIDs.removeValue(forKey: sessionID)
                    cacheConfirmServerDelete(
                        accountUserID: item.accountUserID,
                        entityType: .sessions,
                        entityID: sessionID.uuidString,
                        confirmingLocalRevision: cacheConfirmationRevision(
                            cacheRevisions,
                            entityType: .sessions,
                            entityID: sessionID.uuidString
                        )
                    )
                }
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
                finishedSessionInsert = .manualWorkout(sessionID: draft.sessionID)
                let saved = try await self.repository.insertPhoneWorkout(draft)
                guard accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else {
                    return UploadResult(uploaded: false, failure: nil)
                }
                let receipt = SessionLogReceipt(
                    sessionID: draft.sessionID,
                    accountUserID: item.accountUserID
                )
                sessionReceipt = receipt
                if routineUndo.isClaimed(receipt) {
                    // A pending manual workout can be deleted while its
                    // insert is in flight. Keep the durable delete marker as
                    // the only visible outcome; its upload waits for this
                    // request to settle before soft-deleting the server row.
                    pendingSessions.removeValue(forKey: draft.sessionID)
                } else {
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
            case let .preset(intent):
                // The editor already reflects the optimistic save; the queue's
                // generic toast would be a second, duplicate confirmation.
                suppressSavedToast = true
                let repository = self.repository
                let outcome = try await applyDirectWriteIntent(
                    intent,
                    remote: DirectWriteRemote(
                        fetch: { try await repository.fetchPresets() },
                        insert: { try await repository.insertPreset($0) },
                        update: { try await repository.updatePreset($0) },
                        delete: { try await repository.deletePreset(id: $0) }
                    )
                )
                guard accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else {
                    return UploadResult(uploaded: false, failure: nil)
                }
                switch outcome {
                case let .saved(saved):
                    guard confirmDirectWriteSaved(
                        saved,
                        intent: intent,
                        accountUserID: item.accountUserID,
                        entityType: .presets,
                        cacheRevisions: cacheRevisions
                    ) else { break }
                    presets.removeAll {
                        $0.id == saved.id
                            || $0.id.uuidString.lowercased() == intent.entityID.lowercased()
                    }
                    presets.insert(saved, at: 0)
                case let .deleted(removedEntityID):
                    retireDirectWriteLocalRows(
                        intent: intent,
                        removedEntityID: removedEntityID,
                        accountUserID: item.accountUserID,
                        entityType: .presets,
                        cacheRevisions: cacheRevisions
                    )
                    _ = await terminalizeDirectWrite(
                        item,
                        entityID: item.id,
                        operationID: intent.operationID,
                        reason: "preset-deleted",
                        capturedBy: accountFetch
                    )
                }
            case let .routine(intent):
                suppressSavedToast = true
                let repository = self.repository
                let outcome = try await applyDirectWriteIntent(
                    intent,
                    remote: DirectWriteRemote(
                        fetch: { try await repository.fetchRoutinePresets() },
                        insert: { try await repository.insertRoutine($0) },
                        update: { try await repository.updateRoutine($0) },
                        delete: { try await repository.deleteRoutine(id: $0) }
                    )
                )
                guard accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else {
                    return UploadResult(uploaded: false, failure: nil)
                }
                switch outcome {
                case let .saved(saved):
                    guard confirmDirectWriteSaved(
                        saved,
                        intent: intent,
                        accountUserID: item.accountUserID,
                        entityType: .routinePresets,
                        cacheRevisions: cacheRevisions
                    ) else { break }
                    routines.removeAll {
                        $0.id == saved.id
                            || $0.id.uuidString.lowercased() == intent.entityID.lowercased()
                    }
                    routines.insert(saved, at: 0)
                case let .deleted(removedEntityID):
                    retireDirectWriteLocalRows(
                        intent: intent,
                        removedEntityID: removedEntityID,
                        accountUserID: item.accountUserID,
                        entityType: .routinePresets,
                        cacheRevisions: cacheRevisions
                    )
                    _ = await terminalizeDirectWrite(
                        item,
                        entityID: item.id,
                        operationID: intent.operationID,
                        reason: "routine-deleted",
                        capturedBy: accountFetch
                    )
                }
            case let .phaseTransition(intent):
                // The transition reports its own completion (the new block's
                // name); the queue's generic toast would be a second,
                // duplicate confirmation.
                suppressSavedToast = true
                let outcome = try await applyPhaseTransitionIntent(
                    intent,
                    userID: item.accountUserID
                )
                guard accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else {
                    return UploadResult(uploaded: false, failure: nil)
                }
                if confirmPhaseTransition(
                    outcome,
                    intent: intent,
                    accountUserID: item.accountUserID,
                    cacheRevisions: cacheRevisions
                ) {
                    phasePeriods = outcome.periods
                    settings = outcome.settings
                    publishReadinessWidgetSnapshot()
                    toastMessage = "Training Block changed to \(PhaseCatalog.definition(for: intent.targetPhase).name)."
                }
                refreshPendingCacheWriteCount(accountUserID: item.accountUserID)
            case let .tagMutation(intent):
                // The rename/hide reports itself locally (the tag list and its
                // toast); the queue's generic "Saved" toast would be a second,
                // duplicate confirmation.
                suppressSavedToast = true
                let outcome = try await applyTagMutationIntent(intent)
                guard accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else {
                    return UploadResult(uploaded: false, failure: nil)
                }
                settleTagMutation(
                    outcome,
                    intent: intent,
                    accountUserID: item.accountUserID,
                    cacheRevisions: cacheRevisions
                )
                refreshPendingCacheWriteCount(accountUserID: item.accountUserID)
            case let .healthWrite(intent):
                // The recovery reports its own outcome (the row it confirmed);
                // the queue's generic "Saved" toast would be a second,
                // duplicate confirmation for a background health pass.
                suppressSavedToast = true
                let outcome = try await applyHealthWriteIntent(
                    intent,
                    userID: item.accountUserID
                )
                guard accountFetch.canApply(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) else {
                    return UploadResult(uploaded: false, failure: nil)
                }
                settleHealthWrite(
                    outcome,
                    intent: intent,
                    accountUserID: item.accountUserID,
                    cacheRevisions: cacheRevisions
                )
                refreshPendingCacheWriteCount(accountUserID: item.accountUserID)
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
            if let finishedSessionInsert,
               PendingSessionDeletePolicy.shouldDrainDeleteAfterInsert(
                   finishedSessionInsert
               ) {
                await uploadPendingSessionDelete(
                    sessionID: finishedSessionInsert.sessionID,
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
            // #675: classify the rejection. A permanent one (constraint /
            // malformed / forbidden-with-valid-token) earns the entry a
            // bounded number of attempts and then a quarantine; auth /
            // parked / transient failures keep plain backoff. The
            // classification is the transport's (PostgRESTError
            // conformance), so the actor never parses server errors.
            //
            // #935: the RECORD — attempts, backoff delay, diagnostic and the
            // mode's quarantine budget under this entry's captured revision —
            // is the recovery owner's one failure path. #675 F5: a MANUAL
            // retry ("Retry now" in History/Settings, or the per-item
            // quarantine retry) is an explicit user action, not an automatic
            // drain attempt, so the mode never lets it spend the quarantine
            // budget.
            let classification = (error as? ServerRejectionClassifying)?.rejectionClass ?? .retryable
            let code = (error as? PostgRESTError)?.code
            let failure = MutationUploadFailure(
                classification: classification,
                code: code,
                detail: error.localizedDescription
            )
            let applied = await mutationRecovery.recordFailure(
                item: item,
                failure: failure,
                mode: mode,
                in: queue
            ) { [weak self] queueError in
                guard let self else { return }
                if accountFetch.canApply(
                    to: self.currentUserID,
                    accountEpoch: self.accountEpoch
                ) {
                    self.surface(queueError)
                }
            }
            if applied {
                result = UploadResult(uploaded: false, failure: failure)
            } else {
                // The queue identity now holds a newer replacement. The
                // old request must not spend its backoff/quarantine
                // budget or report its error against that replacement.
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
        // The caller is the matching insert's completion. Its upload claim is
        // still held until the surrounding `upload` defer runs, so waiting on
        // that same claim here would deadlock. The insert has already settled;
        // the delete path may proceed directly.
        _ = await upload(
            deleteItem,
            capturedBy: accountFetch,
            waitForSessionInsert: false
        )
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

    /// #935: the explicit quarantine recovery entry point. The lifecycle it
    /// drives — migrate the recording-edit residue the entry point has to
    /// attempt first, then per entry: clear the rejection stamp, attempt ONE
    /// manual upload, and re-stamp immediately on any failure so the entry is
    /// never auto-retried (#675 F7, with the prior diagnostic restored verbatim
    /// unless the retry itself was a fresh permanent rejection — #675 N1) — is
    /// the recovery owner's. This body is composition only.
    public func retryQuarantinedWrites(id: UUID? = nil) async {
        guard let userID = currentUserID, let queue else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        _ = await mutationRecovery.retryQuarantined(
            id: id,
            boundary: recoveryBoundary(accountFetch),
            in: queue,
            prepare: {
                await self.migrateLegacyRecordingEdits(
                    userID: userID,
                    capturedBy: accountFetch
                ) != nil
            },
            upload: { item, itemMode in
                await self.upload(
                    item,
                    mode: itemMode,
                    capturedBy: accountFetch
                )
            },
            acknowledge: { await self.refreshQueueCount(for: accountFetch) },
            onFailure: { [weak self] error in
                guard let self else { return }
                if accountFetch.canApply(
                    to: self.currentUserID,
                    accountEpoch: self.accountEpoch
                ) {
                    self.surface(error)
                }
            }
        )
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
            // #935: the queue side of a discard — read the entry, remove it
            // quarantined-only under the revision this snapshot captured, and
            // report what actually happened — is the recovery owner's. The
            // aftermath stays here: it owns the optimistic placeholder, the
            // Undo claim and the list/trash refreshes.
            guard let discard = await mutationRecovery.discardQuarantined(
                id: id,
                boundary: recoveryBoundary(accountFetch),
                in: queue,
                onFailure: { [weak self] error in
                    guard let self else { return }
                    if accountFetch.canApply(
                        to: self.currentUserID,
                        accountEpoch: self.accountEpoch
                    ) {
                        self.surface(error)
                    }
                }
            ) else {
                await refreshQueueCount(for: accountFetch)
                return
            }
            let item = discard.item
            guard discard.discarded else {
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
                    await refreshAllSilently()
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
                    await refreshAllSilently()
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
                    await refreshAllSilently()
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
                    await refreshAllSilently()
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
                    await refreshAllSilently()
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
                publishReadinessWidgetSnapshot()
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
            pendingTagWriteCount = 0
            queuedWriteCount = 0
            queuedWriteDiagnostics = []
            queueBreadcrumbs = []
            quarantinedWrites = nil
            // #920: no signed-in account means nothing has been read — the
            // status must stay "not loaded" rather than reading as Synced.
            hasLoadedPendingWrites = false
            lastRetryOutcome = nil
            return
        }
        let fetch = accountFetch ?? AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: self.accountEpoch
        )
        guard fetch.canApply(to: userID, accountEpoch: self.accountEpoch) else { return }
        let activeItems: [DurableQueueItem<PendingWrite>]
        let breadcrumbs: [QueueBreadcrumb]
        let quarantined: [QuarantinedWrite]?
        if let queue {
            activeItems = await queue.items(for: userID)
            breadcrumbs = await queue.breadcrumbs(for: userID)
            quarantined = await queue.quarantinedItems(for: userID).map { $0.summary() }
        } else {
            activeItems = []
            breadcrumbs = []
            quarantined = nil
        }
        guard fetch.canApply(
            to: currentUserID,
            accountEpoch: self.accountEpoch
        ) else { return }
        refreshPendingCacheWriteCount(accountUserID: userID)
        _ = fetch.publishIfCurrent(
            to: currentUserID,
            accountEpoch: self.accountEpoch
        ) {
            queuedWriteCount = activeItems.count
            queuedWriteDiagnostics = activeItems.map { $0.diagnostic() }
            queueBreadcrumbs = breadcrumbs
            quarantinedWrites = quarantined
            // #920: this is the boundary where the app has actually read the
            // account's durable answers. Without a queue handle the quarantine
            // list is unknown (`nil`), so the status honestly stays "not
            // loaded" instead of reporting an unread zero.
            hasLoadedPendingWrites = quarantined != nil
        }
    }

    // MARK: Watch completions

    private func acceptStoredWatchCompletions() async {
        guard let userID = currentUserID else { return }
        let accountFetch = AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: accountEpoch
        )
        for completion in watch.storedCompletions() {
            let adopted = await acceptWatchCompletion(
                completion,
                accountFetch: accountFetch
            )
            // The persisted inbox is owned by the account that was captured
            // for this pass. A switch/sign-out while adoption was suspended
            // must leave the completion for the correct account's next pass.
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: accountEpoch
            ) else { return }
            if adopted {
                watch.acknowledgeStoredCompletion(completion)
            }
        }
    }

    private enum WatchCompletionCacheLookup {
        case missing
        case found(SendmeterCore.Session)
        case corrupt
        case unavailable
    }

    private func cachedWatchCompletionSession(
        sessionID: UUID,
        accountUserID: UUID
    ) -> WatchCompletionCacheLookup {
        guard let cachedWorkspace else { return .unavailable }
        do {
            let result = try cachedWorkspace.store.loadOneResult(
                SendmeterCore.Session.self,
                accountUserID: accountUserID,
                entityType: .sessions,
                entityID: sessionID.uuidString
            )
            if let session = result.value {
                return .found(session)
            }
            if result.invalid {
                recordCacheFailure(
                    "watch completion lookup: corrupt session row",
                    LocalCacheError.invalidPayload
                )
                return .corrupt
            }
            return .missing
        } catch {
            recordCacheFailure("watch completion lookup", error)
            return .unavailable
        }
    }

    /// Publishes a cache-adopted session without replacing an already-visible
    /// authoritative row. The cache is the durable dedupe boundary; the
    /// in-memory overlay only makes the History update synchronous with the WC
    /// callback.
    @discardableResult
    private func publishWatchCompletion(
        _ session: SendmeterCore.Session,
        accountUserID: UUID,
        accountFetch: AccountScopedFetch
    ) -> Bool {
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ), session.accountUserID == nil || session.accountUserID == accountUserID else {
            return false
        }
        if sessions.contains(where: { $0.id == session.id && !$0.pending }) {
            return true
        }
        if session.pending {
            pendingSessions[session.id] = session
            mergeSessions(remote: sessions.filter { !$0.pending })
        } else {
            mergeSessions(
                remote: sessions.filter { !$0.pending } + [session]
            )
        }
        return true
    }

    private func acceptWatchCompletion(
        _ completion: WatchWorkoutCompletion,
        accountFetch: AccountScopedFetch? = nil
    ) async -> Bool {
        guard let userID = currentUserID else { return false }
        let accountFetch = accountFetch ?? AccountScopedFetch(
            accountUserID: userID,
            accountEpoch: self.accountEpoch
        )
        guard accountFetch.canApply(to: userID, accountEpoch: self.accountEpoch) else {
            return false
        }
        let lookup = cachedWatchCompletionSession(
            sessionID: completion.sessionID,
            accountUserID: userID
        )
        let alreadyAdopted: Bool
        if case .found = lookup {
            alreadyAdopted = true
        } else {
            alreadyAdopted = false
        }
        let decision = watchCompletionAdoption.claim(
            completion.identity,
            stampedOwner: completion.accountUserID,
            currentUserID: userID,
            alreadyAdopted: alreadyAdopted
        )
        switch decision {
        case .signedOut, .wrongAccount, .unscopedLegacy, .inFlightDuplicate:
            return false
        case .alreadyAdopted:
            guard case let .found(existing) = lookup else { return false }
            return publishWatchCompletion(
                existing,
                accountUserID: userID,
                accountFetch: accountFetch
            )
        case .adopt:
            break
        }
        // This must be outside the switch. A defer nested in the `.adopt`
        // case fires when the case scope exits, before the cache write and
        // read-back below. Keep the claim live through every adoption return.
        defer { watchCompletionAdoption.finish(completion.identity) }

        let pending = completion.pendingSession(accountUserID: userID)
        switch lookup {
        case .unavailable, .corrupt:
            // The inbox remains unacknowledged because no durable adoption
            // occurred, but the user still sees the completion as pending
            // while the cache is unavailable or its row is corrupt.
            _ = publishWatchCompletion(
                pending,
                accountUserID: userID,
                accountFetch: accountFetch
            )
            return false
        case .found:
            return false
        case .missing:
            break
        }
        guard let cachedWorkspace else {
            _ = publishWatchCompletion(
                pending,
                accountUserID: userID,
                accountFetch: accountFetch
            )
            return false
        }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: self.accountEpoch
        ) else { return false }
        do {
            try cachedWorkspace.upsertPendingServer(
                pending,
                accountUserID: userID,
                entityType: .sessions,
                entityID: CacheEntityID.session(pending)
            )
        } catch {
            recordCacheFailure("watch completion adoption", error)
            _ = publishWatchCompletion(
                pending,
                accountUserID: userID,
                accountFetch: accountFetch
            )
            // Retaining the WC row is the only safe recovery path when the
            // durable adoption write fails.
            return false
        }
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: self.accountEpoch
        ) else { return false }
        do {
            let result = try cachedWorkspace.store.loadOneResult(
                SendmeterCore.Session.self,
                accountUserID: userID,
                entityType: .sessions,
                entityID: CacheEntityID.session(pending)
            )
            guard let adopted = result.value else {
                if result.invalid {
                    recordCacheFailure(
                        "watch completion adoption verify: corrupt session row",
                        LocalCacheError.invalidPayload
                    )
                    _ = publishWatchCompletion(
                        pending,
                        accountUserID: userID,
                        accountFetch: accountFetch
                    )
                }
                // A tombstone or cache failure means local adoption did not
                // become durable. Keep the persisted completion for retry.
                return false
            }
            guard accountFetch.canApply(
                to: currentUserID,
                accountEpoch: self.accountEpoch
            ) else { return false }
            return publishWatchCompletion(
                adopted,
                accountUserID: userID,
                accountFetch: accountFetch
            )
        } catch {
            recordCacheFailure("watch completion adoption verify", error)
            _ = publishWatchCompletion(
                pending,
                accountUserID: userID,
                accountFetch: accountFetch
            )
            return false
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
        // #747: a beat without an immutable owner is legacy transport data,
        // not an ownership proof. Reject it at the account boundary; the
        // durable server row remains the fallback for pre-stamp watch builds.
        guard liveWorkoutOwnedBy(incoming, userID: userID, trustsUnstamped: false) else { return }
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
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            // Deliberately keep the last accepted mirror row and swallow this
            // best-effort fallback failure; it is not an auth event.
            _ = error
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
        // #934: the account boundary is an explicit value here — the identity
        // captured before the first await, plus the live-identity test the
        // coordinator re-runs after every await.
        let boundary = WorkspaceAccountBoundary(fetch: accountFetch) { [weak self] in
            guard let self else { return false }
            return accountFetch.canApply(
                to: self.currentUserID,
                accountEpoch: self.accountEpoch
            )
        }
        do {
            // #934: the optional rollout endpoint and its fallback rule are the
            // coordinator's. Keep realtime convergence alive when it is
            // unavailable: the nil generation forces the foreground path below
            // to reconcile both affected entities.
            let purgeResolution = await workspaceSync.resolvePurgeGeneration {
                try await self.repository.fetchPurgeSyncGeneration()
            }
            if purgeResolution.isAvailable {
                markPurgeGenerationAvailable(capturedBy: accountFetch)
            }
            let remotePurgeGeneration: Int64? = purgeResolution.generation
            guard boundary.canApply() else { return }
            if await cacheNeedsPurgeReconcile(
                accountUserID: userID,
                remoteGeneration: remotePurgeGeneration
            ) {
                // A realtime event can arrive before the coalesced refresh has
                // observed the hard-delete generation. Reuse the foreground
                // authoritative path so sessions and recordings converge
                // together, even when only one table emitted the event.
                await refreshAllSilently()
                return
            }
            if slices.contains(.sessions) {
                guard let snapshot = try await workspaceSync.reconcileSlice(
                    in: cachedWorkspace,
                    boundary: boundary,
                    entityType: .sessions,
                    purgeGeneration: remotePurgeGeneration,
                    fetch: { cursor in
                        try await self.repository.fetchSessionDelta(
                            since: cursor,
                            accountUserID: userID
                        )
                    },
                    fullSnapshot: { CachedWorkspaceSnapshot(sessions: $0.activeValues) },
                    onFailure: recordCacheFailure
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
                guard let snapshot = try await workspaceSync.reconcileSlice(
                    in: cachedWorkspace,
                    boundary: boundary,
                    entityType: .recordings,
                    purgeGeneration: remotePurgeGeneration,
                    fetch: { cursor in
                        try await self.repository.fetchRecordingDelta(since: cursor)
                    },
                    fullSnapshot: { CachedWorkspaceSnapshot(recordings: $0.activeValues) },
                    onFailure: recordCacheFailure
                ) else { return }
                let publishedRecordings = accountFetch.publishIfCurrent(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) {
                    mergeRecordings(remote: snapshot.recordings)
                    markRecordingsLoaded()
                }
                guard publishedRecordings else { return }
                warmTagCurvesIfMissing(capturedBy: accountFetch)
            }
            if slices.contains(.workouts) {
                guard let snapshot = try await workspaceSync.reconcileSlice(
                    in: cachedWorkspace,
                    boundary: boundary,
                    entityType: .workoutsAndAttempts,
                    fetch: { cursor in
                        try await self.repository.fetchWorkoutDelta(since: cursor)
                    },
                    fullSnapshot: { CachedWorkspaceSnapshot(workouts: $0.activeValues) },
                    onFailure: recordCacheFailure
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
                guard let snapshot = try await workspaceSync.reconcileSlice(
                    in: cachedWorkspace,
                    boundary: boundary,
                    entityType: .healthMetrics,
                    fetch: { cursor in
                        try await self.repository.fetchHealthMetricDelta(since: cursor)
                    },
                    fullSnapshot: { CachedWorkspaceSnapshot(healthMetrics: $0.activeValues) },
                    onFailure: recordCacheFailure
                ) else { return }
                let publishedHealth = accountFetch.publishIfCurrent(
                    to: currentUserID,
                    accountEpoch: accountEpoch
                ) {
                    healthMetrics = snapshot.healthMetrics
                    publishReadinessWidgetSnapshot()
                }
                guard publishedHealth else { return }
            }
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            // Deliberately keep the last list snapshot and swallow this
            // best-effort reconcile failure; it is not an auth event.
            _ = error
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
        // Read delete intents first. A session/workout insert and its Undo
        // delete can overlap in the queue; the delete must win before any
        // optimistic row is rebuilt from the insert payload.
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
                let receipt = SessionLogReceipt(
                    sessionID: payload.id,
                    accountUserID: item.accountUserID
                )
                guard PendingSessionDeletePolicy.shouldRestore(
                    insert: .loggedSession(sessionID: payload.id),
                    remoteSessionIDs: remoteSessionIDs,
                    deleteIsClaimed: routineUndo.isClaimed(receipt)
                ) else { continue }
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
            case let .sessionMerge(payload):
                // #942: a queued merge owns the survivor's optimistic row and
                // keeps the merged-away entries hidden until the RPC lands
                // (the server still returns them while the merge is pending).
                for sessionID in payload.mergedSessionIDs where sessionID != payload.survivorID {
                    pendingMergedAwaySessionIDs[sessionID] = item.accountUserID
                }
                // The recordings move under the surviving group in memory, so
                // the pending entry's detail already lists them. The cache
                // still holds the server's (pre-merge) group until the fetch
                // that follows the upload republishes them.
                for recordingID in payload.recordingIDs {
                    guard let index = recordings.firstIndex(where: { $0.id == recordingID }) else {
                        continue
                    }
                    recordings[index].groupID = payload.groupID
                }
                let mergeReceipt = SessionLogReceipt(
                    sessionID: payload.survivorID,
                    accountUserID: item.accountUserID
                )
                guard PendingSessionDeletePolicy.shouldRestore(
                    insert: .loggedSession(sessionID: payload.survivorID),
                    remoteSessionIDs: remoteSessionIDs,
                    deleteIsClaimed: routineUndo.isClaimed(mergeReceipt)
                ) else { continue }
                pendingSessions[payload.survivorID] = pendingSession(
                    id: payload.survivorID,
                    draft: payload.draft,
                    accountUserID: currentUserID,
                    rpeConfirmed: payload.rpeConfirmed,
                    groupID: payload.groupID,
                    rejected: rejected
                )
            case .recordingDelete:
                continue
            case let .workout(draft):
                let receipt = SessionLogReceipt(
                    sessionID: draft.sessionID,
                    accountUserID: item.accountUserID
                )
                guard PendingSessionDeletePolicy.shouldRestore(
                    insert: .manualWorkout(sessionID: draft.sessionID),
                    remoteSessionIDs: remoteSessionIDs,
                    deleteIsClaimed: routineUndo.isClaimed(receipt)
                ) else { continue }
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
            case .preset, .routine, .phaseTransition, .tagMutation, .healthWrite:
                // #916/#917/#918/#919: a preset, routine, phase transition,
                // tag mutation or health write keeps its optimistic state in
                // its own account-scoped cache row (which this restore pass
                // reads separately), so there is no in-memory overlay to
                // rebuild from the queue payload. The durable intent only
                // drives the replay.
                continue
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

    private func mergeSessions(
        remote: [SendmeterCore.Session],
        markLoaded: Bool = true
    ) {
        let visibleRemote = remote.filter { session in
            !routineUndo.hasPendingDelete(
                sessionID: session.id,
                accountUserID: currentUserID
            )
                // #942: a queued merge keeps its merged-away rows out of the
                // published list — the server still returns them until the
                // RPC lands.
                && pendingMergedAwaySessionIDs[session.id] != currentUserID
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
        if markLoaded {
            // Whether the fetch came back empty or not, an authoritative
            // publication has loaded the account's session list once —
            // consumers can distinguish "no history" from "not fetched yet"
            // (#652 F2).
            hasLoadedSessions = true
        }
        publishReadinessWidgetSnapshot()
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
        publishReadinessWidgetSnapshot()
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

    /// Clear every account-scoped surface.
    ///
    /// #936: the manual-workout lifecycle owner tears ITS workout down here —
    /// with no account named (`nil`), because on every path that reaches this
    /// method the model has already cleared its session, so there is no account
    /// left to protect. The account boundaries that still know the outgoing
    /// account tear their workout down themselves, before this reset, naming
    /// it (see `handleAuthEvent`).
    private func resetAccountState() {
        accountEpoch &+= 1
        // Remove a different account's snapshot at the same synchronous
        // boundary as the visible model. A same-account bootstrap keeps its
        // last valid glance visible until the successful refresh publishes a
        // new epoch, avoiding an unnecessary blank window.
        ReadinessWidgetBridge.reset(for: currentUserID)
        authClockAdvisoryMessage = nil
        // A HealthKit read can be suspended across sign-out/account switch.
        // Invalidate its owner before clearing the visible account snapshot;
        // a stale completion can then neither publish a toast nor release a
        // newer account's gate. The persisted progress remains under the old
        // account key so a later same-account sign-in can resume it.
        morningHealthRefreshOwner = nil
        morningHealthRefreshState.release()
        lastMorningRefreshStartedAt = nil
        lastHealthRefreshStartedAt = nil
        lastHealthSyncedAt = nil
        lastHealthSyncObservation = nil
        // Keep the WatchConnectivity transport on the same account boundary
        // as the in-memory/cache snapshot. Stamped completions for other
        // accounts remain durably parked, but live force, queue telemetry, and
        // unstamped legacy completions are never visible after this point.
        watch.setAccountScope(currentUserID)
        watch.clearAccountTransientState()
        // A cache failure is account-scoped for diagnostics: the next account
        // should be able to report its own open/read/reconcile failure even if
        // the previous account already suppressed one.
        cacheOpenFailureReported = false
        // #964: a new account starts without the previous account's load
        // failure — the Dashboard failure state is account-scoped like the
        // rest of the reset snapshot.
        dashboardLoadFailureClass = nil
        // #920/#923: the previous account's measured retry outcome, its retry
        // progress and its partial-refresh failure never carry into the next
        // account's screens (account-scoped like the rest of the snapshot).
        lastRetryOutcome = nil
        isRetryingQueuedWrites = false
        queuedWritesRetryGate.reset()
        lastPartialRefreshFailure = nil
        publishForceProgressInputMutation(.accountReset)
        refreshingOwner = nil
        isRefreshing = false
        dataRefreshOwners.removeAll()
        isLoadingData = false
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
        hasLoadedRecordings = false
        forceModel.hasLoadedRecordings = false
        recordings = []
        presets = []
        routines = []
        workouts = []
        tagMetadata = []
        passkeys = []
        pendingSessions = [:]
        pendingMergedAwaySessionIDs.removeAll()
        watchCompletionAdoption.reset()
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
        signOutRemainderCount = nil
        if let staleSignOutRemainderContinuation = signOutRemainderContinuation {
            signOutRemainderContinuation = nil
            staleSignOutRemainderContinuation.resume(returning: .cancel)
        }
        // Upload claims belong to their in-flight tasks, not to the loaded UI
        // snapshot. Keep them until upload's defer releases them: an A→B→A
        // account transition must not let the returning A duplicate a request
        // that is still suspended for A. B can proceed through its own key.
        queuedWriteCount = 0
        queuedWriteDiagnostics = []
        pendingCacheWriteCount = 0
        pendingTagWriteCount = 0
        queueBreadcrumbs = []
        quarantinedWrites = nil
        // #920: the new account's pending-write state has not been read yet.
        hasLoadedPendingWrites = false
        gaugeSessionTracker.reset()
        handsFreeSaveInFlight = false
        forceModel.guidedProtocolActive = false
        guidedProtocolTeardown = nil
        guidedProtocolTeardownOwnerID = nil
        invalidateTagCurveCache()
        handsFree.handleDisconnected()
        // #936: the manual-workout lifecycle owner tears ITS workout down —
        // the live card, the rest deadline and the workout's queued lock-screen
        // actions. No account is named here (see the method's doc comment): the
        // boundaries that still know the outgoing account tear down before this
        // reset.
        applyManualWorkoutLifecycle(
            manualWorkoutLifecycle.accountChanged(previousAccountUserID: nil)
        )
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

    private func markPurgeGenerationAvailable(capturedBy accountFetch: AccountScopedFetch) {
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return }
        purgeGenerationFailurePolicy.markAvailable(
            accountUserID: accountFetch.accountUserID,
            accountEpoch: accountFetch.accountEpoch
        )
    }

    private func reportPurgeGenerationFailure(
        _ error: Error,
        context: PurgeGenerationRefreshContext,
        capturedBy accountFetch: AccountScopedFetch
    ) {
        guard accountFetch.canApply(
            to: currentUserID,
            accountEpoch: accountEpoch
        ) else { return }
        guard purgeGenerationFailurePolicy.shouldSurface(
            context: context,
            accountUserID: accountFetch.accountUserID,
            accountEpoch: accountFetch.accountEpoch
        ) else { return }
        surface(error)
    }

    private func surface(_ error: Error) {
        errorMessage = UserFacingError.message(for: error)
        recoverAuthFrom(error)
    }

    /// The exact-session recovery side effect of `surface(_:)`, kept separate
    /// so a suppressed banner (#842 background refresh with last-good data)
    /// still heals a rejected bearer instead of leaving the session poisoned.
    private func recoverAuthFrom(_ error: Error) {
        // A rejected bearer can surface as a PostgREST 401 before GoTrue's
        // refresh path gets a chance to report it. Start the same exact-
        // session recovery asynchronously; the current-session check inside
        // AuthService prevents an old request from signing out a newer
        // account.
        guard let postgRESTError = error as? PostgRESTError else { return }
        Task { @MainActor [weak self] in
            await self?.auth.recoverFromAuthFailure(postgRESTError)
        }
    }
}
