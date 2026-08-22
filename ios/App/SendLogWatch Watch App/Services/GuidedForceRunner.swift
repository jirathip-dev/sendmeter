import Foundation
import Observation
import SendLogWatchCore
import WatchKit

enum GuidedForceRunnerPhase: String, Equatable {
    case idle
    case preparing
    case work
    case rest
    case stopping
    case completed
    case failed
}

/// App-scoped adapter between the wall-clock Core state machine and the
/// app-scoped Tindeq manager.  The runner is deliberately the only owner of a
/// guided request: ForceGaugeView captures the picker values synchronously,
/// RootView observes this object, and no navigation closure can outlive the
/// setup screen that created it.
@MainActor
@Observable
final class GuidedForceRunner {
    private(set) var phase: GuidedForceRunnerPhase = .idle
    private(set) var runState: GuidedForceRunState?
    private(set) var snapshot: GuidedForceRunSnapshot?
    private(set) var protocolValue: WatchForceProtocol?
    private(set) var runId: UUID?
    private(set) var tag = ""
    private(set) var side = ""
    private(set) var errorMessage: String?
    private(set) var completionMessage: String?
    /// Stable account identity captured with the protocol/run snapshot. Token
    /// freshness is intentionally not part of this value: an expired token
    /// for the same user must remain able to run offline.
    private(set) var ownerUserId: UUID?

    @ObservationIgnored private let userIdProvider: @Sendable () -> UUID?
    private var manager: TindeqManager?
    private var tickTask: Task<Void, Never>?
    private var sessionFinishIssued = false
    private var stopRequested = false
    private var latestElapsedS = 0.0
    private var activeExecution: ActiveExecution?
    private var cadenceOnlyRun = false
    private var startedKeys = Set<GuidedForceRecordingKey>()
    private var finishedKeys = Set<GuidedForceRecordingKey>()
    private var cadenceSavedKeys = Set<GuidedForceRecordingKey>()
    private var messageGeneration = 0

    init(
        userIdProvider: @escaping @Sendable () -> UUID? = { WatchSessionStore.shared.userId }
    ) {
        self.userIdProvider = userIdProvider
    }

    private enum ActiveExecution: Equatable {
        case measured(kind: GuidedForceRecordingKind, key: GuidedForceRecordingKey, startedS: Double)
        case cadence(key: GuidedForceRecordingKey, startedS: Double)
        /// TindeqManager performs its own disconnect salvage.  Keeping this
        /// sentinel prevents a later state boundary from issuing a duplicate
        /// finish call while allowing movement cadence to continue.
        case salvaged(key: GuidedForceRecordingKey)

        var key: GuidedForceRecordingKey {
            switch self {
            case .measured(_, let key, _), .cadence(let key, _), .salvaged(let key): return key
            }
        }

        var startedS: Double? {
            switch self {
            case .measured(_, _, let startedS), .cadence(_, let startedS): return startedS
            case .salvaged: return nil
            }
        }
    }

    var isActive: Bool {
        switch phase {
        case .preparing, .work, .rest, .stopping: return true
        case .idle, .completed, .failed: return false
        }
    }

    var isMovement: Bool { protocolValue?.mode == .reverseAction }
    var isStatic: Bool { protocolValue?.mode == .hold }

    var isMeasured: Bool {
        guard case .measured = activeExecution else { return false }
        return true
    }

    var isCadenceOnly: Bool {
        isMovement && cadenceOnlyRun
    }

    var currentKg: Double? {
        guard isMeasured, manager?.status == .measuring else { return nil }
        return manager?.currentKg
    }

    var currentSet: Int {
        snapshot?.segment?.set ?? snapshot?.activeSet ?? 1
    }

    var currentRep: Int {
        snapshot?.segment?.rep ?? snapshot?.activeRep ?? 1
    }

    var totalSets: Int { protocolValue?.sets ?? 1 }
    var totalReps: Int { protocolValue?.reps ?? 1 }
    var progress: Double { snapshot?.progress ?? 0 }
    var remainingS: Double { snapshot?.segmentRemainingS ?? 0 }

    var countdownText: String {
        guard snapshot != nil else { return "—" }
        return "\(max(0, Int(ceil(remainingS))))"
    }

