import CoreBluetooth
import Foundation
import Observation
import SendLogWatchCore
import WatchConnectivity

protocol TindeqRecordingQueueing: Sendable {
    func enqueue(_ pending: PendingTindeqRecording) async -> QueuePersistOutcome
}

extension PendingRecordingQueue: TindeqRecordingQueueing {}

protocol TindeqSessionQueueing: Sendable {
    func enqueue(_ pending: PendingTindeqSession) async -> QueuePersistOutcome
}

extension PendingSessionQueue: TindeqSessionQueueing {}

/// CoreBluetooth central for the Tindeq Progressor. Mirrors the web app's
/// useTindeq hook: same statuses, 10 min recording cap, t rounded to ms int,
/// kg to 2 dp, identical summary — recordings look the same in the web UI.
@Observable
final class TindeqManager: NSObject {
    enum Status {
        case unsupported, idle, scanning, connecting, connected, measuring
    }

    var status: Status = .idle
    var errorMsg: String?
    var lowBattery = false
    // UI values, published at ~10 Hz (not per 80 Hz notification)
    var currentKg: Double = 0
    var peakKg: Double = 0
    var elapsedMs: Double = 0
    private(set) var handsFreeState = idleHandsFreeForce()
    private(set) var handsFreeRequested = false
    /// SL-584: which start affordance the Force ready card presents while
    /// connected — hands-free arm (default) or the classic tap-to-start.
    /// Deliberately per-launch and NOT persisted (approved design Q3):
    /// hands-free is the decided default flow, and a persisted tap
    /// preference would silently defeat it on every future launch. Lives
    /// here rather than in view `@State` so the choice survives the Force
    /// view being popped and recreated within one app launch.
    var preferTapToStart = false
    private(set) var saving = false
    private(set) var savedMsg: String?

    // Gauge session grouping (SL-58 #5): every rep saved during one connect
    // shares a group_id, minted lazily on the first save. Lives on the manager
    // (which is owned app-level) — not on the view — so it survives navigating
    // away from the Force screen while the Progressor stays connected.
    var sessionId: UUID?
    var sessionStartedAt: Date?
    var sessionCount = 0

    /// Per-tag force curves (#280), refreshed by `ForceGaugeView`'s tag fetch
    /// — the same round trip that fills the exercise picker. Lives here, not
    /// on the view, because the disconnect-salvage path below saves reps too,
    /// long after the Force screen may have gone away.
    var tagCurves: [String: TindeqTagInfo] = [:]
    /// Running Σ d_i of the session (#280): each saved rep's W' depletion,
    /// measured against ITS OWN tag's curve. Reps whose tag has no fitted
    /// curve contribute nothing; if none of them did, `predicted` falls back.
    private var depletion = SessionDepletionAccumulator()

    // SL-87 live mirror: the phone Force tab shows what the watch gauge is
    // doing. The view keeps these in sync with its pickers so beats carry the
    // exercise context.
    var liveTag = "" { didSet { pushForceBeat() } }
    var liveSide = "" { didSet { pushForceBeat() } }
    private var beatTick = 0

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var controlChar: CBCharacteristic?
    private var measuring = false
    private var t0us: UInt32?
    private var samples: [(t: Double, kg: Double)] = []
    private var repClaims = HandsFreeForceRepClaims()
    private var guidedClaims = GuidedForceSaveClaims()
    private var saveOperationsInFlight = 0
    private var finishAfterSaves = false
    private var savedMsgGeneration = 0
    private var armTimeoutTimer: Timer?
    /// Sample-clock idle budget for the armed stream (#681 review F1). The
    /// wall-clock `armTimeoutTimer` and this budget are both re-based at
    /// every armed-epoch boundary (arm, rep start, save-window entry, re-arm,
    /// transport loss) so recording time and the async save window never
    /// count as idle. Mirrored in Core (`ArmedStreamIdleBudget`) so the
    /// 32-bit µs wrap and the 10-minute threshold live in one testable place.
    private var armedStreamIdleBudget = ArmedStreamIdleBudget()
    private let armTimeoutSeconds: TimeInterval
    private let recordingQueue: any TindeqRecordingQueueing
    private let sessionQueue: any TindeqSessionQueueing
    /// Read synchronously before any queue actor hop. The default reads the
    /// relayed identity cache; tests inject a changing owner to pin the
    /// account-switch boundary.
    private let userIdProvider: @Sendable () -> UUID?
    private var persistenceOwnerUserId: UUID?
    private var persistenceOwnerAssigned = false
    /// Stable account identity for the manual/hands-free paths (issue #529
    /// slice 2) — the counterpart to `persistenceOwnerUserId` for callers
    /// that have no external owner assignment of their own.
    /// `GuidedForceRunner` explicitly assigns `persistenceOwnerUserId` before
    /// it drives the manager; a manual Free-hold `start()` or hands-free
    /// `armHandsFree()` has no such caller, so the manager captures its own
    /// owner right there, before the synchronous claim
    /// (`repClaims.begin`/`beginArmedRecording`) — never at Stop/persist
    /// time, which is exactly the save-time read that let a mid-run account
    /// switch misattribute a rep (the bug this field exists to close).
    ///
    /// Captured once, when `sessionId` is nil (no gauge session open yet),
    /// and held fixed for that session's whole lifetime: a session started
    /// under A stays A's even across a later signed-out/B transition, never
    /// silently rebound — same policy as `WorkoutManager.ownerUserId`. Once
    /// `ensureSession()` mints a `sessionId`, the gate in
    /// `captureManualSessionOwnerIfNeeded()` stops recapturing, so every
    /// later rep and the eventual session-completion row
    /// (`logSessionAfterPendingSaves`) inherit the SAME owner regardless of
    /// who is signed in when they individually start or save.
    ///
    /// `clearSession()` nils this alongside `sessionId` (#529 slice-2 review
    /// F1) — every reader resolves the owner BEFORE calling `clearSession()`,
    /// so this can never observe a mid-read reset, but a stale non-nil value
    /// surviving a CLOSED session used to leak into whatever opened next,
    /// including under a completely different account. `handleAccountTransition(to:)`
    /// is the other half (#529 slice-2 review F2): closing/logging an OPEN
    /// session on an account change so a new account's later activity opens
    /// a genuinely fresh one instead of silently continuing to accumulate
    /// into the old owner's container.
    private var manualSessionOwnerUserId: UUID?
    /// #530 round-2 review R2-F2: fallback identity for a beat that has no
    /// active session/guided-run owner yet — the connect-before-first-rep and
    /// between-session windows (the Progressor stays connected across
    /// Finish/`clearSession()`, and an account switch can land with no
    /// session open at all) that round-1's F2 fix left genuinely unstamped.
    /// An unstamped beat is indistinguishable on the wire from a pre-#530
    /// watch, so those windows were silently trusted by the phone's lenient
    /// legacy branch even for a CURRENT, signed-in watch. Captured at the
    /// SAME kind of deterministic boundary as every other owner field here —
    /// `connect()`, `handleAccountTransition(to:)`, and `clearSession()` —
    /// never read live at `pushForceBeat()` time.
    private var forceMirrorConnectOwnerUserId: UUID?
    /// #530: the live-mirror beat's account stamp. Prefers the CURRENT
    /// session/guided-run owner — re-derived from the SAME two
    /// already-boundary-captured fields above at every beat, never a
    /// separate field pinned once at `connect()` (round-1 review F2: a BLE
    /// connect deliberately outlives multiple, differently-owned gauge
    /// sessions, so pinning the stamp once at connect time could keep
    /// asserting an owner a later session doesn't have) — falling back to
    /// `forceMirrorConnectOwnerUserId` when no session/guided run has
    /// claimed the connect yet (round-2 review R2-F2). Neither branch is a
    /// live re-read of `userIdProvider()` at heartbeat time:
    /// `persistenceOwnerUserId`/`manualSessionOwnerUserId` are themselves
    /// only ever written at their own deterministic ownership boundaries
    /// (`setPersistenceOwner`, `captureManualSessionOwnerIfNeeded`) — the
    /// exact same two fields `enqueuedUserId` is computed from in
    /// `persistPreparedRecording`/`logSessionAfterPendingSaves`, so the
    /// primary branch structurally cannot drift from the save-attribution
    /// owner — and the fallback is captured at its own boundaries above. A
    /// signed-in #530 watch therefore never emits an unstamped packet once
    /// it has connected at least once: "absent" on the wire means exactly
    /// one thing, a pre-#530 build.
    var currentForceMirrorOwnerUserId: UUID? {
        (persistenceOwnerAssigned ? persistenceOwnerUserId : manualSessionOwnerUserId)
            ?? forceMirrorConnectOwnerUserId
    }
    /// The target account of an account transition that `handleAccountTransition(to:)`
    /// could not act on immediately because a rep was actively `measuring`
    /// (#529 slice-2 review round 2, R2-F1). Dropping the transition there
    /// silently reopened the exact misattribution this feature exists to
    /// close: once the straddling rep ends, the session stays open under
    /// the OLD owner with nothing left to notice the account has moved on —
    /// on the hands-free path, `rearmHandsFreeAfterSave` re-arms
    /// automatically, so every later pull would keep landing in the old
    /// owner's session with NO further user action. `nil`/`false` means "no
    /// transition pending"; a genuinely pending signed-out target is still
    /// representable (`hasPendingAccountTransition == true`,
    /// `pendingAccountTransitionUserId == nil`), which is why a bare
    /// Optional can't double as its own "is anything pending" flag.
    private var pendingAccountTransitionUserId: UUID?
    private var hasPendingAccountTransition = false
    /// Test seam: production writes through CoreBluetooth; watch target tests
    /// inject this observer so the real command ordering is inspectable.
    private let commandWriter: ((Tindeq.Cmd) -> Void)?
#if DEBUG && targetEnvironment(simulator)
    /// The simulator-only transport still enters through `handleNotification`
    /// and `handleTransportDisconnect`; it never owns a recording or queue.
    private let fakeTransport: FakeTindeqTransport?
#endif
    private var fakeTransportConnected: Bool
    // Live-force beat backfill watermark (issue #148): the last `t` a beat
    // successfully sent, so the next beat only ships what's new instead of a
    // fixed trailing window that leaves a permanent gap when WC reachability
    // flaps for longer than that window. See `ForceBeatWindow`.
    private var lastBeatT: Double?
    private var needsBackfill = true
    /// #521: one run identity per Progressor transport connection. Sequence
    /// allocation is synchronous on this manager before the WC send queue.
    private var forceMirrorSequence = LiveMirrorSequence(runId: UUID())
    private var forceMirrorStatus: String?
    private var forceMirrorCount = 0
    private var forceMirrorTag = ""
    private var forceMirrorSide = ""
    private let beatQueue = DispatchQueue(label: "com.jirathip.sendlog.forcebeat")
    /// Telemetry can arrive faster than WatchConnectivity can deliver. The
    /// queue keeps only the newest telemetry snapshot; discrete start,
    /// phase/count, and end snapshots bypass this coalescing lane.
    private var pendingTelemetry: [String: Any]?
    private var telemetryFlushScheduled = false
    private var uiTimer: Timer?
    // Distinguishes an app-initiated disconnect from a real BLE drop, so only
    // the latter triggers the finish-on-disconnect prompt.
    private var intentionalDisconnect = false
    // Account transitions are a hard no-save boundary. Keep this latched
    // until the next explicit connect so a late CoreBluetooth callback cannot
    // turn the old account's cleared trace into a salvage row.
    private var discardWithoutSavingActive = false
    // Save tasks outlive the transport, so account transitions advance this
    // token. Completions from the old run must not restore counts/depletion or
    // trigger a deferred session log under the next account.
    private var persistenceGeneration = 0

