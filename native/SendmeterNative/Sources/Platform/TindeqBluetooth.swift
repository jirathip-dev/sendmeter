import CoreBluetooth
import Foundation
import Observation
import SendmeterCore

@MainActor
@Observable
public final class TindeqBluetooth: NSObject {
    public enum Status: Equatable {
        case unavailable
        case idle
        case scanning
        case connecting
        case connected
        case measuring
        case interrupted(String)
    }

    public private(set) var status: Status = .idle {
        didSet { onStatusChange?(status) }
    }
    public private(set) var currentKilograms: Double = 0
    public private(set) var peakKilograms: Double = 0
    public private(set) var averageKilograms: Double = 0
    public private(set) var elapsedMilliseconds: Double = 0
    public private(set) var lowBattery = false
    /// The live chart reads `sampleBuffer` over this display-coalesced range.
    /// The range is observed; the buffer is deliberately not, because the BLE
    /// path mutates it at notification rate and only publishes this range at
    /// the display cadence.
    public private(set) var visibleSampleRange: Range<Int> = 0..<0
    public private(set) var completedSummary: ForceSummary?
    /// True while the hands-free arming loop owns the weight stream (the
    /// Progressor only publishes force after the start command, so arming
    /// keeps the stream live BEFORE the recording begins). The pre-start
    /// samples drive the hands-free trigger and must never be saved.
    public private(set) var handsFreeArmed = false {
        didSet { onHandsFreeArmedChange?(handsFreeArmed) }
    }
    /// Publishes/sec of the force surface, bounded to display rate by the
    /// flush driver (#671). Debug-only; zero outside DEBUG builds.
    #if DEBUG
    public private(set) var publishesPerSecond: Double = 0
    #endif

    /// Stable reference-backed storage shared with the accumulator and the
    /// live chart. It is intentionally not an Observation property: only
    /// `visibleSampleRange` is published by the display-rate flush driver.
    @ObservationIgnored public let sampleBuffer: ForceSampleBuffer

    /// Every parsed weight sample, recording or not — the hands-free arming
    /// loop's feed. Set once by AppModel; never mutated by callers.
    @ObservationIgnored
    public var onWeightSample: ((TindeqWireSample) -> Void)?
    /// Status transitions used by AppModel for transport haptics and salvage.
    /// Observation replaces the old `$status` publisher; this callback keeps
    /// that side-effect path synchronous and MainActor-isolated.
    @ObservationIgnored
    public var onStatusChange: ((Status) -> Void)?
    @ObservationIgnored
    public var onHandsFreeArmedChange: ((Bool) -> Void)?

    public var interruptedRecording: ForceSummary? { interruptedSummary }
    /// #678: whether the interrupted rep was a hands-free pull (started via
    /// `beginArmedRecording()`). Captured in `didDisconnectPeripheral` BEFORE
    /// `handsFreeArmed`/`isRecording` clear, so the AppModel `.interrupted`
    /// handler can apply #682 Guard 1 to a hands-free salvaged rep (the watch
    /// captures `wasHandsFree` the same way, before
    /// `clearHandsFreeAfterTransportLoss()`).
    public private(set) var interruptedWasHandsFree = false
    public var hasUnsavedRecording: Bool { completedSummary != nil || interruptedSummary != nil }

