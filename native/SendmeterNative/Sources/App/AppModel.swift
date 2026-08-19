import Auth
import Combine
import Foundation
import SendLogHealthCore
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

private enum PendingWrite: Codable, Sendable {
    case session(SessionQueuePayload)
    case sessionDelete(SessionDeleteQueuePayload)
    case recording(NewTindeqRecording)
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
        case .workout: kind = "Phone workout"
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

private struct TagCurveKey: Hashable {
    let tag: String
    let modality: String
}

@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var bootState: AppBootState = .loading
    @Published public private(set) var authSession: AuthSession?
    @Published public private(set) var sessions: [SendmeterCore.Session] = []
    /// True once the session list has been fetched at least once for the
    /// current account (even if it came back empty). Sessions have no disk
    /// cache — `refreshAll` fetches them over the network and `sessions` stays
    /// `[]` until that resolves — so `sessions.isEmpty` alone cannot tell "no
    /// history" from "not loaded yet". Consumers (the ACWR projection card)
    /// use this to avoid claiming a fresh user has no history on every cold
    /// launch or failed refresh (#652 F2).
    @Published public private(set) var hasLoadedSessions = false
    @Published public private(set) var deletedSessions: [SendmeterCore.Session] = []
    @Published public private(set) var deletedRecordings: [TindeqRecording] = []
    @Published public private(set) var healthMetrics: [HealthMetric] = []
    @Published public private(set) var phasePeriods: [PhasePeriod] = []
    @Published public private(set) var settings = UserSettings(
        currentPhase: .capacity,
        phaseStartDate: LocalDateSupport.string(from: Date())
    )
    /// True once the recording list has been fetched and merged at least once
    /// for the current account (even if it came back empty). Recordings have
    /// no disk cache, so `recordings.isEmpty` cannot distinguish "no force
    /// history" from "not fetched yet" or an initial fetch failure. Consumers
    /// use this to keep the Force consistency card's empty state honest.
    @Published public private(set) var hasLoadedRecordings = false
    @Published public private(set) var recordings: [TindeqRecording] = []
    @Published public private(set) var presets: [TindeqPreset] = []
    @Published public private(set) var routines: [RoutinePreset] = []
    @Published public private(set) var workouts: [WorkoutListItem] = []
    @Published public private(set) var liveWorkout: LiveWorkout?
    @Published public private(set) var liveWorkoutSyncState: LiveWorkoutSyncState = .unknown
    /// #631: the per-user tag registry (SL-92) — rename/hide metadata. Tags
    /// themselves stay denormalized on recordings.
    @Published public private(set) var tagMetadata: [TagMetadata] = []
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var queuedWriteCount = 0
    @Published public private(set) var queueBreadcrumbs: [QueueBreadcrumb] = []
    /// #675: entries the server has permanently rejected — retained on device,
    /// excluded from every automatic retry, and recoverable only by the
    /// explicit Retry/Discard actions in Settings. `nil` means the queue has
    /// not been read yet this session; `[]` means genuinely nothing
    /// quarantined. Never default to `[]` where the honest state is "not
    /// known" (#269 honest-states rule — unknown must not render as empty).
    @Published public private(set) var quarantinedWrites: [QuarantinedWrite]?
    @Published public var errorMessage: String?
    @Published public private(set) var toast: AppToastState?
    /// Compatibility accessors keep existing call sites readable while the
    /// published source of truth is one identity-bearing toast instance.
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
    @Published public var passwordRecovery = false
    @Published public var selectedTab: AppTab = .dashboard
    /// #627: the fitted per-tag curves the gauge-session RPE prediction reads.
    @Published public private(set) var tagCurves: [TagForceCurve] = []
    /// True while a guided protocol runs: the run owns its session end (its
    /// interrupted path preserves the final rep and THEN ends the session),
    /// so the generic disconnect trigger defers to it.
    @Published public private(set) var guidedProtocolActive = false
    /// #632: true while a user-initiated sign-out is in flight (drain + any
    /// remainder prompt + auth.signOut) — used to disable the Sign Out button
    /// so a double-tap can't run two drains against one queue.
    @Published public private(set) var isSigningOut = false
    /// #632: non-nil while the sign-out remainder prompt is showing — the
    /// count the user is deciding about, presented by SettingsView as a
    /// confirmation dialog (Sign Out / Cancel) and resolved through
    /// `resolveSignOutRemainder`. The prompt appears ONLY when the pre-sign-
    /// out drain left something behind; a clean drain never asks.
    @Published public private(set) var signOutRemainderCount: Int?
    private var signOutRemainderContinuation: CheckedContinuation<SignOutRemainderChoice, Never>?