    init(
        recordingQueue: any TindeqRecordingQueueing = PendingRecordingQueue.shared,
        sessionQueue: any TindeqSessionQueueing = PendingSessionQueue.shared,
        armTimeoutSeconds: TimeInterval = 10 * 60,
        // Kept as AnyObject so the simulator-only fake type never appears in
        // a release/device signature. The value is cast only in the gated
        // implementation below; existing commandWriter tests remain intact.
        fakeTransport: AnyObject? = nil,
        commandWriter: ((Tindeq.Cmd) -> Void)? = nil,
        userIdProvider: @escaping @Sendable () -> UUID? = { WatchSessionStore.shared.userId }
    ) {
        self.recordingQueue = recordingQueue
        self.sessionQueue = sessionQueue
        self.armTimeoutSeconds = armTimeoutSeconds
#if DEBUG && targetEnvironment(simulator)
        self.fakeTransport = (fakeTransport as? FakeTindeqTransport)
            ?? (commandWriter == nil
                ? FakeTindeqLaunchConfiguration.script().map(FakeTindeqTransport.init(script:))
                : nil)
#endif
        self.commandWriter = commandWriter
        self.userIdProvider = userIdProvider
        self.fakeTransportConnected = commandWriter != nil
        super.init()
#if DEBUG && targetEnvironment(simulator)
        self.fakeTransport?.onConnect = { [weak self] in
            guard let self else { return }
            self.fakeTransportConnected = true
            self.status = .connected
            self.lowBattery = false
            self.write(.sampleBattery)
            self.pushForceBeat()
        }
        self.fakeTransport?.onNotification = { [weak self] data in
            self?.handleNotification(data)
        }
        self.fakeTransport?.onDisconnect = { [weak self] error in
            self?.handleTransportDisconnect(error: error, wasIntentionalOverride: false)
        }
#endif
        // A command writer is a complete fake transport for unit tests.
        if commandWriter != nil { status = .connected }
    }

    private var transportConnected: Bool {
        peripheral != nil || fakeTransportConnected
    }

    // MARK: Session

    /// Return the active session's group id, minting it (and its start time) on
    /// the first call. Called synchronously at save time so this rep and later
    /// reps of the same connect land in one group.
    func ensureSession() -> UUID {
        if let id = sessionId { return id }
        let id = UUID()
        sessionId = id
        sessionStartedAt = Date()
        return id
    }

    func clearSession() {
        sessionId = nil
        sessionStartedAt = nil
        sessionCount = 0
        depletion.reset()
        guidedClaims.reset()
        // #529 slice-2 review F1: every reader of `manualSessionOwnerUserId`
        // (`clearPersistenceOwner()`'s carry-over, `logSessionAfterPendingSaves`)
        // resolves it BEFORE this function runs (both call sites read, then
        // call `clearSession()`), so nil-ing it here is safe and closes a
        // real cross-account leak: without this, a stale owner from a
        // CLOSED session survived into whatever session opens next — even
        // under a completely different account via a later guided run — and
        // both readers had no way to tell "captured for THIS session" from
        // "left over from the last one".
        manualSessionOwnerUserId = nil
        // #530 round-2 review R2-F2: refresh the between-session fallback
        // right as the primary owner clears, so the very next beat — before
        // any new session claims an owner of its own — still stamps whoever
        // the watch is CURRENTLY relayed as, not nothing. A one-time read at
        // this deterministic session-boundary, not a live re-read at beat
        // time.
        forceMirrorConnectOwnerUserId = userIdProvider()
    }

    /// Captures `manualSessionOwnerUserId` for a NEW gauge session (#529
    /// slice 2) — a no-op once one is already open (`sessionId != nil`), so
    /// this only ever fixes the owner once per session, at the first
    /// ACCEPTED manual `start()`/`armHandsFree()`, never re-deriving it for
    /// later reps of the same session. Both call sites invoke this only
    /// after their claim is accepted (#529 slice-2 review F6 — `start()`
    /// calls it once `repClaims.begin` succeeds; `armHandsFree()` has no
    /// further gate past its own guard) and before any `await`, so no
    /// suspension can run between "who is signed in" and "who owns this
    /// measurement", and a rejected call never mutates ownership state.
    private func captureManualSessionOwnerIfNeeded() {
        guard sessionId == nil else { return }
        manualSessionOwnerUserId = userIdProvider()
    }

    /// Fold one just-saved rep into the session's W' depletion (#280). Called
    /// from every path that persists a rep — the Stop & Save button and the
    /// disconnect salvage — so the prediction covers the whole session.
    func recordRepDepletion(peakKg: Double, durationMs: Int, tag: String) {
        let curve = tagCurves[tag]
        depletion.add(
            DepletionRep(
                peakKg: peakKg,
                durationS: Double(durationMs) / 1000,
                cf: curve?.cf,
                wPrime: curve?.wPrime
            )
        )
    }

    /// The RPE this session would be logged at right now.
    var predictedRPE: PredictedRPE { depletion.predicted }

    /// End the gauge session and log it immediately at the predicted RPE
    /// (#280) — there is no prompt any more. Every caller (the Finish button,
    /// the explicit disconnect, and an unplanned BLE drop) goes through here,
    /// so a session can't be orphaned by the user simply walking away.
    ///
    /// The payload is built synchronously, at call time: date and duration
    /// must reflect this exact moment, not whenever the queued upload
    /// eventually lands (issue #144 — the old sheet's `try? await` froze
    /// mid-flight the instant the user lowered their wrist, so the session
    /// could arrive minutes to hours late, if at all). Persist-first +
    /// idempotent upsert (`PendingSessionQueue`/`Repo`) is unchanged: this
    /// returns immediately when persistence succeeds. If persistence and the
    /// direct-upload fallback both fail, the manager records a one-shot Home
    /// notice because this path may run after the Force UI has disappeared.
    func logSessionNow() {
        cancelHandsFree()
        if saveOperationsInFlight > 0 {
            finishAfterSaves = true
            return
        }
        logSessionAfterPendingSaves()
    }