    /// CoreBluetooth's lazy delegate handle is infrastructure, not UI state;
    /// Observation cannot transform a lazy stored property into a tracked
    /// computed property.
    @ObservationIgnored private lazy var central = CBCentralManager(delegate: self, queue: .main)
    private var peripheral: CBPeripheral?
    private var notifyCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var accumulator: ForceSessionAccumulator
    private var isRecording = false
    private var connectRequested = false
    private var interruptedSummary: ForceSummary?
    /// #678: whether the CURRENT recording (when `isRecording`) was started by
    /// the hands-free machine. Read in `didDisconnectPeripheral` to populate
    /// `interruptedWasHandsFree`, then reset with the recording.
    private var wasHandsFreeRecording = false
    /// #671: publishes are coalesced to display rate instead of firing per
    /// BLE notification. Notifications only accumulate and mark
    /// `pendingPublish`; a ~60 Hz flush timer (running while a stream is live)
    /// assigns the published values — the window included — at most once per
    /// display frame. The timer IS the throttle (one cadence source; a fire
    /// always publishes); the accumulator is the source of truth.
    /// The timer is installed and normally touched only by MainActor methods.
    /// `deinit` is deliberately nonisolated: destruction can happen on the
    /// executor that releases the last owner, but it must still invalidate the
    /// RunLoop.main-owned timer so that a released transport cannot leave a
    /// 60 Hz callback behind. `nonisolated(unsafe)` is scoped to this
    /// infrastructure slot; the callback below re-enters MainActor before it
    /// touches any UI or stream state.
    @ObservationIgnored
    private nonisolated(unsafe) var flushTimer: Timer?
    /// True when a notification has appended samples since the last flush.
    /// Consumed by the next timer fire — the final flush on stop uses it too.
    private var pendingPublish = false
    /// The last sample while hands-free-armed (pre-recording): the accumulator
    /// holds nothing yet, so the live reading comes from here (#671).
    private var lastSampleKilograms: Double = 0
    private let flushScheduler = ForcePublishScheduler()
    #if DEBUG
    private var flushCountInSecond = 0
    private var flushSecondStart: TimeInterval = 0
    #endif

    public override init() {
        let sampleBuffer = ForceSampleBuffer()
        self.sampleBuffer = sampleBuffer
        self.accumulator = ForceSessionAccumulator(sampleBuffer: sampleBuffer)
        super.init()
        _ = central
    }

    deinit {
        // RunLoop.main owns the timer; if this transport is ever released
        // mid-stream the timer must not keep firing at 60 Hz forever (#671
        // review F6). Invalidating in deinit closes that.
        flushTimer?.invalidate()
    }

    public func connect() {
        connectRequested = true
        guard central.state == .poweredOn else {
            status = central.state == .unsupported || central.state == .unauthorized
                ? .unavailable
                : .idle
            return
        }
        beginScan()
    }