    public let auth: AuthService
    public let repository: SendmeterRepository
    public let tindeq: TindeqBluetooth
    public let health: HealthKitService
    public let watch: WatchConnectivityService
    public let realtime: RealtimeService
    /// #631: Send Conditions (SL-69) — Open-Meteo current weather + local
    /// climate, fetched + cached by the platform service.
    public let weather: WeatherService
    /// #628: hands-free arming loop (load-triggered start/stop/save).
    public let handsFree: HandsFreeForceController
    /// #628: lock-screen Live Activity mirror of the guided protocol.
    public let guidedActivity: GuidedProtocolActivityManager
    /// #627: in-flight rep saves the session-end snapshot waits for.
    public let gaugeSessionSaveGate: GaugeSessionSaveGate
    /// #628: refcounted screen keep-awake while connected/armed/measuring.
    public let keepAwake: KeepAwakeCoordinator

    public private(set) var gaugeSessionTracker = GaugeSessionTracker()
    public var freePullContext = FreePullContext()

    /// #656 (review F1): the one way a user asks to connect the Progressor.
    /// Marks the transport as user-initiated for THIS LAUNCH so the
    /// success/error haptics in the `$status` sink may fire — a cold launch
    /// with Bluetooth off has no user gesture behind it and must stay silent.
    public func requestConnect() {
        transportUserInitiated = true
        tindeq.connect()
    }

    private let queue: DurableQueue<PendingWrite>?
    private var authObservationTask: Task<Void, Never>?
    private var pendingSessions: [UUID: SendmeterCore.Session] = [:]
    private var pendingRecordings = PendingRecordingOverlay()
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
    private var recomputeGate = ReadinessRecomputeGate()
    /// #661: silent foreground/appear health sync. The policy is pure Core
    /// (`HealthRefreshPolicy`, unit-tested); `lastHealthRefreshStartedAt` is
    /// the monotonic system-uptime time the most recent actual refresh started
    /// (never wall-clock — an NTP step or manual clock change must not suppress
    /// every refresh for the skew, finding 7). The window mirrors the web's
    /// `FOREGROUND_SYNC_COALESCE_MS` (5s).
    private let healthRefreshPolicy = HealthRefreshPolicy(coalescingWindow: 5)
    private var lastHealthRefreshStartedAt: TimeInterval?
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
    private var liveMirrorTicker: Task<Void, Never>?
    /// Realtime list reconciliation: pending slices + the scheduled flush.
    private let reconcileCoalescer = RealtimeRefreshCoalescer()
    private var reconcileFlushTask: Task<Void, Never>?
    private var tagCurveCache: [TagCurveKey: TagForceCurve] = [:]
    private var keepAwakeRelease: (() -> Void)?
    private var pendingWarmKeys: Set<TagCurveKey> = []
    private var warmTask: Task<Void, Never>?