    private func logSessionAfterPendingSaves() {
        finishAfterSaves = false
        guard let groupId = sessionId, sessionCount > 0 else {
            clearSession()
            return
        }
        // Capture A before the actor hop and before `clearSession()` (which
        // nils `manualSessionOwnerUserId`) — passed straight into `build(...)`
        // rather than assigned afterward (#529 slice-2 review F4:
        // `PendingTindeqSession`'s memberwise init and `build(...)` both
        // require this explicitly now, so a future call site cannot forget
        // the post-hoc stamp and fall through to `UploadQueueEngine.enqueue`'s
        // legacy nil→current-user fallback). A guided run's explicit
        // assignment wins while it's still active (`logSessionNow` runs
        // before `clearPersistenceOwner` on the guided completion path);
        // otherwise this session's immutable manual owner, captured once at
        // its first rep's start — never a live read, which is exactly the
        // save-time misattribution this closes. `userIdProvider()` only
        // backstops the case neither owner was ever captured (unreachable
        // via the UI today, same as `WorkoutManager.endAndSave()`'s
        // equivalent fallback).
        let enqueuedUserId = persistenceOwnerAssigned
            ? persistenceOwnerUserId
            : (manualSessionOwnerUserId ?? userIdProvider())
        let pending = PendingTindeqSession.build(
            sessionStartedAt: sessionStartedAt,
            recordingCount: sessionCount,
            rpe: predictedRPE.rpe,
            groupId: groupId,
            enqueuedUserId: enqueuedUserId
        )
        clearSession()
        let generation = persistenceGeneration
        Task { @MainActor in
            guard generation == persistenceGeneration else { return }
            let outcome = await sessionQueue.enqueue(pending)
            guard generation == persistenceGeneration else { return }
            guard outcome == .lost else { return }
            self.errorMsg = "Force session couldn't be saved"
            GaugeSessionLossNotice.record()
        }
    }

    // MARK: Controls