    public func disconnect() {
        connectRequested = false
        // Final flush before the branch flags clear, so the last frame of a
        // live stream publishes (#671 review F3).
        stopFlushDriver()
        isRecording = false
        handsFreeArmed = false
        wasHandsFreeRecording = false
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        } else {
            resetConnection(status: .idle)
        }
    }

    public func stopMeasuring() -> ForceSummary? {
        let summary = accumulator.summary()
        completedSummary = summary
        // Final flush of the last samples while still marked recording, so the
        // metric card's peak/elapsed match the summary it just saved (#671
        // review F3).
        stopFlushDriver()
        guard let peripheral, let controlCharacteristic else {
            isRecording = false
            status = .idle
            return summary
        }
        peripheral.writeValue(
            Data([TindeqProtocolConstants.Command.stop.rawValue]),
            for: controlCharacteristic,
            type: .withResponse
        )
        isRecording = false
        status = .connected
        wasHandsFreeRecording = false
        return summary
    }

    /// Start the weight stream WITHOUT recording — the hands-free arming
    /// loop watches the load through `onWeightSample` and only promotes the
    /// stream to a recording via `beginArmedRecording()` once the pull is
    /// real (mirrors the web's `arm()` / `beginArmedRecording()` in
    /// `src/hooks/useTindeq.ts`).
    public func armHandsFree() throws {
        guard status == .connected,
              let peripheral,
              let controlCharacteristic
        else { throw BluetoothError.notReady }
        guard !hasUnsavedRecording else { throw BluetoothError.unsavedRecording }
        guard !handsFreeArmed, !isRecording else { return }
        accumulator.reset()
        currentKilograms = 0
        peakKilograms = 0
        averageKilograms = 0
        elapsedMilliseconds = 0
        visibleSampleRange = 0..<0
        handsFreeArmed = true
        startFlushDriver()
        peripheral.writeValue(
            Data([TindeqProtocolConstants.Command.startWeight.rawValue]),
            for: controlCharacteristic,
            type: .withResponse
        )
    }

    /// Promote an already-streaming armed sensor to a real recording without
    /// a second BLE command. The pre-start samples are discarded
    /// synchronously, before the recording claims ownership, so no arming
    /// load can leak into the saved force curve or a disconnect salvage.
    public func beginArmedRecording() -> Bool {
        guard handsFreeArmed else { return false }
        accumulator.reset()
        handsFreeArmed = false
        isRecording = true
        wasHandsFreeRecording = true
        status = .measuring
        return true
    }

    /// Stop the hands-free stream and return to plain connected. Safe when
    /// nothing was armed.
    public func disarmHandsFree() {
        guard handsFreeArmed || isRecording else { return }
        // Final flush while still armed, so the last live reading renders
        // (#671 review F3).
        stopFlushDriver()
        handsFreeArmed = false
        isRecording = false
        wasHandsFreeRecording = false
        try? write(.stop)
    }

    public func tare() throws {
        try write(.tare)
    }

    public func refreshBattery() throws {
        lowBattery = false
        try write(.sampleBattery)
    }

    public func clearInterruptedRecording() {
        interruptedSummary = nil
        interruptedWasHandsFree = false
    }

    public func clearCompletedRecording() {
        completedSummary = nil
        wasHandsFreeRecording = false
    }

    private func write(_ command: TindeqProtocolConstants.Command) throws {
        guard let peripheral,
              let controlCharacteristic,
              status == .connected || status == .measuring
        else { throw BluetoothError.notReady }
        peripheral.writeValue(
            Data([command.rawValue]),
            for: controlCharacteristic,
            type: .withResponse
        )
    }

    private func beginScan() {
        guard !central.isScanning else { return }
        status = .scanning
        central.scanForPeripherals(
            withServices: [CBUUID(string: TindeqProtocolConstants.serviceUUID)],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func resetConnection(status: Status) {
        central.stopScan()
        stopFlushDriver()
        peripheral?.delegate = nil
        peripheral = nil
        notifyCharacteristic = nil
        controlCharacteristic = nil
        self.status = status
    }

    /// The display-rate flush driver. Started while a stream is live
    /// (recording or hands-free-armed) so the 5 published force values are
    /// assigned at most once per display frame, independent of the BLE
    /// notification rate (#671). Notifications never assign published values
    /// directly — they only mark `pendingPublish`.
    ///
    /// The timer IS the throttle: its fire cadence is display rate, and a fire
    /// publishes whenever `pendingPublish` is set. There is deliberately no
    /// time-gate inside — two throttles with the same period beat against each
    /// other and drop a fraction of the fires (the #671 review's F1 finding).
    private func startFlushDriver() {
        guard flushTimer == nil else { return }
        let timer = Timer(timeInterval: flushScheduler.displayIntervalSeconds, repeats: true) { [weak self] _ in
            guard let self else { return }
            // RunLoop.main is the executor contract for this timer. Keep the
            // 60 Hz path synchronous (no Task allocation per frame), but make
            // the actor boundary explicit and fail loudly if that contract is
            // ever broken by a future scheduler change.
            MainActor.assumeIsolated {
                self.flushIfDue()
            }
        }
        // Add to `.common` so the live gauge keeps flushing during scroll
        // tracking (the default `.default` mode suspends timers mid-scroll).
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
        #if DEBUG
        flushCountInSecond = 0
        flushSecondStart = ProcessInfo.processInfo.systemUptime
        #endif
    }

    /// Invalidate the flush timer and publish any final pending frame so the
    /// last samples of a pull always render — the metric card stays on screen
    /// after Stop and would otherwise show a peak/elapsed one or two frames
    /// behind the summary it just saved (#671 review F3). No-op when nothing
    /// is pending.
    private func stopFlushDriver() {
        flushTimer?.invalidate()
        flushTimer = nil
        if pendingPublish {
            pendingPublish = false
            publishSnapshot()
        }
        #if DEBUG
        publishesPerSecond = 0
        #endif
    }

    private func flushIfDue() {
        // One cadence source: every timer fire with pending samples publishes.
        // `pendingPublish` is the only gate (F1).
        guard pendingPublish else { return }
        pendingPublish = false
        publishSnapshot()
        #if DEBUG
        flushCountInSecond += 1
        let now = ProcessInfo.processInfo.systemUptime
        if now - flushSecondStart >= 1.0 {
            publishesPerSecond = Double(flushCountInSecond) / (now - flushSecondStart)
            flushCountInSecond = 0
            flushSecondStart = now
        }
        #endif
    }

    /// Assign the published force values from one flush's snapshot. Recording
    /// publishes all five fields (one invalidation pulse); an armed-but-not-
    /// recording stream publishes only the live reading (#671 review F8);
    /// an idle stream publishes nothing.
    private func publishSnapshot() {
        let snapshot = ForcePublishSnapshotBuilder.snapshot(
            isRecording: isRecording,
            handsFreeArmed: handsFreeArmed,
            lastSampleKilograms: lastSampleKilograms,
            accumulator: accumulator
        )
        if snapshot.fields.contains(.currentKilograms) {
            currentKilograms = snapshot.currentKilograms
        }
        if snapshot.fields.contains(.peakKilograms) {
            peakKilograms = snapshot.peakKilograms
        }
        if snapshot.fields.contains(.averageKilograms) {
            averageKilograms = snapshot.averageKilograms
        }
        if snapshot.fields.contains(.elapsedMilliseconds) {
            elapsedMilliseconds = snapshot.elapsedMilliseconds
        }
        if snapshot.fields.contains(.window) {
            visibleSampleRange = snapshot.visibleRange
        }
    }

    /// Scene-phase pause (#671 review F6): while the app is backgrounded the
    /// process suspends anyway, and re-creating the timer on foreground is
    /// cheap — so the driver is torn down on leaving `.active` (dropping any
    /// unsent `pendingPublish`; it was stalling the display-rate cadence for
    /// nothing) and rebuilt by the normal `startFlushDriver()` path on return.
    public func setFlushDriverPaused(_ paused: Bool) {
        if paused {
            stopFlushDriver()
        } else if handsFreeArmed || isRecording {
            startFlushDriver()
        }
    }
}

public enum BluetoothError: Error, LocalizedError, FriendlyErrorClassifying {
    case notReady
    case unsavedRecording
    case serviceMissing
    case characteristicMissing

    public var errorDescription: String? {
        switch self {
        case .notReady: return "Progressor is not connected yet."
        case .unsavedRecording: return "Save or discard the previous pull before starting another."
        case .serviceMissing: return "Progressor force service was not found."
        case .characteristicMissing: return "Progressor force characteristics were not found."
        }
    }

    public var friendlyErrorClass: FriendlyErrorClass {
        switch self {
        case .notReady: return .progressorNotConnected
        case .unsavedRecording: return .previousRecordingUnfinished
        case .serviceMissing, .characteristicMissing: return .progressorUnrecognized
        }
    }
}

extension TindeqBluetooth: CBCentralManagerDelegate {
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                if connectRequested { beginScan() } else { status = .idle }
            case .unsupported, .unauthorized:
                resetConnection(status: .unavailable)
            case .poweredOff:
                resetConnection(
                    status: .interrupted(UserFacingError.message(for: .progressorUnavailable))
                )
            default:
                status = .idle
            }
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            let name = advertisedName ?? peripheral.name ?? ""
            guard name.hasPrefix(TindeqProtocolConstants.namePrefix) else { return }
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            status = .connecting
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            status = .connecting
            peripheral.discoverServices([CBUUID(string: TindeqProtocolConstants.serviceUUID)])
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            resetConnection(
                status: .interrupted(UserFacingError.message(for: .progressorConnectFailed))
            )
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            if isRecording {
                interruptedSummary = accumulator.summary()
                interruptedWasHandsFree = wasHandsFreeRecording
            }
            // Final flush while the branch flags still identify the stream, so
            // the last frame renders before the connection resets (#671 review
            // F3).
            stopFlushDriver()
            isRecording = false
            handsFreeArmed = false
            wasHandsFreeRecording = false
            resetConnection(
                status: .interrupted(UserFacingError.message(for: .progressorDisconnected))
            )
        }
    }
}