    public init(
        auth: AuthService? = nil,
        repository: SendmeterRepository = SendmeterRepository(),
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
        self.repository = repository
        self.tindeq = tindeq ?? TindeqBluetooth()
        self.health = health ?? HealthKitService()
        self.watch = watch ?? WatchConnectivityService()
        self.realtime = realtime ?? RealtimeService()
        self.weather = weather ?? WeatherService()
        self.handsFree = HandsFreeForceController()
        self.guidedActivity = GuidedProtocolActivityManager()
        self.gaugeSessionSaveGate = GaugeSessionSaveGate()
        self.keepAwake = KeepAwakeCoordinator { active in
            await MainActor.run {
                UIApplication.shared.isIdleTimerDisabled = active
            }
        }

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
        let weather = self.weather
        let health = self.health

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
        tindeq.onWeightSample = { [weak self] sample in
            self?.handsFree.feed(
                atMs: Date().timeIntervalSince1970 * 1_000,
                kg: sample.kilograms
            )
        }

        tindeq.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &nestedCancellables)
        watch.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &nestedCancellables)
        weather.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &nestedCancellables)
        health.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &nestedCancellables)
        // #627/#628: a disconnect ends the gauge session (auto-log) — unless
        // a guided protocol is running, whose interrupted path preserves the
        // final rep and then ends the session itself (so the last rep can
        // never be orphaned into a fresh group by a racing end). The
        // keep-awake hold follows the transport + arming state. #656: the
        // transport's transitions carry the success/error haptics — connect
        // succeeds, a drop (or deliberate disconnect) errors. The success
        // fires ONLY on a `.connecting`/`.scanning` → `.connected` transition,
        // never when `stopMeasuring()` re-sets `.connected` after a rep.
        tindeq.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                let previous = self.lastTransportStatus
                self.lastTransportStatus = status
                // #656 (review F1/F2): the transport cues success/error only
                // when a user gesture armed them this launch — `connect()`
                // called from the Force tab — and only once per logical
                // event. A cold launch with Bluetooth off is `.idle →
                // .interrupted` with no user intent, and must stay silent.
                // A single Bluetooth-off delivers TWO different
                // `.interrupted` values back-to-back (the `.poweredOff` state
                // change and the `didDisconnect`), so consecutive error
                // statuses collapse to one cue.
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
                    self.handsFree.handleDisconnected()
                    if !self.guidedProtocolActive {
                        Task { @MainActor in await self.endGaugeSession() }
                    }
                }
                self.updateKeepAwake()
            }
            .store(in: &nestedCancellables)
        tindeq.$handsFreeArmed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateKeepAwake()
            }
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
        await perform {
            try await self.repository.setTagHidden(name: name, hidden: hidden)
            if let index = self.tagMetadata.firstIndex(where: { $0.name == name }) {
                self.tagMetadata[index] = TagMetadata(name: name, hidden: hidden)
            } else {
                self.tagMetadata.append(TagMetadata(name: name, hidden: hidden))
            }
            self.toastMessage = hidden ? "Hid “\(name)”" : "Showing “\(name)”"
        }
    }

    /// Rename a tag EVERYWHERE — the DB repoints every recording carrying
    /// the old name; the recording list is refetched after (its tags are
    /// the source of truth for counts).
    public func renameTag(oldName: String, newName: String) async {
        let merged = tagEntries.contains { $0.name == newName.trimmingCharacters(in: .whitespacesAndNewlines) }
        await perform {
            try await self.repository.renameTag(oldName: oldName, newName: newName)
            self.toastMessage = merged
                ? "Merged into “\(newName.trimmingCharacters(in: .whitespacesAndNewlines))”"
                : "Renamed to “\(newName.trimmingCharacters(in: .whitespacesAndNewlines))”"
            await self.refreshAll(showSpinner: false)
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
    }

    public func becameActive() async {
        // #674 review F7: clear any guided Live Activity stranded by a
        // force-quit / jetsam BEFORE the auth gate — a killed app never ran
        // the in-process teardown, and relaunch is the only chance to retire
        // the card. No-op while a run is in progress.
        guidedActivity.reconcileOrphans()
        guard authSession != nil else { return }
        await relayValidSessionToWatch(guaranteed: false)
        await drainQueue()
        await refreshAll(showSpinner: false)
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
            let valid = try await self.auth.client.auth.session
            authSession = valid
            watch.relaySession(valid, guaranteed: guaranteed)
        } catch {
            watch.relaySession(nil, guaranteed: guaranteed)
        }
    }

    // MARK: Loading

    public func refreshAll(showSpinner: Bool = true) async {
        guard let userID = currentUserID else { return }
        let accountFetch = AccountScopedFetch(accountUserID: userID)
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
            async let remoteTags = repository.fetchTagMetadata()

            let fetchedSessions = try await remoteSessions
            let fetchedRecordings = try await remoteRecordings
            settings = try await remoteSettings
            phasePeriods = try await remotePeriods
            healthMetrics = try await remoteHealth
            presets = try await remotePresets
            routines = try await remoteRoutines
            workouts = try await remoteWorkouts
            tagMetadata = try await remoteTags
            await restorePendingWrites(
                accountFetch: accountFetch,
                userID: userID,
                remoteSessionIDs: Set(fetchedSessions.map(\.id)),
                remoteRecordingIDs: Set(fetchedRecordings.map(\.id))
            )
            guard accountFetch.canApply(to: currentUserID) else { return }
            mergeSessions(remote: fetchedSessions)
            mergeRecordings(remote: fetchedRecordings)
            hasLoadedRecordings = true
            await refreshQueueCount()
            warmTagCurvesIfMissing()
        } catch {
            surface(error)
        }
    }

    /// #627: warm the per-tag curve cache in the background for every tag
    /// currently in the recordings (bounded by the pick window inside
    /// `ForceCurveEngine.pickCurveRecordings`), so the gauge-session end
    /// reads cached curves instead of fetching.
    public func warmTagCurvesIfMissing() {
        var keys = Set<TagCurveKey>()
        for recording in recordings where !recording.tag.isEmpty {
            keys.insert(
                TagCurveKey(
                    tag: recording.tag,
                    modality: GaugeSessionRPE.modality(of: recording)
                )
            )
        }
        for key in keys where tagCurveCache[key] == nil {
            warmTagCurveIfMissing(tag: key.tag, modality: key.modality)
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
        return await enqueueAndUpload(item)
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
            // #632: the workout draft is lost — see the notice write in
            // `saveForceSummary`.
            LostRecordingStore.note(reason: "workout", in: .standard)
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

        // The session-end snapshot must count this rep, so the gate is
        // claimed synchronously — before the first await below (#613's
        // RepSettlement contract).
        await gaugeSessionSaveGate.begin()
        defer {
            Task { await gaugeSessionSaveGate.finish() }
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
            note: "",
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
        pendingRecordings.insert(optimistic, accountUserID: userID)
        mergeRecordings(
            remote: recordings.filter {
                !pendingRecordings.contains(id: $0.id, accountUserID: userID)
            }
        )
        let item = DurableQueueItem(
            id: recording.id,
            accountUserID: userID,
            payload: PendingWrite.recording(recording)
        )
        let enqueued = await enqueueAndUpload(item)
        if !enqueued {
            // #632: the rep is lost — the only copy was the in-memory
            // optimistic row being discarded below. The durable one-shot
            // notice IS the out-loud reporting (no Sentry in this target);
            // `surfaceLostRecordingNoticeIfAny` shows it on next foreground.
            LostRecordingStore.note(reason: "recording", in: .standard)
            pendingRecordings.removeValue(for: recording.id, accountUserID: userID)
            mergeRecordings(
                remote: recordings.filter {
                    !pendingRecordings.contains(id: $0.id, accountUserID: userID)
                }
            )
        }
        // #627: warm the tag's fitted curve in the background so the
        // session-end prediction reads a cached curve instead of fetching.
        let savedModality = recording.protocolMode == .reverseAction ? "reverse_action" : "static"
        warmTagCurveIfMissing(tag: recording.tag, modality: savedModality)
        return enqueued
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
    public func endGaugeSession() async {
        // #613: wait for any in-flight rep save to become durable + locally
        // published BEFORE claiming the end — a disconnect's interrupted
        // save lands after the status change (the guided view's tick
        // preserves the partial rep), and a late rep must join THIS group,
        // not mint a new one. Bounded by local persistence, never the
        // network. The claim after the wait still precedes any await of the
        // insert, so concurrent end paths still log exactly once.
        await gaugeSessionSaveGate.waitForIdle()
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
        toastMessage = ok
            ? "Gauge session logged to history"
            : "Couldn't log gauge session"
    }

    /// #628: a guided protocol's run owns the disconnect-triggered session
    /// end (its interrupted path preserves the final rep first); the generic
    /// disconnect trigger defers while this is set.
    public func setGuidedProtocolActive(_ active: Bool) {
        guidedProtocolActive = active
    }

    /// The keep-awake hold follows the transport + arming state (#628): the
    /// screen stays awake while connected (a short auto-lock must never cut
    /// a hold or protocol), armed, or measuring — the web's `useWakeLock`
    /// rule — and the last release restores the idle timer.
    public func scenePhaseChanged(_ phase: ScenePhase) {
        if phase == .active {
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
            errorMessage = error.localizedDescription
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
        Task {
            let trimmed = trimSummary(summary, endMilliseconds: trimEndMilliseconds)
            let enqueued = await saveForceSummary(
                trimmed,
                tag: context.tag,
                side: context.side,
                zone: context.zone,
                preset: context.preset,
                targetBand: context.targetBand
            )
            if enqueued {
                tindeq.clearCompletedRecording()
                handsFree.rearmAfterSave()
            } else {
                handsFree.disarm()
                errorMessage = "Hands-free pull couldn't be saved."
            }
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
            guard !recording.tag.isEmpty, !seen.contains(key) else { return nil }
            seen.insert(key)
            return tagCurveCache[key]
        }
    }

    /// Background-warm the tag's fitted curve (mirrors the web's cached
    /// `fetchTagCurves()` registry): computed from the native recordings via
    /// ForceCurveEngine, cached per tag+modality. Requests are queued and
    /// drained by ONE background task, so a burst (refreshAll warming every
    /// tag at once) warms them all instead of cancelling down to the last.
    public func warmTagCurveIfMissing(tag: String, modality: String) {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, !modality.isEmpty else { return }
        let key = TagCurveKey(tag: tag, modality: modality)
        guard tagCurveCache[key] == nil else { return }
        pendingWarmKeys.insert(key)
        guard warmTask == nil else { return }
        warmTask = Task { [weak self] in
            await self?.drainWarmQueue()
        }
    }

    private func drainWarmQueue() async {
        warmTask = nil
        while !Task.isCancelled {
            let keys = Array(pendingWarmKeys)
            pendingWarmKeys = []
            guard !keys.isEmpty else { return }
            for key in keys {
                guard !Task.isCancelled else { return }
                let normalized = key.tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let curve = await computeTagCurve(
                    tag: key.tag,
                    modality: key.modality,
                    normalizedTag: normalized
                ) {
                    tagCurveCache[key] = curve
                    publishTagCurves()
                }
            }
        }
    }

    private func publishTagCurves() {
        tagCurves = tagCurveCache.values.sorted {
            $0.tag < $1.tag || ($0.tag == $1.tag && $0.modality < $1.modality)
        }
    }

    private func computeTagCurve(
        tag: String,
        modality: String,
        normalizedTag: String
    ) async -> TagForceCurve? {
        let byTag = recordings.filter {
            $0.tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedTag
                && !pendingRecordings.contains(id: $0.id, accountUserID: currentUserID)
                && modalityFilter($0, modality: modality)
                // #651: warm-up/prehab (submaximal) and salvage blobs
                // (inflated duration / deflated avg) corrupt CF/W′ — exclude
                // them exactly like the web's `curveCandidateRecordings`.
                && ZoneMix.isCurveFitCandidate($0)
        }
        guard !byTag.isEmpty else { return nil }
        let candidates = ForceCurveEngine.pickCurveRecordings(byTag)
        guard !candidates.isEmpty else { return nil }
        let sampleSets = await withTaskGroup(of: [TindeqSample]?.self) { group in
            for candidate in candidates {
                group.addTask {
                    let samples = try? await self.repository.fetchRecordingSamples(id: candidate.id)
                    return (samples?.isEmpty == false) ? samples : nil
                }
            }
            var values: [[TindeqSample]] = []
            for await result in group {
                if let result { values.append(result) }
            }
            return values
        }
        guard !sampleSets.isEmpty else { return nil }
        let references = await Task.detached(priority: .utility) {
            ForceCurveEngine.references(metadata: byTag, sampleSets: sampleSets)
        }.value
        guard let cf = references.criticalForceKilograms,
              let wPrime = references.impulseAboveCriticalForceKilogramSeconds
        else { return nil }
        return TagForceCurve(
            tag: tag,
            modality: modality,
            cf: cf,
            wPrime: wPrime,
            maxForceKilograms: references.maximumForceKilograms
        )
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
                    }
                }
                if let index = self.sessions.firstIndex(where: { $0.id == session.id }),
                   self.sessions[index].groupID != result.groupID {
                    var updated = self.sessions[index]
                    updated.groupID = result.groupID
                    self.sessions[index] = updated
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
        guard currentUserID != nil else { return false }
        guard let plan = SelectionSessionPlanner.plan(
            recordings: recordings,
            phase: settings.currentPhase
        ) else { return false }
        do {
            let sessionID = UUID()
            let saved = try await repository.insertSession(plan.draft, id: sessionID)
            let result = try await repository.linkRecordingsToSession(
                sessionID: sessionID,
                recordingIDs: plan.recordingIDs
            )
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
                    }
                }
            } else {
                replaceSession(saved)
            }
            toastMessage = "Session created from recordings"
            return true
        } catch {
            surface(error)
            return false
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
                try await repository.upsertHealthMetric(plan.upsertMetric, userID: userID)
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
        await perform {
            try await self.repository.deleteAccount()
            try await self.queue?.discardAll(accountUserID: userID, reason: "account-deleted")
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
        toastMessage = "\(label) couldn't be saved"
    }
    // MARK: Offline queue

    public func drainQueue() async {
        guard let userID = currentUserID, let queue else { return }
        let due = await queue.items(for: userID, dueAt: Date())
        for item in due {
            _ = await upload(item)
        }
        await refreshQueueCount()
    }

    public func retryAllQueuedWrites() async {
        guard let userID = currentUserID, let queue else { return }
        let pending = await queue.items(for: userID)
        for item in pending {
            _ = await upload(item, mode: .manual)
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
                _ = await self?.upload(item)
            }
            return true
        } catch {
            surface(error)
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
    }

    @discardableResult
    private func upload(
        _ item: DurableQueueItem<PendingWrite>,
        mode: QueueUploadMode = .automatic
    ) async -> UploadResult {
        guard let queue, currentUserID == item.accountUserID else {
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
        defer { inFlightUploadClaims.release(uploadClaim) }

        // Queue reads are snapshots. Re-read through the active queue filter
        // after claiming the item so an automatic producer cannot upload an
        // item that another producer quarantined while this snapshot was
        // suspended. Manual retries are allowed to bypass ordinary backoff,
        // but never the non-quarantined filter.
        guard let currentItem = await queue.activeItem(
            id: item.id,
            accountUserID: item.accountUserID,
            dueAt: mode.revalidationDueAt(now: Date())
        ), currentUserID == item.accountUserID else {
            return UploadResult(uploaded: false, failure: nil)
        }
        let item = currentItem
        let result: UploadResult
        do {
            var sessionReceipt: SessionLogReceipt?
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
                    guard currentUserID == item.accountUserID else {
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
                    }
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
                let hasPendingInsert = await queue.items(
                    for: item.accountUserID,
                    includeQuarantined: true
                ).contains { queued in
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
                guard currentUserID == item.accountUserID else {
                    // The request belonged to the original account. Leave
                    // the durable intent for that account to reconcile rather
                    // than allowing a new account's UI to acknowledge it.
                    return UploadResult(uploaded: false, failure: nil)
                }
                completedDeleteReceipt = receipt
            case let .recording(recording):
                let saved = try await self.repository.insertRecording(recording)
                pendingRecordings.removeValue(
                    for: recording.id,
                    accountUserID: item.accountUserID
                )
                replaceRecording(saved)
            case let .workout(draft):
                let saved = try await self.repository.insertPhoneWorkout(draft)
                pendingSessions.removeValue(forKey: draft.sessionID)
                replaceSession(saved)
            }
            if let sessionReceipt, routineUndo.isClaimed(sessionReceipt) {
                suppressSavedToast = true
            }
            do {
                try await queue.remove(
                    id: item.id,
                    accountUserID: item.accountUserID,
                    reason: "uploaded"
                )
            } catch let error as DurableQueueError {
                // Undo may have removed the same queue item while its upload
                // was in flight. That is already the desired terminal state.
                if !(suppressSavedToast && error == .itemNotFound) { throw error }
            }
            if let finishedSessionInsertID {
                await uploadPendingSessionDelete(
                    sessionID: finishedSessionInsertID,
                    accountUserID: item.accountUserID
                )
            }
            if let completedDeleteReceipt {
                guard currentUserID == item.accountUserID else {
                    return UploadResult(uploaded: false, failure: nil)
                }
                _ = routineUndo.markDeleteCompleted(
                    completedDeleteReceipt,
                    currentUserID: item.accountUserID
                )
                sessions.removeAll { $0.id == completedDeleteReceipt.sessionID }
                mergeSessions(remote: sessions.filter { !$0.pending })
            }
            if !suppressSavedToast { toastMessage = "Saved" }
            result = UploadResult(uploaded: true, failure: nil)
        } catch {
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
                try await queue.markFailure(
                    id: item.id,
                    accountUserID: item.accountUserID,
                    error: error.localizedDescription,
                    classification: classification,
                    code: code,
                    countsTowardQuarantine: mode.countsTowardQuarantine
                )
                result = UploadResult(
                    uploaded: false,
                    failure: UploadFailure(
                        classification: classification,
                        code: code,
                        detail: error.localizedDescription
                    )
                )
            } catch {
                surface(error)
                result = UploadResult(uploaded: false, failure: nil)
            }
        }
        await refreshQueueCount()
        return result
    }

    /// Starts a delete that was intentionally held behind a matching session
    /// insert. The delete remains durable if this process goes away before
    /// the follow-up upload completes.
    private func uploadPendingSessionDelete(
        sessionID: UUID,
        accountUserID: UUID
    ) async {
        guard currentUserID == accountUserID, let queue else { return }
        let queued = await queue.items(
            for: accountUserID,
            dueAt: Date()
        )
        guard let deleteItem = queued.first(where: { item in
            guard case let .sessionDelete(payload) = item.payload else { return false }
            return payload.sessionID == sessionID
        }) else { return }
        _ = await upload(deleteItem)
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
        let quarantined = await queue.quarantinedItems(for: userID)
        for item in quarantined where id == nil || item.id == id {
            do {
                guard let previous = try await queue.retryQuarantined(
                    id: item.id,
                    accountUserID: item.accountUserID
                ) else { continue }
                let result = await upload(item, mode: .manual)
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
                surface(error)
            }
        }
        await refreshQueueCount()
    }

    /// #675: discard ONE quarantined entry. Quarantined-only (the Settings
    /// surface's Discard action is never offered for an active entry); the
    /// #273 sign-out and account-deletion paths keep their own removal rules,
    /// so this is the only per-item discard site. Also drops the restored
    /// rejected placeholder from History/Force — a discarded entry is gone,
    /// it must not keep rendering as "Rejected" (#675 F1).
    public func discardQuarantinedWrite(id: UUID) async {
        guard let userID = currentUserID, let queue else { return }
        do {
            let item = await queue.item(id: id, accountUserID: userID)
            if try await queue.discardQuarantined(id: id, accountUserID: userID) {
                guard currentUserID == userID else {
                    await refreshQueueCount()
                    return
                }
                if let item, case let .sessionDelete(payload) = item.payload {
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
                    return
                }
                pendingSessions.removeValue(forKey: id)
                pendingRecordings.removeValue(for: id, accountUserID: userID)
                sessions.removeAll { $0.id == id }
                recordings.removeAll { $0.id == id }
            }
        } catch {
            surface(error)
        }
        await refreshQueueCount()
    }

    private func refreshQueueCount() async {
        guard let userID = currentUserID, let queue else {
            queuedWriteCount = 0
            queueBreadcrumbs = []
            quarantinedWrites = nil
            return
        }
        queuedWriteCount = await queue.count(for: userID)
        queueBreadcrumbs = await queue.breadcrumbs(for: userID)
        quarantinedWrites = await queue.quarantinedItems(for: userID).map { $0.summary() }
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
            let refreshed = try await self.repository.fetchSessions(accountUserID: userID)
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
        let accountFetch = AccountScopedFetch(accountUserID: userID)
        do {
            if slices.contains(.sessions) {
                mergeSessions(remote: try await repository.fetchSessions(accountUserID: userID))
            }
            if slices.contains(.recordings) {
                let fetchedRecordings = try await repository.fetchRecordings()
                guard accountFetch.canApply(to: currentUserID) else { return }
                mergeRecordings(remote: fetchedRecordings)
                hasLoadedRecordings = true
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
        accountFetch: AccountScopedFetch,
        userID: UUID,
        remoteSessionIDs: Set<UUID>,
        remoteRecordingIDs: Set<UUID>
    ) async {
        guard let queue else { return }
        // #675 F1: restore BOTH the active entries AND the quarantined ones.
        // A quarantined write is data the user still owns — it is on device,
        // was permanently rejected, and must stay visible in History/Force
        // after a relaunch (rebuilding the optimistic placeholders from
        // `items(for:)` alone made it vanish: not on the server, and the
        // strict drain filter no longer returns it). The restored placeholder
        // is badged `rejected`, never "Syncing" — it will NOT upload on its
        // own. The hot drain path never sees these (only the Settings
        // Retry/Discard actions touch them).
        let queued = await queue.items(for: userID, includeQuarantined: true)
        // `queue.items` is an async boundary. The account may have switched
        // while it was suspended; no pending state, including routine Undo,
        // may be mutated by that stale restore.
        guard let currentUserID = self.currentUserID,
              accountFetch.canApply(to: currentUserID)
        else { return }
        let restoredRecordings = queued.compactMap { item -> PendingRecordingOverlay.Entry? in
            guard case let .recording(recording) = item.payload,
                  !remoteRecordingIDs.contains(recording.id)
            else { return nil }
            return PendingRecordingOverlay.Entry(
                accountUserID: item.accountUserID,
                recording: pendingRecording(
                    from: recording,
                    rejected: item.quarantined != nil
                )
            )
        }
        guard pendingRecordings.applyRestored(
            restoredRecordings,
            capturedBy: accountFetch,
            currentUserID: currentUserID
        ) else { return }
        // Read delete intents first. A session insert and its Undo delete can
        // overlap in the queue; the delete must win before any optimistic row
        // is rebuilt from the insert payload.
        for item in queued {
            guard case let .sessionDelete(payload) = item.payload else { continue }
            routineUndo.restorePendingDelete(
                SessionLogReceipt(
                    sessionID: payload.sessionID,
                    accountUserID: item.accountUserID
                ),
                currentUserID: currentUserID
            )
        }
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
            case let .workout(draft):
                guard !remoteSessionIDs.contains(draft.sessionID) else { continue }
                pendingSessions[draft.sessionID] = pendingSession(from: draft, rejected: rejected)
            case .recording:
                continue
            }
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
        let remoteIDs = Set(remote.map(\.id))
        if let currentUserID {
            pendingRecordings.removeValues(withIDs: remoteIDs, accountUserID: currentUserID)
        }
        recordings = pendingRecordings
            .merged(remote: remote, accountUserID: currentUserID)
            .sorted { $0.recordedAt > $1.recordedAt }
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
        sessions = (visibleRemote + pendingSessions.values.filter { !remoteIDs.contains($0.id) })
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
        sessions.append(session)
        sessions.sort {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString > $1.id.uuidString
        }
        hasLoadedSessions = true
    }

    private func replaceRecording(_ recording: TindeqRecording) {
        recordings.removeAll { $0.id == recording.id }
        recordings.append(recording)
        recordings.sort { $0.recordedAt > $1.recordedAt }
    }

    private func clearLoadedData() {
        sessions = []
        hasLoadedSessions = false
        deletedSessions = []
        deletedRecordings = []
        healthMetrics = []
        phasePeriods = []
        hasLoadedRecordings = false
        recordings = []
        presets = []
        routines = []
        workouts = []
        tagMetadata = []
        pendingSessions = [:]
        pendingRecordings = PendingRecordingOverlay()
        routineUndo.reset()
        // Upload claims belong to their in-flight tasks, not to the loaded UI
        // snapshot. Keep them until upload's defer releases them: an A→B→A
        // account transition must not let the returning A duplicate a request
        // that is still suspended for A. B can proceed through its own key.
        queuedWriteCount = 0
        queueBreadcrumbs = []
        quarantinedWrites = nil
        gaugeSessionTracker.reset()
        guidedProtocolActive = false
        tagCurveCache = [:]
        tagCurves = []
        handsFree.handleDisconnected()
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
        errorMessage = error.localizedDescription
    }
}
