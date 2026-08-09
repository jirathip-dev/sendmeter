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
/// useTindeq hook: same statuses, 30 min recording cap, t rounded to ms int,
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
    private var armedStreamStartedAtUs: UInt32?
    private let armTimeoutSeconds: TimeInterval
    private let recordingQueue: any TindeqRecordingQueueing
    private let sessionQueue: any TindeqSessionQueueing
    /// Test seam: production writes through CoreBluetooth; watch target tests
    /// inject this observer so the real command ordering is inspectable.
    private let commandWriter: ((Tindeq.Cmd) -> Void)?
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

    init(
        recordingQueue: any TindeqRecordingQueueing = PendingRecordingQueue.shared,
        sessionQueue: any TindeqSessionQueueing = PendingSessionQueue.shared,
        armTimeoutSeconds: TimeInterval = 10 * 60,
        commandWriter: ((Tindeq.Cmd) -> Void)? = nil
    ) {
        self.recordingQueue = recordingQueue
        self.sessionQueue = sessionQueue
        self.armTimeoutSeconds = armTimeoutSeconds
        self.commandWriter = commandWriter
        self.fakeTransportConnected = commandWriter != nil
        super.init()
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
        let pending = PendingTindeqSession.build(
            sessionStartedAt: sessionStartedAt,
            recordingCount: sessionCount,
            rpe: predictedRPE.rpe,
            groupId: groupId
        )
        clearSession()
        Task {
            let outcome = await sessionQueue.enqueue(pending)
            guard outcome == .lost else { return }
            await MainActor.run {
                self.errorMsg = "Force session couldn't be saved"
                GaugeSessionLossNotice.record()
            }
        }
    }

    // MARK: Controls

    func connect() {
        errorMsg = nil
        resetForceMirrorPipeline()
        forceMirrorSequence = LiveMirrorSequence(runId: UUID())
        forceMirrorStatus = nil
        forceMirrorCount = sessionCount
        forceMirrorTag = liveTag
        forceMirrorSide = liveSide
        status = .scanning
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
        peripheral = nil
        fakeTransportConnected = false
        controlChar = nil
        status = .idle
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
        guard repClaims.begin(tag: trimmedLiveTag, side: liveSide) != nil else { return }
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
        guard status == .connected, !handsFreeRequested, !saving,
              guidedClaims.active == nil, !trimmedLiveTag.isEmpty else { return }
        savedMsgGeneration += 1
        savedMsg = nil
        handsFreeRequested = true
        handsFreeState = armedHandsFreeForce() // synchronous control claim
        armedStreamStartedAtUs = nil
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
        armedStreamStartedAtUs = nil
        armTimeoutTimer?.invalidate()
        armTimeoutTimer = nil
        if wasArmedStream {
            write(.stop)
            resetRecordingBuffer()
            pushForceBeat()
        }
    }

    /// Stop and persistence share one synchronous claim. Automatic release,
    /// the Stop & Save button and the 30-minute cap all enter here; only the
    /// first can take `repClaims.active`, and that happens before the
    /// Task/await below. `reason` has no default on purpose (#503): only
    /// `.released` carries a trim timestamp and re-arms without fresh slack,
    /// and every call site must say which stop it is — a new caller cannot
    /// get release semantics by accident.
    func stopAndSave(reason: HandsFreeStopReason) {
        guard let claim = repClaims.claimStop() else { return }
        if handsFreeRequested { handsFreeState = .stopping }
        guard let summary = stopTransport(endMs: reason.trimEndMs) else {
            if handsFreeRequested, transportConnected {
                rearmHandsFreeAfterSave(afterStop: reason)
            }
            return
        }
        persistRecording(
            summary,
            claim: claim,
            note: "",
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
        guard status == .connected, !handsFreeRequested, !saving,
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

    private func stopTransport(endMs: Double? = nil) -> StoppedRecording? {
        measuring = false
        stopUITimer()
        write(.stop)
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
        guard !trimmedLiveTag.isEmpty else {
            cancelHandsFree()
            savedMsg = "Pick an exercise to start"
            scheduleSavedMsgDismiss()
            return
        }
        guard repClaims.begin(tag: trimmedLiveTag, side: liveSide) != nil else {
            cancelHandsFree()
            return
        }
        t0us = first.us
        samples.append((t: 0, kg: Double(first.kg)))
        measuring = true
        status = .measuring
        startUITimer()
        pushForceBeat()
    }

    private func rearmHandsFreeAfterSave(afterStop reason: HandsFreeStopReason) {
        guard handsFreeRequested, transportConnected, status == .connected, !finishAfterSaves else {
            handsFreeState = idleHandsFreeForce()
            return
        }
        // Only `.released` has already proved 1.5 s <= stopKg, so it re-arms
        // straight to armed — requiring another slack sample after the
        // stop/save/restart dark window can silently miss a fast next rep.
        // Tap/cap stops have no such proof and must still gate the same
        // continuous load before re-arming. Decided in Core (#503).
        handsFreeState = rearmedHandsFreeForce(afterStop: reason)
        armedStreamStartedAtUs = nil
        resetRecordingBuffer()
        write(.startWeight)
        scheduleArmTimeout()
        pushForceBeat()
    }

    private func clearHandsFreeAfterTransportLoss() {
        handsFreeRequested = false
        handsFreeState = idleHandsFreeForce()
        armedStreamStartedAtUs = nil
        armTimeoutTimer?.invalidate()
        armTimeoutTimer = nil
    }

    private func persistRecording(
        _ summary: StoppedRecording,
        claim: HandsFreeForceRepClaim,
        note: String,
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
        rearmHandsFreeAfterStop: HandsFreeStopReason?
    ) {
        saveOperationsInFlight += 1
        saving = true
        savedMsg = "Saving…"
        Task { @MainActor in
            let outcome = await recordingQueue.enqueue(PendingTindeqRecording(row: row))
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

            if finishAfterSaves, saveOperationsInFlight == 0 {
                logSessionAfterPendingSaves()
            } else if let rearmHandsFreeAfterStop {
                rearmHandsFreeAfterSave(afterStop: rearmHandsFreeAfterStop)
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
            if armedStreamStartedAtUs == nil { armedStreamStartedAtUs = sample.us }
            let armedMs = Double(sample.us &- (armedStreamStartedAtUs ?? sample.us)) / 1000
            if armTimeoutSeconds > 0, armedMs >= armTimeoutSeconds * 1000 {
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
            guard handsFreeRequested, case .recording(let belowSinceMs) = handsFreeState else {
                continue // unchanged manual buffering path
            }
            let stepped = stepHandsFreeForce(handsFreeState, atMs: t, kg: Double(sample.kg))
            handsFreeState = stepped.state // claim before stop/save Task
            if stepped.action == .stop {
                // `.stop` only fires once the grace window measured from a
                // non-nil belowSinceMs has elapsed, so the fallback is
                // unreachable while stopGraceMs > 0; `t` (the sample that
                // crossed the grace) is the conservative no-trim end if a
                // future config ever made it reachable.
                stopAndSave(reason: .released(endMs: belowSinceMs ?? t))
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
        handleTransportDisconnect(error: error)
    }

    /// Shared by the CoreBluetooth delegate and watch target tests. Keeping
    /// the salvage/auto-log flow behind this seam lets tests exercise the
    /// actual manager logic without constructing an Apple-owned CBPeripheral.
    func handleTransportDisconnect(error: Error?, wasIntentionalOverride: Bool? = nil) {
        // Keep samples so an interrupted recording can still be saved.
        stopUITimer()
        let wasMeasuring = measuring
        measuring = false
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
            salvageInterruptedRecording(summary)
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
    func salvageInterruptedRecording(_ summary: StoppedRecording) {
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
        currentKg = 0
        peakKg = summary.peakKg
        elapsedMs = Double(summary.durationMs)
        samples.removeAll()
        persistRecording(
            summary,
            claim: claim,
            note: "Recovered after connection loss",
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