    func connect() {
        discardWithoutSavingActive = false
        intentionalDisconnect = false
        errorMsg = nil
        resetForceMirrorPipeline()
        forceMirrorSequence = LiveMirrorSequence(runId: UUID())
        // #530 round-2 review R2-F2: the mirror's fallback identity for
        // this connect, before any session/guided run claims its own — see
        // `forceMirrorConnectOwnerUserId`'s doc comment.
        forceMirrorConnectOwnerUserId = userIdProvider()
        forceMirrorStatus = nil
        forceMirrorCount = sessionCount
        forceMirrorTag = liveTag
        forceMirrorSide = liveSide
        status = .scanning
#if DEBUG && targetEnvironment(simulator)
        if let fakeTransport {
            fakeTransport.connect()
            return
        }
#endif
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            startScanIfPoweredOn()
        }
    }

    func disconnect() {
        cancelHandsFree()
        stopUITimer()
        measuring = false
        repClaims.discard()
        guidedClaims.discardActive()
        if let p = peripheral {
            // Flag only when a delegate callback will follow, so it can't go
            // stale and mask a later real drop.
            intentionalDisconnect = true
            central?.cancelPeripheralConnection(p)
        }
#if DEBUG && targetEnvironment(simulator)
        fakeTransport?.disconnect()
#endif
        peripheral = nil
        fakeTransportConnected = false
        controlChar = nil
        status = .idle
        pushForceBeat()
    }

    /// Binds guided persistence to the account that owned the run snapshot.
    /// Direct/manual manager callers leave this unset and use the current
    /// relayed identity at their synchronous save boundary instead.
    func setPersistenceOwner(_ userId: UUID?) {
        persistenceOwnerUserId = userId
        persistenceOwnerAssigned = true
    }

    func clearPersistenceOwner() {
        // #529 slice 2: the shared gauge session's `sessionId` is minted
        // once per CONNECT, not once per guided run — if it survives past
        // this guided run's end (a manual rep continues in the same
        // connect), later manual saves must inherit the SAME owner the
        // guided run itself used, not silently fall back to whoever is
        // signed in when the next manual `start()` happens. Only when no
        // manual owner has been captured yet for this session — a manual
        // rep that already opened the session under its OWN owner (guided
        // started later, using the assigned field) must keep that value.
        if sessionId != nil, manualSessionOwnerUserId == nil {
            manualSessionOwnerUserId = persistenceOwnerUserId
        }
        persistenceOwnerUserId = nil
        persistenceOwnerAssigned = false
    }

    /// Reacts to a signed-in account change for the manual/hands-free paths
    /// (#529 slice 2 review F2). A gauge session has no natural end of its
    /// own — it spans the whole Progressor CONNECT, not one run — so nothing
    /// closed an OPEN session when the signed-in account changed, and its
    /// already-open container kept silently accepting whoever was next to
    /// pull a rep or tap Finish. Only acts when no guided run has claimed
    /// persistence (`persistenceOwnerAssigned`/`guidedClaims.active`):
    /// `GuidedForceRunner`'s own `authStateDidChange` already owns that
    /// decision via `discardWithoutSaving()`, and running both policies over
    /// the same state at once would race.
    ///
    /// Policy mirrors slice 1: the already-open session's captured owner is
    /// held — logged/queued under them, never rebound (`logSessionNow()`
    /// already routes through `shouldDrain`'s account guard at drain time) —
    /// while the container itself closes, so a genuinely NEW account's next
    /// `start()`/`armHandsFree()` opens a fresh session under them instead
    /// of silently continuing to accumulate into the old owner's.
    ///
    /// Records rather than acts while a rep is actively `measuring`: that
    /// rep's Start already happened under the captured owner, and closing
    /// the session out from under it would clear `manualSessionOwnerUserId`
    /// before its own (still in-flight) Stop/save reads it — reopening the
    /// exact save-time-read bug this field exists to close, just for the
    /// one rep straddling the transition. `resolvePendingAccountTransitionIfNeeded()`
    /// (#529 slice-2 review round 2 R2-F1) is what actually completes a
    /// deferred transition, called from every point a rep ends — dropping it
    /// here instead (the round-1 shape) left it silently lost: on the
    /// hands-free path `rearmHandsFreeAfterSave` re-arms automatically, so
    /// every later pull kept landing in the OLD owner's session with no
    /// further user action at all. An armed-but-idle hands-free wait has
    /// made no such commitment yet (no claim, no samples) — closing through
    /// it is safe, and just means the new account has to re-arm.
    func handleAccountTransition(to userId: UUID?) {
        // #530 round-2 review R2-F2: unconditional and first — the watch's
        // relayed identity has genuinely changed regardless of whether the
        // session-management guards below act on it, and the live-mirror
        // fallback must track that immediately so a beat sent between here
        // and whenever (or whether) a new session opens stamps the NEW
        // account, not the old one and not nothing.
        forceMirrorConnectOwnerUserId = userId
        guard !persistenceOwnerAssigned, guidedClaims.active == nil else { return }
        guard let sessionOwner = manualSessionOwnerUserId, userId != sessionOwner else { return }
        guard !measuring else {
            pendingAccountTransitionUserId = userId
            hasPendingAccountTransition = true
            return
        }
        logSessionNow()
    }

    /// Completes a transition `handleAccountTransition(to:)` had to defer
    /// while a rep was `measuring` (#529 slice-2 review round 2 R2-F1).
    /// Called from every point a rep can end — the durable-save completion
    /// (manual Stop, hands-free auto-rearm, and salvage, which all funnel
    /// through `persistPreparedRecording`), a Stop that produced no
    /// summary to persist, the 10-minute manual cap's no-save branch, and
    /// the end of `handleTransportDisconnect` — so there is no rep-ending
    /// path this can silently miss. Re-runs `handleAccountTransition`'s own
    /// policy (never a different one): a safe no-op if the session already
    /// closed some other way in the meantime, or a genuine close/log-held
    /// if it's still open under the stale owner.
    private func resolvePendingAccountTransitionIfNeeded() {
        guard hasPendingAccountTransition, !measuring, saveOperationsInFlight == 0 else { return }
        let target = pendingAccountTransitionUserId
        hasPendingAccountTransition = false
        pendingAccountTransitionUserId = nil
        handleAccountTransition(to: target)
    }

    /// Synchronously tears down an account's transport and claims without
    /// entering any salvage or persistence path. Account changes use this
    /// instead of `disconnect()`: the latter is an ordinary transport
    /// boundary whose delegate callback may salvage an interrupted trace.
    ///
    /// This is intentionally idempotent. In-flight queue completions are
    /// invalidated so they cannot resurrect manager state or finish a session
    /// after the run has been handed to another account.
    func discardWithoutSaving() {
        discardWithoutSavingActive = true
        intentionalDisconnect = true
        persistenceGeneration &+= 1

        let wasMeasuring = measuring
        cancelHandsFree()
        stopUITimer()
        if wasMeasuring { write(.stop) }
        measuring = false
        central?.stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
#if DEBUG && targetEnvironment(simulator)
        fakeTransport?.disconnect()
#endif
        peripheral = nil
        fakeTransportConnected = false
        controlChar = nil
        status = .idle

        resetRecordingBuffer()
        repClaims.discard()
        guidedClaims.discardActive()
        clearSession()
        saveOperationsInFlight = 0
        finishAfterSaves = false
        saving = false
        savedMsg = nil
        savedMsgGeneration &+= 1
        errorMsg = nil
        persistenceOwnerUserId = nil
        persistenceOwnerAssigned = false
        // manualSessionOwnerUserId is reset by clearSession() above.
        pendingAccountTransitionUserId = nil
        hasPendingAccountTransition = false
        pushForceBeat()
    }

    func tare() {
        write(.tare)
    }

    func start() {
        guard status == .connected, !handsFreeRequested, !saving, guidedClaims.active == nil else { return }
        savedMsgGeneration += 1
        savedMsg = nil
        resetRecordingBuffer()
        // #529 slice-2 review F6: capture only once the claim is actually
        // ACCEPTED, not on the guard above (a concurrent/racing rejection
        // here must not mutate ownership state) — matches
        // `WorkoutManager.start()`, which captures `ownerUserId` only past
        // its own acceptance guard.
        guard repClaims.begin(tag: trimmedLiveTag, side: liveSide) != nil else { return }
        captureManualSessionOwnerIfNeeded()
        write(.startWeight)
        measuring = true
        status = .measuring
        startUITimer()
        pushForceBeat()
    }

    /// Starts the Progressor's weight stream while leaving `measuring` false.
    /// `handleNotification` feeds these samples to the Core state machine but
    /// does not append them to `samples`; the claimed Start transition resets
    /// the buffer/t0 and only then promotes the stream to a recording.
    func armHandsFree() {
        // SL-585: no empty-tag refusal any more — an empty `liveTag` IS the
        // free-hold representation (the DB's own column default is `''` and
        // the manual `start()` path never required a tag). With no exercise
        // selected, the Force page's primary card arms an untagged free
        // hold; picking an exercise later tags subsequent reps as always.
        guard status == .connected, !handsFreeRequested, !saving,
              guidedClaims.active == nil else { return }
        captureManualSessionOwnerIfNeeded()
        savedMsgGeneration += 1
        savedMsg = nil
        handsFreeRequested = true
        handsFreeState = armedHandsFreeForce() // synchronous control claim
        armedStreamIdleBudget = ArmedStreamIdleBudget()
        repClaims.discard()
        resetRecordingBuffer()
        write(.startWeight)
        scheduleArmTimeout()
        pushForceBeat() // armed intentionally mirrors as "connected"
    }

    /// Cancels an armed wait or prevents a post-save re-arm. It never discards
    /// an active recording; the measuring screen owns Stop & Save.
    func cancelHandsFree() {
        let wasArmedStream: Bool
        switch handsFreeState {
        case .armed, .waitingForSlack, .recording: wasArmedStream = !measuring
        case .idle, .stopping: wasArmedStream = false
        }
        handsFreeRequested = false
        handsFreeState = idleHandsFreeForce()
        armedStreamIdleBudget = ArmedStreamIdleBudget()
        armTimeoutTimer?.invalidate()
        armTimeoutTimer = nil
        if wasArmedStream {
            write(.stop)
            resetRecordingBuffer()
            pushForceBeat()
        }
    }

    /// Stop and persistence share one synchronous claim. Automatic release,
    /// the Stop & Save button and the 10-minute cap all enter here; only the
    /// first can take `repClaims.active`, and that happens before the
    /// Task/await below. `reason` has no default on purpose (#503): only
    /// `.released` carries a trim timestamp and re-arms without fresh slack,
    /// and every call site must say which stop it is — a new caller cannot
    /// get release semantics by accident.
    func stopAndSave(reason: HandsFreeStopReason) {
        guard let claim = repClaims.claimStop() else { return }
        // #681: an auto-release (.released) has already proved stopGraceMs of
        // slack, so it can stop the transport stream outright and re-arm
        // straight to armed. A tap ("Stop & Save"), the 10-minute cap, or a
        // `.staticLoad` termination (#682) re-arms through `waitingForSlack`,
        // which must OBSERVE a sample at/below stopKg before the next pull can
        // be recognized. If the user's release-to-slack edge falls inside the
        // async save's dark window (transport stopped, samples dropped), that
        // sample never arrives: the re-arm sees only a resumed loaded stream
        // and the second pull never arms — the #607 report. Keep the weight
        // stream LIVE through tap/cap/static-load saves so the machine
        // observes the release while saving, and let the re-arm preserve
        // whatever it observed.
        // #681 review F3: the keep-live decision is Core's
        // (`reason.keepsStreamLive`) — not a fourth local switch — and the
        // live-window state is Core's own re-arm decision
        // (`rearmedHandsFreeForce(afterStop:)`); only the stopped-stream case
        // stamps `.stopping`.
        let keepStreamRunning = handsFreeRequested
            && reason.keepsStreamLive
            && transportConnected
        if handsFreeRequested {
            handsFreeState = keepStreamRunning
                ? rearmedHandsFreeForce(afterStop: reason)
                : .stopping
            // #681 review F1: the save window is a new armed epoch. Re-base
            // the sample-clock idle budget so the first post-stop sample
            // starts a fresh 10-minute clock instead of inheriting the stale
            // pre-rep base — with the whole rep's recording time counted as
            // idle, a 10-minute cap rep would spuriously cancel inside its own
            // save window (the "hands-free disarmed" dead gauge under #683).
            if keepStreamRunning { armedStreamIdleBudget = ArmedStreamIdleBudget() }
        }
        let summary = stopTransport(
            endMs: reason.trimEndMs,
            keepStreamRunning: keepStreamRunning
        )
        guard let summary else {
            // #529 slice-2 review round 2 R2-F1: nothing was captured to
            // persist, so no `persistPreparedRecording` completion will ever
            // run for this rep — this IS the rep-ending point. Resolve
            // before the re-arm check below for the same reason as the
            // completion handler: a closed session cancels hands-free too.
            resolvePendingAccountTransitionIfNeeded()
            if handsFreeRequested, transportConnected {
                rearmHandsFreeAfterSave(afterStop: reason, keepStreamRunning: keepStreamRunning)
            }
            return
        }
        // Guard 1 (#682): evaluate the persisted form AFTER any trim (a
        // `.staticLoad` termination trims to the flat-window start; release
        // trims to the release edge). A trivial rep (peak below `minPeakKg` or
        // duration below `minDurationMs`) is discarded silently, never enters
        // the recording queue, and is never reported as queued. Only gates
        // hands-free reps — manual recordings are unchanged while hands-free is
        // opt-in.
        if handsFreeRequested,
           recordingVerdict(peakKg: summary.peakKg, durationMs: Double(summary.durationMs)) != .persist {
            resolvePendingAccountTransitionIfNeeded()
            if handsFreeRequested, transportConnected {
                rearmHandsFreeAfterSave(afterStop: reason, keepStreamRunning: keepStreamRunning)
            }
            return
        }
        persistRecording(
            summary,
            claim: claim,
            note: "",
            keepStreamRunning: keepStreamRunning,
            rearmHandsFreeAfterStop: handsFreeRequested ? reason : nil
        )
    }

    // MARK: Guided protocol persistence

    /// Begin one measured resisted-movement set as one continuous BLE trace.
    /// Run/set identity and all mutable picker/protocol context are claimed
    /// synchronously before the transport is started.
    @discardableResult
    func startMeasuredMovementSet(
        protocolValue: WatchForceProtocol,
        runId: UUID,
        set: Int,
        tag: String,
        side: String,
        zone: String? = nil,
        targetBand: MovementTargetBand? = nil
    ) -> Bool {
        guard let context = GuidedForceRecordingContext.movementSet(
            protocolValue: protocolValue,
            runId: runId,
            set: set,
            tag: tag.trimmingCharacters(in: .whitespaces),
            side: side,
            zone: zone,
            targetBand: targetBand
        ) else { return false }
        return beginGuidedMeasured(context)
    }

    /// Begin one measured static hold. Each rep is independently identified
    /// and saved, matching the existing web protocol row shape.
    @discardableResult
    func startMeasuredStaticHold(
        protocolValue: WatchForceProtocol,
        runId: UUID,
        set: Int,
        rep: Int,
        tag: String,
        side: String,
        zone: String? = nil,
        targetBand: MovementTargetBand? = nil
    ) -> Bool {
        guard let context = GuidedForceRecordingContext.staticHold(
            protocolValue: protocolValue,
            runId: runId,
            set: set,
            rep: rep,
            tag: tag.trimmingCharacters(in: .whitespaces),
            side: side,
            zone: zone,
            targetBand: targetBand
        ) else { return false }
        return beginGuidedMeasured(context)
    }

    private func beginGuidedMeasured(_ context: GuidedForceRecordingContext) -> Bool {
        // `saving` is immutable-row durability, not transport readiness. A
        // delayed guided tick can finish set N and start set N+1 in one
        // synchronous event list (especially with zero rest). The first row
        // is already claimed and has its own durable id/group; blocking the
        // next BLE start here would leave Core's next boundary unsaved.
        guard status == .connected, !handsFreeRequested,
              repClaims.active == nil, !context.tag.isEmpty,
              guidedClaims.begin(context: context) != nil
        else { return false }
        savedMsgGeneration += 1
        savedMsg = nil
        resetRecordingBuffer()
        write(.startWeight)
        measuring = true
        status = .measuring
        startUITimer()
        pushForceBeat()
        return true
    }

    @discardableResult
    func finishMeasuredMovementSet() -> Bool {
        finishGuidedMeasured(expected: .movementSet, outcome: nil, note: "")
    }

    @discardableResult
    func finishMeasuredStaticHold(outcome: String? = nil) -> Bool {
        finishGuidedMeasured(expected: .staticHold, outcome: outcome, note: "")
    }

    private func finishGuidedMeasured(
        expected: GuidedForceRecordingKind,
        outcome: String?,
        note: String
    ) -> Bool {
        guard guidedClaims.active?.context.kind == expected,
              let claim = guidedClaims.claimFinish()
        else { return false }
        let plannedEndMs = Double(claim.context.plannedDurationMs)
        guard let summary = stopTransport(endMs: plannedEndMs),
              let completion = guidedForceCompletion(
                  context: claim.context,
                  actualDurationMs: summary.durationMs
              )
        else { return false }
        persistGuidedMeasured(
            summary,
            claim: claim,
            completion: completion,
            outcome: outcome,
            note: note,
            rememberSelection: true
        )
        return true
    }

    /// Save one sensorless movement set. The stable row claim is consumed
    /// synchronously; persistence then uses the same durable queue as measured
    /// work but never manufactures samples, force values, or metrics.
    @discardableResult
    func saveCadenceOnlyMovementSet(
        protocolValue: WatchForceProtocol,
        runId: UUID,
        set: Int,
        tag: String,
        side: String,
        zone: String? = nil,
        actualDurationMs: Int
    ) -> Bool {
        guard let context = GuidedForceRecordingContext.movementSet(
            protocolValue: protocolValue,
            runId: runId,
            set: set,
            tag: tag.trimmingCharacters(in: .whitespaces),
            side: side,
            zone: zone,
            targetBand: nil
        ), !context.tag.isEmpty,
           let completion = guidedForceCompletion(
               context: context, actualDurationMs: actualDurationMs
           ),
           let claim = guidedClaims.claimCadenceOnly(context: context)
        else { return false }
        let groupId = ensureSession()
        let row = Repo.makeCadenceOnlyMovementRow(
            claim: claim, completion: completion, groupId: groupId
        )
        persistPreparedRecording(
            row,
            displayPeakKg: nil,
            depletion: nil,
            lostSavedMessage: "Movement set was not saved",
            lostErrorMessage: "Set not saved — couldn't write to the watch.",
            rememberSelection: true,
            keepStreamRunning: false,
            rearmHandsFreeAfterStop: nil
        )
        return true
    }

    /// Finish the gauge session after every guided row has reached a durable
    /// queued/direct-upload outcome. `logSessionNow` already owns the in-flight
    /// gate, so this is intentionally a named API rather than a second path.
    func finishGuidedRun() {
        logSessionNow()
    }

    private func stopTransport(endMs: Double? = nil, keepStreamRunning: Bool = false) -> StoppedRecording? {
        measuring = false
        stopUITimer()
        if !keepStreamRunning { write(.stop) }
        status = transportConnected ? .connected : .idle
        guard let summary = makeSummary(endMs: endMs) else { return nil }
        currentKg = 0
        peakKg = summary.peakKg
        elapsedMs = Double(summary.durationMs)
        pushForceBeat()
        return summary
    }

    /// Rounding/derivation shared by `stopTransport()` and the disconnect-salvage path
    /// (issue #151) so a recovered rep looks identical to a manually-stopped
    /// one: t rounded to ms int, kg to 2 dp, duration/peak/avg from the same
    /// samples.
    private func makeSummary(endMs: Double? = nil) -> StoppedRecording? {
        let included = endMs.map { end in samples.filter { $0.t <= end } } ?? samples
        guard !included.isEmpty else { return nil }
        let rounded = included.map { (t: ($0.t).rounded(), kg: ($0.kg * 100).rounded() / 100) }
        let kgs = rounded.map(\.kg)
        return StoppedRecording(
            durationMs: Int(rounded.last!.t),
            peakKg: kgs.max() ?? 0,
            avgKg: ((kgs.reduce(0, +) / Double(kgs.count)) * 100).rounded() / 100,
            samples: rounded
        )
    }

    /// Last ~10 s of samples for the sparkline (called from the UI timer cadence).
    func recentSamples(windowMs: Double = 10_000) -> [(t: Double, kg: Double)] {
        guard let last = samples.last else { return [] }
        let cutoff = last.t - windowMs
        return samples.filter { $0.t >= cutoff }
    }

    // MARK: Internals

    private func write(_ cmd: Tindeq.Cmd) {
        commandWriter?(cmd)
#if DEBUG && targetEnvironment(simulator)
        fakeTransport?.write(cmd)
#endif
        guard let p = peripheral, let c = controlChar else { return }
        p.writeValue(Data([cmd.rawValue]), for: c, type: .withResponse)
    }

    private func startScanIfPoweredOn() {
        guard let central, central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: [Tindeq.service])
        // Progressor advertises its service; stop scanning after 15 s if nothing found
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.status == .scanning else { return }
            central.stopScan()
            self.status = .idle
            self.errorMsg = "No Progressor found. Is it on?"
        }
    }

    private func startUITimer() {
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let last = self.samples.last else { return }
            self.currentKg = last.kg
            self.elapsedMs = last.t
            if last.kg > self.peakKg { self.peakKg = last.kg }
            // Mirror beat every 5th tick (~2 Hz) while measuring (SL-87).
            self.beatTick += 1
            if self.beatTick % 5 == 0 { self.pushForceBeat() }
            if TindeqRecordingLimit.shouldStop(elapsedMs: last.t), self.measuring {
                if let guidedKind = self.guidedClaims.active?.context.kind {
                    switch guidedKind {
                    case .movementSet: _ = self.finishMeasuredMovementSet()
                    case .staticHold: _ = self.finishMeasuredStaticHold()
                    }
                } else if self.handsFreeRequested {
                    self.stopAndSave(reason: .cappedAt30Min)
                } else {
                    // Preserve the pre-existing manual cap behavior: it stops
                    // the stream and returns to setup without inventing a
                    // save action the user did not tap.
                    self.repClaims.discard()
                    _ = self.stopTransport()
                    // #529 slice-2 review round 2 R2-F1: nothing is
                    // persisted on this branch, so this IS the rep-ending
                    // point for any deferred account transition.
                    self.resolvePendingAccountTransitionIfNeeded()
                }
            }
        }
    }

    /// SL-87/#521: fire one live-force beat over WatchConnectivity when the
    /// phone is reachable — the plugin forwards it to the WebView with no
    /// network hop. The force stream has no Supabase fallback (an 80 Hz gauge
    /// has no business heartbeating the network); `needsBackfill` causes the
    /// next successful telemetry beat to resend the capped window (#148).
    ///
    /// High-rate telemetry is coalesced on `beatQueue`, while start,
    /// phase/count, and end transitions bypass that lane. Every payload still
    /// gets its sequence before enqueueing, so a skipped telemetry packet is a
    /// valid gap rather than an ordering ambiguity.
    private func pushForceBeat() {
        let wc = WCSession.default
        guard wc.activationState == .activated else { return }
        guard wc.isReachable else {
            needsBackfill = true
            return
        }
        let statusStr: String
        switch status {
        case .measuring: statusStr = "measuring"
        case .connected: statusStr = "connected"
        default: statusStr = "idle"
        }
        let event: LiveMirrorEvent
        if statusStr == "idle" {
            event = .end
        } else if forceMirrorStatus == nil {
            event = .start
        } else if forceMirrorStatus != statusStr {
            event = .phase
        } else if forceMirrorCount != sessionCount {
            event = .count
        } else if forceMirrorTag != liveTag || forceMirrorSide != liveSide {
            // Exercise/side labels drive the whole Force card. Treat a
            // selection change as a discrete context transition so it cannot
            // sit behind a telemetry debounce window.
            event = .phase
        } else {
            event = .telemetry
        }
        forceMirrorStatus = statusStr
        forceMirrorCount = sessionCount
        forceMirrorTag = liveTag
        forceMirrorSide = liveSide
        // Sequence exhaustion is astronomically unlikely, but it must fail
        // closed rather than repeat Int.max and make the phone accept a
        // duplicate force transition.
        guard let beat = forceMirrorSequence.nextIfAvailable(event: event) else { return }

        // SL-95: only meaningful mid-hold — omitted (empty) otherwise so
        // idle/connected beats stay tiny, and the backfill watermark is left
        // untouched by them.
        var spark: [[Double]] = []
        if status == .measuring {
            spark = ForceBeatWindow.window(samples: samples, sinceT: needsBackfill ? nil : lastBeatT)
            if let lastPoint = spark.last {
                lastBeatT = lastPoint[0]
                needsBackfill = false
            }
        }
        var payload: [String: Any] = [
            "kind": "liveForce",
            "status": statusStr,
            "kg": (currentKg * 100).rounded() / 100,
            "peak_kg": (peakKg * 100).rounded() / 100,
            "elapsed_ms": elapsedMs.rounded(),
            "session_count": sessionCount,
            "tag": liveTag,
            "side": liveSide,
            "updated_at": Date().timeIntervalSince1970,
            "spark": spark,
        ]
        payload.merge(beat.wireFields) { _, new in new }
        // #530 (round-1 review F2): the CURRENT session's owner, re-derived
        // per beat from already-boundary-captured fields — see
        // `currentForceMirrorOwnerUserId`'s doc comment for why this is not
        // a live re-read of `userIdProvider()`.
        payload = LiveMirrorOwnership.stamped(payload, ownerUserId: currentForceMirrorOwnerUserId)
        let stamped = WatchBuild.stamp(payload)
        let immediate = event.isDiscrete
        let runId = beat.runId
        beatQueue.async { [weak self] in
            guard let self else { return }
            if immediate {
                // A transition supersedes any telemetry still waiting in the
                // debounce window. Its lower sequence would be rejected by
                // the phone anyway, so dropping it is safe coalescing.
                self.pendingTelemetry = nil
                wc.sendMessage(stamped, replyHandler: nil, errorHandler: { [weak self] _ in
                    DispatchQueue.main.async { self?.markForceBeatFailed(runId: runId) }
                })
                return
            }
            self.pendingTelemetry = stamped
            guard !self.telemetryFlushScheduled else { return }
            self.telemetryFlushScheduled = true
            self.beatQueue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self else { return }
                let next = self.pendingTelemetry
                self.pendingTelemetry = nil
                self.telemetryFlushScheduled = false
                guard let next else { return }
                wc.sendMessage(next, replyHandler: nil, errorHandler: { [weak self] _ in
                    DispatchQueue.main.async { self?.markForceBeatFailed(runId: runId) }
                })
            }
        }
    }

    /// A WatchConnectivity error can arrive after the gauge has been
    /// disconnected and a new run has already begun. Only the current run may
    /// change its backfill watermark; an old callback must not make a fresh
    /// stream resend stale samples.
    private func markForceBeatFailed(runId: UUID) {
        guard forceMirrorSequence.runId == runId else { return }
        needsBackfill = true
    }

    /// Clear a coalesced telemetry snapshot before a new BLE connection gets
    /// a fresh run identity. The debounce timer itself is harmless: when it
    /// fires it observes an empty pending slot, while the serial queue keeps
    /// this reset ahead of the next beat emitted by `connect()`/`start()`.
    private func resetForceMirrorPipeline() {
        beatQueue.async { [weak self] in
            self?.pendingTelemetry = nil
            self?.telemetryFlushScheduled = false
        }
    }

    private func stopUITimer() {
        uiTimer?.invalidate()
        uiTimer = nil
    }

    private var trimmedLiveTag: String {
        liveTag.trimmingCharacters(in: .whitespaces)
    }

    private var isWaitingForHandsFreePull: Bool {
        switch handsFreeState {
        case .armed, .waitingForSlack: return true
        case .idle, .recording, .stopping: return false
        }
    }

    private func resetRecordingBuffer() {
        samples.removeAll()
        t0us = nil
        lastBeatT = nil
        needsBackfill = true
        currentKg = 0
        peakKg = 0
        elapsedMs = 0
        errorMsg = nil
    }

    private func scheduleArmTimeout() {
        armTimeoutTimer?.invalidate()
        guard armTimeoutSeconds > 0 else { return }
        // Unlike the UI timer, the Progressor's ~80 Hz weight notifications
        // remain live for the whole armed wait. Bound that radio/CPU duty to
        // ten idle minutes instead of silently streaming until disconnect.
        armTimeoutTimer = Timer.scheduledTimer(withTimeInterval: armTimeoutSeconds, repeats: false) { [weak self] _ in
            guard let self, self.handsFreeRequested, self.isWaitingForHandsFreePull else { return }
            self.cancelHandsFree()
            self.savedMsg = "Hands-free disarmed after 10 min idle"
            self.scheduleSavedMsgDismiss()
        }
    }

    private func beginArmedRecording(with first: TindeqFrame.WeightSample) {
        armTimeoutTimer?.invalidate()
        armTimeoutTimer = nil
        resetRecordingBuffer()
        // #681 review F1: a rep start is a new armed epoch — recording time
        // must never count against the sample-clock idle budget.
        armedStreamIdleBudget = ArmedStreamIdleBudget()
        // SL-585: an empty tag no longer cancels the armed pull — it records
        // as an untagged free hold, exactly what the manual `start()` path
        // has always allowed (`repClaims.begin` and the recordings schema
        // both accept `""`). The old cancel-and-toast here was the
        // hands-free half of the "Pick an exercise" refusal that SL-585
        // removes.
        guard repClaims.begin(tag: trimmedLiveTag, side: liveSide) != nil else {
            cancelHandsFree()
            return
        }
        t0us = first.us
        // #682: Guard 2's flat-watch is seeded by `stepHandsFreeForce` on the
        // armed clock (`sample.us` absolute), but `handleMeasuringSamples`
        // below feeds the recording clock (`samples[].t`, t0-relative). Re-base
        // the flat-watch start to 0 (the first recording sample) so Core's
        // `atMs - flatWatch.sinceMs` subtracts matching clocks. The min/max are
        // the START sample's load — exactly `samples[0]` — so they are kept.
        if case let .recording(belowSinceMs, flatWatch) = handsFreeState {
            let rebased = flatWatch.map {
                HandsFreeForceFlatWatch(sinceMs: 0, minKg: $0.minKg, maxKg: $0.maxKg)
            }
            handsFreeState = .recording(belowSinceMs: belowSinceMs, flatWatch: rebased)
        }
        samples.append((t: 0, kg: Double(first.kg)))
        measuring = true
        status = .measuring
        startUITimer()
        pushForceBeat()
    }

    private func rearmHandsFreeAfterSave(afterStop reason: HandsFreeStopReason, keepStreamRunning: Bool) {
        // #681: if a new rep already started during this save (the live stream
        // let the machine observe release + re-pull inside the save window), it
        // owns the machine now — the re-arm must not idle or reset it.
        if case .recording = handsFreeState {
            return
        }
        guard handsFreeRequested, transportConnected, status == .connected, !finishAfterSaves else {
            handsFreeState = idleHandsFreeForce()
            return
        }
        switch reason {
        case .released:
            // The stream was stopped at save time (release already proved
            // stopGraceMs of slack), so re-arm straight to armed and restart
            // the stream (#503).
            handsFreeState = rearmedHandsFreeForce(afterStop: reason)
            armedStreamIdleBudget = ArmedStreamIdleBudget()
            resetRecordingBuffer()
            write(.startWeight)
            scheduleArmTimeout()
            pushForceBeat()
        case .userTapped, .cappedAt30Min, .staticLoad:
            // #681: whether THIS stop kept the transport stream running is a
            // value decided synchronously at stop time and carried through
            // the async save (`keepStreamRunning`, #681 review F2) — never
            // re-derived from `handsFreeState` at completion time, which a
            // second rep can advance while this save is in flight.
            if keepStreamRunning {
                // The machine already observed the post-save world —
                // waitingForSlack if the user is still hanging (phantom
                // guard), armed(aboveSinceMs: nil) once slack arrived, or
                // armed(aboveSinceMs: some) if the next pull is already in
                // its stable window. Preserve that evidence instead of
                // stamping the blind Core decision (waitingForSlack) over it:
                // that would strand the already-armed machine and swallow the
                // fast next pull — the #607 report. Only the stopped-stream
                // case (transport was unavailable at stop time) needs the
                // blind re-arm and a restart.
                // A `.stopping` machine here belongs to a NEWER rep that
                // stopped the stream inside this save window; its own re-arm
                // owns the machine — do nothing (hand off, don't stomp).
                if case .stopping = handsFreeState {
                    return
                }
                // Machine already reflects the live stream. Refresh the idle
                // disarm budget and the mirror beat; leave samples/buffer
                // alone.
                armedStreamIdleBudget = ArmedStreamIdleBudget()
                scheduleArmTimeout()
                pushForceBeat()
            } else if case .stopping = handsFreeState {
                // The stream was stopped at save time (transport was
                // unavailable at stop): blind re-arm + restart.
                handsFreeState = rearmedHandsFreeForce(afterStop: reason)
                armedStreamIdleBudget = ArmedStreamIdleBudget()
                resetRecordingBuffer()
                write(.startWeight)
                scheduleArmTimeout()
                pushForceBeat()
            }
        }
    }

    private func clearHandsFreeAfterTransportLoss() {
        handsFreeRequested = false
        handsFreeState = idleHandsFreeForce()
        armedStreamIdleBudget = ArmedStreamIdleBudget()
        armTimeoutTimer?.invalidate()
        armTimeoutTimer = nil
    }

    private func persistRecording(
        _ summary: StoppedRecording,
        claim: HandsFreeForceRepClaim,
        note: String,
        // #681 review F2: whether THIS stop kept the transport stream running
        // — decided synchronously at stop time and carried through the async
        // save, never re-derived from shared `handsFreeState` at completion
        // time (a second rep can arm/record/release inside this save window
        // and advance the machine).
        keepStreamRunning: Bool,
        // nil = never re-arm (the disconnect salvage); non-nil re-arms after
        // the save with slack semantics decided by the stop reason (#503).
        rearmHandsFreeAfterStop: HandsFreeStopReason?,
        lostSavedMessage: String = "Rep not saved — try pulling again",
        lostErrorMessage: String? = nil,
        rememberSelection: Bool = true
    ) {
        // Session id + immutable label/id snapshot are claimed before Task.
        let groupId = ensureSession()
        let row = Repo.makeTindeqRecordingRow(
            summary,
            id: claim.id,
            note: note,
            tag: claim.tag,
            side: claim.side,
            groupId: groupId
        )
        persistPreparedRecording(
            row,
            displayPeakKg: summary.peakKg,
            depletion: (summary.peakKg, summary.durationMs, claim.tag),
            lostSavedMessage: lostSavedMessage,
            lostErrorMessage: lostErrorMessage,
            rememberSelection: rememberSelection,
            keepStreamRunning: keepStreamRunning,
            rearmHandsFreeAfterStop: rearmHandsFreeAfterStop
        )
    }

    private func persistGuidedMeasured(
        _ summary: StoppedRecording,
        claim: GuidedForceRecordingClaim,
        completion: GuidedForceCompletion,
        outcome: String?,
        note: String,
        rememberSelection: Bool
    ) {
        let context = claim.context
        let metrics: MovementSetMetrics? = context.kind == .movementSet
            ? movementSetMetrics(
                samples: summary.samples.map { MovementSample(tMs: $0.t, kg: $0.kg) },
                band: context.targetBand,
                plannedDurationMs: Double(context.plannedDurationMs)
            )
            : nil
        let row = Repo.makeGuidedMeasuredRecordingRow(
            summary,
            claim: claim,
            completion: completion,
            groupId: ensureSession(),
            metrics: metrics,
            outcome: outcome,
            note: note
        )
        persistPreparedRecording(
            row,
            displayPeakKg: summary.peakKg,
            depletion: (summary.peakKg, completion.actualDurationMs, context.tag),
            lostSavedMessage: "Guided recording was not saved",
            lostErrorMessage: "Recording not saved — couldn't write to the watch.",
            rememberSelection: rememberSelection,
            keepStreamRunning: false,
            rearmHandsFreeAfterStop: nil
        )
    }

    /// Queue persistence is the durability boundary for every recording
    /// modality. A queued or directly-uploaded row counts into the gauge
    /// session; a `.lost` row never does.
    private func persistPreparedRecording(
        _ row: TindeqRecordingInsert,
        displayPeakKg: Double?,
        depletion: (peakKg: Double, durationMs: Int, tag: String)?,
        lostSavedMessage: String,
        lostErrorMessage: String?,
        rememberSelection: Bool,
        // #681 review F2: carried from the synchronous stop decision (see
        // `persistRecording`) so the completion re-arm never re-derives the
        // stopped-stream fact from mutable `handsFreeState`.
        keepStreamRunning: Bool,
        rearmHandsFreeAfterStop: HandsFreeStopReason?
    ) {
        // Both the queue owner and the completion generation are captured on
        // this synchronous MainActor turn, before the first await. #529
        // slice 2: a guided run's explicit assignment wins while active;
        // otherwise this session's immutable manual owner (captured once at
        // the first rep's `start()`/`armHandsFree()`, never re-derived at
        // this save boundary) — `userIdProvider()` only backstops the
        // unreachable case where neither owner was ever captured.
        let enqueuedUserId = persistenceOwnerAssigned
            ? persistenceOwnerUserId
            : (manualSessionOwnerUserId ?? userIdProvider())
        var row = row
        // #529 slice 2 — row-level defense-in-depth, see
        // `TindeqRecordingInsert.userId`'s doc comment.
        row.userId = enqueuedUserId
        let generation = persistenceGeneration
        saveOperationsInFlight += 1
        saving = true
        savedMsg = "Saving…"
        Task { @MainActor in
            guard generation == persistenceGeneration else { return }
            let outcome = await recordingQueue.enqueue(
                PendingTindeqRecording(row: row, enqueuedUserId: enqueuedUserId)
            )
            guard generation == persistenceGeneration else { return }
            if outcome == .lost {
                savedMsg = lostSavedMessage
                if let lostErrorMessage { errorMsg = lostErrorMessage }
                RecordingLossNotice.record()
            } else {
                let tagLabel = row.tag.isEmpty ? "" : " · \(row.tag)"
                if let displayPeakKg {
                    savedMsg = String(format: "Saved · %.1f kg%@", displayPeakKg, tagLabel)
                } else {
                    savedMsg = "Saved\(tagLabel)"
                }
                sessionCount += 1
                // Count changes are discrete mirror transitions, not a
                // telemetry update that may wait behind the coalescing lane.
                pushForceBeat()
                if let depletion {
                    recordRepDepletion(
                        peakKg: depletion.peakKg,
                        durationMs: depletion.durationMs,
                        tag: depletion.tag
                    )
                }
                if rememberSelection {
                    UserDefaults.standard.set(row.tag, forKey: "lastTindeqTag")
                    UserDefaults.standard.set(row.side, forKey: "lastTindeqSide")
                }
            }
            saveOperationsInFlight -= 1
            saving = saveOperationsInFlight > 0
            scheduleSavedMsgDismiss()

            // #529 slice-2 review round 2 R2-F1: resolve any deferred
            // account transition BEFORE the hands-free auto-rearm check
            // below — this rep's own Stop already set `measuring` false, but
            // since #681 a tap/cap save keeps the stream live and a second rep
            // can already be recording at this point; `resolvePendingAccountTransitionIfNeeded`
            // guards on `!measuring` itself, so it just defers again in that
            // case. `sessionCount` already reflects this rep (bumped above),
            // so it's safe to close/log the session now. If it DOES close,
            // `logSessionNow()`'s `cancelHandsFree()` clears
            // `handsFreeRequested`, so `rearmHandsFreeAfterSave` below (which
            // guards on it) correctly declines to re-arm instead of silently
            // continuing the closed session under whoever pulls next.
            resolvePendingAccountTransitionIfNeeded()

            if finishAfterSaves, saveOperationsInFlight == 0 {
                logSessionAfterPendingSaves()
            } else if let rearmHandsFreeAfterStop {
                rearmHandsFreeAfterSave(afterStop: rearmHandsFreeAfterStop, keepStreamRunning: keepStreamRunning)
            }
        }
    }

    private func scheduleSavedMsgDismiss() {
        savedMsgGeneration += 1
        let generation = savedMsgGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if generation == savedMsgGeneration { savedMsg = nil }
        }
    }

    func handleNotification(_ data: Data) {
        switch parseTindeqNotification(data) {
        case .weight(let incoming):
            // THE BLOCKER path sits alongside — and before — the original
            // manual guard. Armed samples reach Core but never the buffer.
            // #681: `waitingForSlack` while saving (measuring == false) is the
            // live post-tap/post-cap save window — the stream stays running so
            // a release edge that falls inside the async save is OBSERVED
            // (see stopAndSave), advancing the machine to armed in time for
            // the next pull. `isWaitingForHandsFreePull` covers it.
            if !measuring, handsFreeRequested, isWaitingForHandsFreePull {
                handleArmedSamples(incoming)
                return
            }
            guard measuring else { return } // idle noise stays out of manual recordings
            handleMeasuringSamples(incoming)
        case .lowBattery:
            lowBattery = true
        case .response, .unknown:
            break
        }
    }

    private func handleArmedSamples(_ incoming: [TindeqFrame.WeightSample]) {
        for (index, sample) in incoming.enumerated() {
            // #681 review F1: the idle budget is re-based at every armed-epoch
            // boundary (arm, rep start, save-window entry, re-arm, transport
            // loss), so a sample inside the save window starts a fresh
            // 10-minute clock instead of inheriting the stale pre-rep base and
            // spuriously cancelling mid-save. Mirrored in Core so the 32-bit
            // µs wrap and the threshold are testable on both KEEP-IN-SYNC
            // sides.
            let idleStep = observeArmedStreamIdleBudget(
                armedStreamIdleBudget,
                sampleUs: sample.us,
                timeoutSeconds: armTimeoutSeconds
            )
            armedStreamIdleBudget = idleStep.budget
            if idleStep.idleExceeded {
                cancelHandsFree()
                savedMsg = "Hands-free disarmed after 10 min idle"
                scheduleSavedMsgDismiss()
                return
            }
            let stepped = stepHandsFreeForce(
                handsFreeState,
                atMs: Double(sample.us) / 1000,
                kg: Double(sample.kg)
            )
            handsFreeState = stepped.state
            guard stepped.action == .start else { continue }
            beginArmedRecording(with: sample)
            // A BLE notification can batch several samples. Once this sample
            // claims Start, capture only the later samples from the same frame.
            if measuring, index + 1 < incoming.count {
                handleMeasuringSamples(Array(incoming.dropFirst(index + 1)))
            }
            return
        }
    }

    private func handleMeasuringSamples(_ incoming: [TindeqFrame.WeightSample]) {
        for sample in incoming {
            if t0us == nil { t0us = sample.us }
            let t = Double(sample.us &- (t0us ?? 0)) / 1000
            samples.append((t: t, kg: Double(sample.kg)))
            guard handsFreeRequested, case .recording(let belowSinceMs, _) = handsFreeState else {
                continue // unchanged manual buffering path
            }
            let stepped = stepHandsFreeForce(handsFreeState, atMs: t, kg: Double(sample.kg))
            handsFreeState = stepped.state // claim before stop/save Task
            if stepped.action == .stop {
                if let staticLoadEndMs = stepped.staticLoadEndMs {
                    // Guard 2 (#682): the machine proved a sustained non-human
                    // load (flat inside the band for flatlineWindowMs). Stop
                    // as `.staticLoad`, trimming to the flat-window start.
                    stopAndSave(reason: .staticLoad(endMs: staticLoadEndMs))
                } else {
                    // `.stop` only fires once the grace window measured from a
                    // non-nil belowSinceMs has elapsed, so the fallback is
                    // unreachable while stopGraceMs > 0; `t` (the sample that
                    // crossed the grace) is the conservative no-trim end if a
                    // future config ever made it reachable.
                    stopAndSave(reason: .released(endMs: belowSinceMs ?? t))
                }
                return
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension TindeqManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if status == .scanning { startScanIfPoweredOn() }
        case .unsupported, .unauthorized:
            clearHandsFreeAfterTransportLoss()
            status = .unsupported
            errorMsg = "Bluetooth unavailable"
        case .poweredOff:
            clearHandsFreeAfterTransportLoss()
            status = .idle
            errorMsg = "Bluetooth is off"
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        status = .connecting
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Tindeq.service])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        self.peripheral = nil
        clearHandsFreeAfterTransportLoss()
        status = .idle
        errorMsg = error?.localizedDescription ?? "Connection failed"
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        // An explicit discard clears `self.peripheral` before CoreBluetooth
        // delivers this callback. Ignore a stale callback so an old transport
        // cannot take a later connection offline.
        guard self.peripheral === peripheral else { return }
        handleTransportDisconnect(error: error)
    }

    /// Shared by the CoreBluetooth delegate and watch target tests. Keeping
    /// the salvage/auto-log flow behind this seam lets tests exercise the
    /// actual manager logic without constructing an Apple-owned CBPeripheral.
    func handleTransportDisconnect(error: Error?, wasIntentionalOverride: Bool? = nil) {
        if discardWithoutSavingActive {
            // `discardWithoutSaving()` already performed every cleanup
            // operation synchronously. A queued delegate callback must not
            // salvage or log anything after AuthManager changes users.
            stopUITimer()
            measuring = false
            resetRecordingBuffer()
            repClaims.discard()
            guidedClaims.discardActive()
            peripheral = nil
            fakeTransportConnected = false
            controlChar = nil
            status = .idle
            return
        }
        // Keep samples so an interrupted recording can still be saved.
        stopUITimer()
        let wasMeasuring = measuring
        measuring = false
        // #682: capture whether the interrupted rep was a hands-free pull
        // BEFORE `clearHandsFreeAfterTransportLoss()` clears the flag. Guard 1
        // applies only to hands-free-started reps at the persist boundary; a
        // manual interrupted rep keeps its existing behavior.
        let wasHandsFree = handsFreeRequested
        clearHandsFreeAfterTransportLoss()
        self.peripheral = nil
        fakeTransportConnected = false
        controlChar = nil
        status = .idle
        let wasIntentional = wasIntentionalOverride ?? intentionalDisconnect
        intentionalDisconnect = false
        if error != nil { errorMsg = "Device disconnected" }
        // Capture the kind before salvage consumes the synchronous claim. A
        // movement run may continue with cadence-only sets after this trace is
        // queued, so it must keep the same manager-owned session open; static
        // salvage is terminal and can finish/log the session here.
        let guidedKind = guidedClaims.active?.context.kind
        // Finish-on-disconnect: an unplanned drop mid-session with saved reps
        // surfaces the log prompt (mirrors the web status→idle effect). SL-58 #5.
        // Issue #151: a drop mid-hold used to silently lose the in-flight rep —
        // the samples buffer survived but nothing wrote it, and the next
        // start() wiped it. Salvage it like a manual Stop & Save when there's
        // enough of a hold to be worth keeping; otherwise fall back to the
        // existing drop-with-saved-reps prompt unchanged.
        if shouldSalvageGuidedForce(
            wasIntentional: wasIntentional,
            hasActiveClaim: guidedClaims.active != nil,
            wasMeasuring: wasMeasuring,
            sampleCount: samples.count
        ), let summary = makeSummary() {
            salvageInterruptedGuidedRecording(
                summary,
                finishSessionAfterSave: GuidedForceDisconnectPolicy
                    .shouldFinishSessionAfterSalvage(kind: guidedKind)
            )
        } else if guidedClaims.active == nil, TindeqSalvagePolicy.shouldSalvage(
            wasIntentional: wasIntentional, wasMeasuring: wasMeasuring, sampleCount: samples.count
        ), let summary = makeSummary() {
            salvageInterruptedRecording(summary, wasHandsFree: wasHandsFree)
        } else if !wasIntentional, sessionId != nil, sessionCount > 0 {
            repClaims.discard()
            guidedClaims.discardActive()
            // #280: the drop used to raise the finish prompt at the root. It
            // now logs the session itself at the predicted RPE — the user may
            // be nowhere near the watch when the Progressor dies, and a
            // prompt nobody sees orphans the session.
            logSessionNow()
        } else {
            repClaims.discard()
            guidedClaims.discardActive()
        }
        // #529 slice-2 review round 2 R2-F1: unconditional and last, after
        // every branch above — `measuring` was already set false at the top
        // of this function, so this is always a valid rep-ending point. Safe
        // regardless of which branch ran: a salvage branch already
        // incremented `saveOperationsInFlight` (synchronously, before its
        // own `Task`), so this correctly no-ops here and resolves instead
        // from that salvage's own `persistPreparedRecording` completion,
        // once `sessionCount` reflects it.
        resolvePendingAccountTransitionIfNeeded()
        pushForceBeat()
    }

    /// Salvage one interrupted guided trace through the same synchronous
    /// claim and durable queue path as an explicit finish. The active claim is
    /// consumed before persistence starts, so duplicate CoreBluetooth
    /// disconnect callbacks cannot create a second row.
    func salvageInterruptedGuidedRecording(
        _ summary: StoppedRecording,
        finishSessionAfterSave: Bool = true
    ) {
        guard let claim = guidedClaims.claimFinish(),
              let completion = guidedForceCompletion(
                  context: claim.context,
                  actualDurationMs: summary.durationMs
              )
        else {
            RecordingLossNotice.record()
            if finishSessionAfterSave {
                logSessionNow()
            }
            errorMsg = "Interrupted guided recording was not saved — recovery state was missing."
            return
        }
        currentKg = 0
        peakKg = summary.peakKg
        elapsedMs = Double(summary.durationMs)
        samples.removeAll()
        persistGuidedMeasured(
            summary,
            claim: claim,
            completion: completion,
            outcome: nil,
            note: "Recovered after connection loss",
            rememberSelection: false
        )
        // Static salvage is terminal and logs once after the durable enqueue;
        // movement salvage deliberately leaves this session open so the
        // runner can queue later cadence-only sets into the same group.
        if finishSessionAfterSave {
            logSessionNow()
        }
    }

    /// Salvages the in-flight rep after an unplanned BLE drop mid-hold
    /// (issue #151), mirroring the web app's interruption-salvage
    /// (`useTindeq.ts`/`ForceView.tsx`): saved with the same note text so it
    /// reads identically in History. Claims `samples` immediately so a late
    /// duplicate delegate callback can't double-save, then queues on the
    /// existing per-connect session group (minting one if this is the first
    /// rep of the connect) through the same manager-owned save path — #486:
    /// persist-first + idempotent upsert, so a BLE drop that ALSO coincides
    /// with no network doesn't lose the rep on top of the connection. Does
    /// NOT show any discard/save prompt — since #280 the salvaged rep is
    /// folded into the session's depletion and the session logs itself,
    /// exactly as a manual Finish would.
    func salvageInterruptedRecording(_ summary: StoppedRecording, wasHandsFree: Bool) {
        guard let claim = repClaims.claimStop() else {
            // This invariant currently follows from `measuring`: every real
            // recording begins a claim first. If later cleanup breaks it, a
            // recovered hold must still be reported and prior saved reps must
            // still be logged instead of disappearing behind a silent return.
            RecordingLossNotice.record()
            logSessionNow()
            // `logSessionNow()` may disarm an armed stream, whose buffer reset
            // clears errorMsg. Set this after cleanup so the loud report stays.
            errorMsg = "Interrupted force rep was not saved — recovery state was missing."
            return
        }
        // #682 Guard 1: the persist-boundary verdict applies to a hands-free
        // rep even when it ends by a BLE drop instead of an Arm/Stop edge. A
        // trivial rep (peak < `minPeakKg` or duration < `minDurationMs`) is
        // dropped here — it never enters the queue and is never reported as
        // queued. The stream is already back to idle (the transport is gone;
        // `clearHandsFreeAfterTransportLoss` reset it), so a discard re-arms
        // cleanly on the next connect with nothing further to do. Manual
        // interrupted reps (a manual Stop & Save drop) keep their existing
        // behavior and are never gated.
        if wasHandsFree,
           recordingVerdict(
               peakKg: summary.peakKg,
               durationMs: Double(summary.durationMs)
           ) != .persist {
            samples.removeAll()
            // A closed session with prior saved reps must still be logged; a
            // session with only this trivial rep logs nothing (sessionCount 0).
            logSessionNow()
            return
        }
        currentKg = 0
        peakKg = summary.peakKg
        elapsedMs = Double(summary.durationMs)
        samples.removeAll()
        persistRecording(
            summary,
            claim: claim,
            note: "Recovered after connection loss",
            keepStreamRunning: false,
            rearmHandsFreeAfterStop: nil,
            lostSavedMessage: "Recovered rep was not saved",
            lostErrorMessage: "Rep not saved — couldn't write to the watch.",
            rememberSelection: false
        )
        // Defer session logging until this save is durable or honestly lost.
        logSessionNow()
    }
}

// MARK: - CBPeripheralDelegate

extension TindeqManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Tindeq.service }) else {
            errorMsg = "Progressor service not found"
            disconnect()
            return
        }
        peripheral.discoverCharacteristics([Tindeq.notifyChar, Tindeq.controlChar], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        for c in service.characteristics ?? [] {
            if c.uuid == Tindeq.notifyChar {
                peripheral.setNotifyValue(true, for: c)
            } else if c.uuid == Tindeq.controlChar {
                controlChar = c
            }
        }
        if controlChar != nil {
            status = .connected
            write(.sampleBattery)
            pushForceBeat()
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == Tindeq.notifyChar, let data = characteristic.value else { return }
        handleNotification(data)
    }
}