    var phaseTitle: String {
        guard let segment = snapshot?.segment else {
            switch phase {
            case .completed: return "Complete"
            case .failed: return "Not saved"
            default: return "Ready"
            }
        }
        switch segment.phase {
        case .prepare: return "Get ready"
        case .hold: return "Hold"
        case .concentric: return WatchForceProtocol.Labels.concentric
        case .eccentric: return WatchForceProtocol.Labels.eccentric
        case .rest, .setRest: return "Rest"
        }
    }

    /// Starts a run by taking every mutable setup value as a synchronous
    /// snapshot.  `manager` is passed explicitly so this seam can later be
    /// connected to persistence orchestration without inventing manager APIs.
    @discardableResult
    func start(
        protocolValue: WatchForceProtocol,
        tag: String,
        side: String,
        manager: TindeqManager
    ) -> Bool {
        guard !isActive else { return false }

        let normalizedTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTag.isEmpty else {
            failBeforeStart("Choose an exercise before starting.")
            return false
        }
        guard let ownerUserId = userIdProvider() else {
            // Queue `nil` is reserved for legacy/unattributed files. A new
            // guided run must have a stable owner so an async enqueue can
            // never be adopted by whichever account signs in later.
            failBeforeStart("Sign in on your iPhone before starting a guided Force protocol.")
            return false
        }
        switch guidedForceStartEligibility(
            for: protocolValue,
            sensorConnected: manager.status == .connected
        ) {
        case .allowed:
            break
        case .requiresProgressor:
            failBeforeStart("Connect Progressor for a measured static hold.")
            return false
        case .alternatingSidesUnsupported:
            failBeforeStart(
                "Run this alternating-sides protocol on your iPhone; alternating sides are unsupported on watch."
            )
            return false
        }

        let id = UUID()
        let startedAt = Date()
        self.protocolValue = protocolValue
        self.runId = id
        self.ownerUserId = ownerUserId
        self.tag = normalizedTag
        self.side = side
        self.manager = manager
        manager.setPersistenceOwner(ownerUserId)
        // #683: a guided protocol is a screen the user entered, and while it
        // is active free-hold hands-free is suspended entirely. Suspend here
        // (and re-arm in `endRun`/`fail`/`discardRunForAccountChange`) so a
        // stray pull cannot start an untimed rep beside the guided set.
        manager.setFreeHoldSuspended(true)
        self.errorMessage = nil
        self.completionMessage = nil
        self.sessionFinishIssued = false
        self.stopRequested = false
        self.latestElapsedS = 0
        self.activeExecution = nil
        self.cadenceOnlyRun = protocolValue.mode == .reverseAction && manager.status != .connected
        self.startedKeys.removeAll(keepingCapacity: true)
        self.finishedKeys.removeAll(keepingCapacity: true)
        self.cadenceSavedKeys.removeAll(keepingCapacity: true)
        self.runState = GuidedForceRunState(protocolValue: protocolValue, runId: id, startedAt: startedAt)
        self.snapshot = self.runState?.snapshot(elapsedS: 0)
        self.phase = .preparing

        // Process t=0 synchronously so the first haptic/visual state is never
        // dependent on a timer callback arriving after the setup view leaves.
        // The .prepare event owns the single launch cue; do not add a second
        // unconditional .start haptic immediately after this synchronous tick.
        tick(now: startedAt)
        guard isActive else { return true }
        scheduleTicks()
        return true
    }

    /// Re-evaluate from the wall clock after a foreground transition.  A
    /// delayed foreground tick is allowed to cross many boundaries; Core
    /// emits them in order and the runner handles each synchronously.
    func refresh() {
        guard isActive else { return }
        guard ensureRunOwnership() else { return }
        tick(now: Date())
    }

    /// Deterministic wall-clock seam used by the app-target integration tests.
    /// Production foreground/timer paths call `refresh()`, while this keeps a
    /// delayed boundary test from sleeping through a whole protocol.
    func advance(to now: Date) {
        guard isActive else { return }
        guard ensureRunOwnership() else { return }
        tick(now: now)
    }