extension TindeqBluetooth: CBPeripheralDelegate {
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                resetConnection(
                    status: .interrupted(UserFacingError.message(for: .progressorConnectFailed))
                )
                return
            }
            guard let service = peripheral.services?.first(where: {
                $0.uuid == CBUUID(string: TindeqProtocolConstants.serviceUUID)
            }) else {
                resetConnection(
                    status: .interrupted(UserFacingError.message(for: .progressorUnrecognized))
                )
                return
            }
            peripheral.discoverCharacteristics(
                [
                    CBUUID(string: TindeqProtocolConstants.notifyCharacteristicUUID),
                    CBUUID(string: TindeqProtocolConstants.controlCharacteristicUUID)
                ],
                for: service
            )
        }
    }

    nonisolated public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                resetConnection(
                    status: .interrupted(UserFacingError.message(for: .progressorConnectFailed))
                )
                return
            }
            notifyCharacteristic = service.characteristics?.first(where: {
                $0.uuid == CBUUID(string: TindeqProtocolConstants.notifyCharacteristicUUID)
            })
            controlCharacteristic = service.characteristics?.first(where: {
                $0.uuid == CBUUID(string: TindeqProtocolConstants.controlCharacteristicUUID)
            })
            guard let notifyCharacteristic, controlCharacteristic != nil else {
                resetConnection(
                    status: .interrupted(UserFacingError.message(for: .progressorUnrecognized))
                )
                return
            }
            peripheral.setNotifyValue(true, for: notifyCharacteristic)
            status = .connected
            try? refreshBattery()
        }
    }

    nonisolated public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        // #671: the delegate is already on `.main` — `CBCentralManager` is
        // created with `queue: .main` (line 43), which is a documented
        // guarantee that every delegate callback runs on the main thread. The
        // old per-notification `Task { @MainActor in … }` hop is therefore
        // redundant (a Task allocation + actor hop per notification). We take
        // the main-actor call synchronously instead; `assumeIsolated` traps
        // (in release AND debug builds) if the thread ever isn't main, so a
        // future queue change fails loudly rather than silently hopping.
        MainActor.assumeIsolated {
            guard error == nil, let data = characteristic.value else { return }
            switch TindeqFrameParser.parse(data) {
            case let .weight(samples):
                // The hands-free arming loop watches the stream whether or
                // not a recording is owned; pre-start samples are consumed by
                // the controller and never accumulated.
                if handsFreeArmed || isRecording {
                    for sample in samples {
                        onWeightSample?(sample)
                    }
                }
                guard isRecording else {
                    if handsFreeArmed, let last = samples.last {
                        lastSampleKilograms = last.kilograms
                        pendingPublish = true
                    }
                    return
                }
                _ = accumulator.append(samples)
                // Coalesce: never assign published values per notification.
                // The flush driver publishes at display rate (#671).
                pendingPublish = true
                if accumulator.elapsedMilliseconds
                    >= Double(ForceSessionAccumulator.maximumRecordingMilliseconds) {
                    _ = stopMeasuring()
                }
            case .lowBattery:
                lowBattery = true
            case .response, .unknown:
                break
            }
        }
    }
}