    func stop() {
        guard isActive, var state = runState else { return }
        guard ensureRunOwnership() else { return }
        stopRequested = true
        phase = .stopping
        handleDisconnectIfNeeded()
        guard isActive else { return }

        // Stop uses the current wall clock, then handles the exact ordered
        // partial-finish boundary.  `GuidedForceRunState.stop` is terminal and
        // therefore a second tap cannot repeat any persistence call.
        let events = state.stop(now: Date())
        runState = state
        latestElapsedS = state.lastElapsedS
        snapshot = state.snapshot(elapsedS: state.lastElapsedS)
        let hadPartialWork = activeExecution != nil || events.contains {
            switch $0 {
            case .finishMovement, .finishStaticHold: return true
            default: return false
            }
        }
        handle(events)

        guard phase != .failed else { return }
        // A stop tap that arrives after a long suspension may cross the final
        // boundary.  Normal completion already ended this run; do not replace
        // its success state with a second "Stopped" finish path.
        guard !events.contains(where: {
            if case .completed = $0 { return true }
            return false
        }) else { return }
        finishSessionIfNeeded()
        endRun(message: hadPartialWork ? "Stopped · partial work saved" : "Stopped")
    }

    private func scheduleTicks() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.refresh()
                }
            }
        }
    }

    private func tick(now: Date) {
        guard isActive, var state = runState else { return }
        guard ensureRunOwnership() else { return }

        handleDisconnectIfNeeded()
        guard isActive else { return }

        let events = state.advance(now: now)
        runState = state
        latestElapsedS = state.lastElapsedS
        snapshot = state.snapshot(elapsedS: state.lastElapsedS)
        handle(events)
    }

    private func handle(_ events: [GuidedForceRunEvent]) {
        let hapticIndex = GuidedForceHapticPolicy.latestCueIndex(in: events)
        for (index, event) in events.enumerated() {
            let shouldCue = index == hapticIndex
            guard phase != .failed else { return }
            switch event {
            case .prepare:
                phase = .preparing
                if shouldCue { play(.directionUp) }
            case let .startMovement(set):
                startMovement(set: set, shouldCue: shouldCue)
            case let .direction(direction):
                phase = .work
                if shouldCue {
                    play(direction == .concentric ? .directionUp : .directionDown)
                }
            case let .finishMovement(set):
                finishMovement(set: set)
            case let .startStaticHold(set, rep):
                startStaticHold(set: set, rep: rep, shouldCue: shouldCue)
            case let .finishStaticHold(set, rep):
                finishStaticHold(set: set, rep: rep)
            case let .rest(_, _):
                phase = .rest
                if shouldCue { play(.click) }
            case .completed:
                completeNormally(shouldCue: shouldCue)
            case .stopped:
                if shouldCue { play(.stop) }
            }
        }
    }

    private func startMovement(set: Int, shouldCue: Bool) {
        guard let protocolValue, let runId else { return fail("Protocol snapshot was lost.") }
        let key = GuidedForceRecordingKey(runId: runId, set: set, rep: nil)
        guard startedKeys.insert(key).inserted else { return }

        phase = .work
        let startedS = protocolValue.timeline.first {
            $0.set == set && $0.phase == .concentric
        }?.startS ?? latestElapsedS
        if manager?.status == .connected {
            guard manager?.startMeasuredMovementSet(
                protocolValue: protocolValue,
                runId: runId,
                set: set,
                tag: tag,
                side: side,
                targetBand: fixedMovementTargetBand(for: protocolValue)
            ) == true else {
                fail("Progressor could not start this set.")
                return
            }
            activeExecution = .measured(kind: .movementSet, key: key, startedS: startedS)
        } else {
            // A disconnected movement run is intentionally cadence-only.  No
            // force values are read or claimed, and one row is written at the
            // end of each set.
            cadenceOnlyRun = true
            activeExecution = .cadence(key: key, startedS: startedS)
        }
        if shouldCue { play(.directionUp) }
    }

    private func finishMovement(set: Int) {
        guard let protocolValue, let runId else { return fail("Protocol snapshot was lost.") }
        let key = GuidedForceRecordingKey(runId: runId, set: set, rep: nil)
        guard finishedKeys.insert(key).inserted else { return }

        guard let execution = activeExecution, execution.key == key else { return }
        activeExecution = nil
        switch execution {
        case .measured:
            guard manager?.finishMeasuredMovementSet() == true else {
                fail("This measured set was not saved.")
                return
            }
        case let .cadence(_, startedS):
            guard cadenceSavedKeys.insert(key).inserted else { return }
            let durationMs = max(
                1,
                guidedMovementDurationMs(
                    protocolValue: protocolValue,
                    set: set,
                    startedS: startedS,
                    elapsedS: latestElapsedS
                )
            )
            guard manager?.saveCadenceOnlyMovementSet(
                protocolValue: protocolValue,
                runId: runId,
                set: set,
                tag: tag,
                side: side,
                actualDurationMs: durationMs
            ) == true else {
                fail("Cadence set was not saved.")
                return
            }
        case .salvaged:
            // The manager's disconnect handler already claimed and queued the
            // measured salvage.  This boundary only closes the Core state.
            break
        }
    }

    private func startStaticHold(set: Int, rep: Int, shouldCue: Bool) {
        guard let protocolValue, let runId else { return fail("Protocol snapshot was lost.") }
        guard manager?.status == .connected else {
            fail("Connect Progressor for a measured static hold.")
            return
        }
        let key = GuidedForceRecordingKey(runId: runId, set: set, rep: rep)
        guard startedKeys.insert(key).inserted else { return }
        guard manager?.startMeasuredStaticHold(
            protocolValue: protocolValue,
            runId: runId,
            set: set,
            rep: rep,
            tag: tag,
            side: side,
            targetBand: fixedMovementTargetBand(for: protocolValue)
        ) == true else {
            fail("Progressor could not start this hold.")
            return
        }
        let startedS = protocolValue.timeline.first {
            $0.phase == .hold && $0.set == set && $0.rep == rep
        }?.startS ?? latestElapsedS
        activeExecution = .measured(kind: .staticHold, key: key, startedS: startedS)
        phase = .work
        if shouldCue { play(.directionUp) }
    }

    private func finishStaticHold(set: Int, rep: Int) {
        guard let runId else { return fail("Protocol snapshot was lost.") }
        let key = GuidedForceRecordingKey(runId: runId, set: set, rep: rep)
        guard finishedKeys.insert(key).inserted else { return }
        guard let execution = activeExecution, execution.key == key else { return }
        activeExecution = nil
        guard case .measured = execution else {
            // An unplanned disconnect is salvaged by TindeqManager before the
            // runner sees the idle status; do not claim that recovered hold was
            // unsaved or issue a duplicate finish call.
            if case .salvaged = execution { return }
            return fail("Static hold was not measured.")
        }
        let holdEndS = protocolValue?.timeline.first {
            $0.phase == .hold && $0.set == set && $0.rep == rep
        }.map { $0.startS + $0.durationS }
        let isPartialStop = stopRequested && (holdEndS.map { latestElapsedS < $0 } ?? true)
        let outcome = isPartialStop ? "partial" : nil
        guard manager?.finishMeasuredStaticHold(outcome: outcome) == true else {
            fail("This static hold was not saved.")
            return
        }
    }

    private func handleDisconnectIfNeeded() {
        guard let execution = activeExecution, let protocolValue else { return }
        guard case .measured(let kind, let key, _) = execution else { return }

        let connected = manager?.status == .connected || manager?.status == .measuring
        guard !connected else { return }

        if kind == .movementSet, protocolValue.mode == .reverseAction {
            // TindeqManager salvages the active trace as soon as CoreBluetooth
            // reports the drop.  Keep the state machine running and switch
            // future sets to honest cadence-only rows.
            activeExecution = .salvaged(key: key)
            cadenceOnlyRun = true
            completionMessage = "Progressor disconnected · force recovery queued"
        } else {
            // TindeqManager's disconnect path claims and queues the partial
            // measured hold. Stop this static run so later holds are never
            // fabricated without a sensor, while the setup screen can report
            // the recovered/queued outcome honestly.
            activeExecution = .salvaged(key: key)
            endRun(
                message: "Progressor disconnected · partial hold recovered and queued",
                terminalPhase: .completed
            )
        }
    }

    private func completeNormally(shouldCue: Bool = true) {
        guard phase != .completed, phase != .failed else { return }
        phase = .completed
        if shouldCue { play(.success) }
        finishSessionIfNeeded()
        endRun(message: "Protocol complete · session saved")
    }

    private func finishSessionIfNeeded() {
        guard !sessionFinishIssued else { return }
        sessionFinishIssued = true
        // TindeqManager owns the existing in-flight save gate: if the last
        // measured/cadence row is still being queued, logSessionNow defers
        // the session finish until that durable operation completes.
        manager?.logSessionNow()
    }

    /// Called synchronously by the app-owned auth relay observer. A token
    /// refresh for the same user is safe and leaves the run untouched; a new
    /// user (including signed out) invalidates the run before RootView can
    /// continue ticking it under the new account.
    func authStateDidChange(to state: WatchAuthState) {
        // Keep watching the manager after the visual run reaches a terminal
        // phase: its queue/session task may still be in flight, and an
        // account switch in that window must invalidate the old generation.
        guard ownerUserId != nil || manager != nil else { return }
        guard state.userId == ownerUserId else {
            discardRunForAccountChange()
            return
        }
    }

    private func ensureRunOwnership() -> Bool {
        guard isActive else { return true }
        guard userIdProvider() == ownerUserId else {
            discardRunForAccountChange()
            return false
        }
        return true
    }

    /// Drops all in-memory state and the manager's active transport/claim. It
    /// deliberately does not call `logSessionNow()`: doing so after AuthManager
    /// switched accounts could stamp an account-A run with account-B's token.
    private func discardRunForAccountChange() {
        guard manager != nil || ownerUserId != nil else { return }
        let wasActive = isActive
        tickTask?.cancel()
        tickTask = nil

        let oldManager = manager
        oldManager?.discardWithoutSaving()
        // After discard the manager is idle; clearing the flag here never
        // re-arms (status != .connected), so the armed waiting state from an
        // undisrupted run can't leak onto a different account.
        oldManager?.setFreeHoldSuspended(false)

        runState = nil
        snapshot = nil
        activeExecution = nil
        manager = nil
        ownerUserId = nil
        runId = nil
        protocolValue = nil
        tag = ""
        side = ""
        cadenceOnlyRun = false
        sessionFinishIssued = true
        stopRequested = false
        startedKeys.removeAll(keepingCapacity: true)
        finishedKeys.removeAll(keepingCapacity: true)
        cadenceSavedKeys.removeAll(keepingCapacity: true)
        guard wasActive else {
            // A completed/failed UI may outlive its queue task. Invalidate the
            // old manager silently, but never replace a genuine terminal
            // result with a false account-change failure much later.
            return
        }
        let discardMessage = "Protocol discarded because the signed-in account changed."
        errorMessage = discardMessage
        completionMessage = nil
        phase = .failed
        publishMessage(discardMessage, generation: messageGeneration + 1)
    }

    private func failBeforeStart(_ message: String) {
        errorMessage = message
        completionMessage = nil
        phase = .failed
        publishMessage(message, generation: messageGeneration + 1)
    }

    private func fail(_ message: String) {
        guard phase != .failed else { return }
        errorMessage = message
        phase = .failed
        tickTask?.cancel()
        finishSessionIfNeeded()
        manager?.setFreeHoldSuspended(false)
        manager?.clearPersistenceOwner()
        publishMessage(message, generation: messageGeneration + 1)
    }

    private func endRun(
        message: String,
        terminalPhase: GuidedForceRunnerPhase? = nil
    ) {
        tickTask?.cancel()
        tickTask = nil
        manager?.setFreeHoldSuspended(false)
        manager?.clearPersistenceOwner()
        completionMessage = message
        publishMessage(message, generation: messageGeneration + 1)
        runState = nil
        snapshot = nil
        activeExecution = nil
        phase = terminalPhase
            ?? (message.hasPrefix("Protocol complete") || message.hasPrefix("Stopped")
                ? .completed
                : phase)
    }

    private func publishMessage(_ message: String, generation: Int) {
        messageGeneration = generation
        let currentGeneration = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.messageGeneration == currentGeneration else { return }
                self.completionMessage = nil
                if self.phase == .completed { self.phase = .idle }
            }
        }
    }

    private func play(_ haptic: WKHapticType) {
        WKInterfaceDevice.current().play(haptic)
    }
}
