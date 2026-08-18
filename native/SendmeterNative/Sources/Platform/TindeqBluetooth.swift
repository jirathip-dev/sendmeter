import CoreBluetooth
import Foundation
import SendmeterCore

@MainActor
public final class TindeqBluetooth: NSObject, ObservableObject {
    public enum Status: Equatable {
        case unavailable
        case idle
        case scanning
        case connecting
        case connected
        case measuring
        case interrupted(String)
    }

    @Published public private(set) var status: Status = .idle
    @Published public private(set) var currentKilograms: Double = 0
    @Published public private(set) var peakKilograms: Double = 0
    @Published public private(set) var averageKilograms: Double = 0
    @Published public private(set) var elapsedMilliseconds: Double = 0
    @Published public private(set) var lowBattery = false
    @Published public private(set) var visibleSamples: [TindeqSample] = []
    @Published public private(set) var completedSummary: ForceSummary?
    /// True while the hands-free arming loop owns the weight stream (the
    /// Progressor only publishes force after the start command, so arming
    /// keeps the stream live BEFORE the recording begins). The pre-start
    /// samples drive the hands-free trigger and must never be saved.
    @Published public private(set) var handsFreeArmed = false
    /// Publishes/sec of the force surface, bounded to display rate by the
    /// flush driver (#671). Debug-only; zero outside DEBUG builds.
    #if DEBUG
    @Published public private(set) var publishesPerSecond: Double = 0
    #endif

    /// Every parsed weight sample, recording or not — the hands-free arming
    /// loop's feed. Set once by AppModel; never mutated by callers.
    public var onWeightSample: ((TindeqWireSample) -> Void)?

    public var interruptedRecording: ForceSummary? { interruptedSummary }
    public var hasUnsavedRecording: Bool { completedSummary != nil || interruptedSummary != nil }

    private lazy var central = CBCentralManager(delegate: self, queue: .main)
    private var peripheral: CBPeripheral?
    private var notifyCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var accumulator = ForceSessionAccumulator()
    private var isRecording = false
    private var connectRequested = false
    private var interruptedSummary: ForceSummary?
    /// #671: publishes are coalesced to display rate instead of firing per
    /// BLE notification. Notifications only accumulate; a ~60 Hz flush timer
    /// (running while a stream is live) assigns the published values — the
    /// window included — at most once per display frame. The accumulator is
    /// the source of truth; the flush reads cheap computed values off it, so
    /// the hot path stays allocation-free.
    private var flushTimer: Timer?
    private var lastFlushTime: TimeInterval = 0
    private var pendingPublish = false
    /// The last sample while hands-free-armed (pre-recording): the accumulator
    /// holds nothing yet, so the live reading comes from here (#671).
    private var lastSampleKilograms: Double = 0
    private var coalescer = ForcePublishCoalescer()
    #if DEBUG
    private var flushCountInSecond = 0
    private var flushSecondStart: TimeInterval = 0
    #endif

    public override init() {
        super.init()
        _ = central
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
        isRecording = false
        handsFreeArmed = false
        stopFlushDriver()
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        } else {
            resetConnection(status: .idle)
        }
    }

    public func startMeasuring() throws {
        guard status == .connected,
              let peripheral,
              let controlCharacteristic
        else { throw BluetoothError.notReady }
        guard !hasUnsavedRecording else { throw BluetoothError.unsavedRecording }
        accumulator.reset()
        currentKilograms = 0
        peakKilograms = 0
        averageKilograms = 0
        elapsedMilliseconds = 0
        visibleSamples = []
        isRecording = true
        status = .measuring
        startFlushDriver()
        peripheral.writeValue(
            Data([TindeqProtocolConstants.Command.startWeight.rawValue]),
            for: controlCharacteristic,
            type: .withResponse
        )
    }

    public func stopMeasuring() -> ForceSummary? {
        let summary = accumulator.summary()
        completedSummary = summary
        guard let peripheral, let controlCharacteristic else {
            isRecording = false
            status = .idle
            stopFlushDriver()
            return summary
        }
        peripheral.writeValue(
            Data([TindeqProtocolConstants.Command.stop.rawValue]),
            for: controlCharacteristic,
            type: .withResponse
        )
        isRecording = false
        status = .connected
        stopFlushDriver()
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
        visibleSamples = []
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
        status = .measuring
        return true
    }

    /// Stop the hands-free stream and return to plain connected. Safe when
    /// nothing was armed.
    public func disarmHandsFree() {
        guard handsFreeArmed || isRecording else { return }
        handsFreeArmed = false
        isRecording = false
        stopFlushDriver()
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
    }

    public func clearCompletedRecording() {
        completedSummary = nil
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
    private func startFlushDriver() {
        guard flushTimer == nil else { return }
        lastFlushTime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.flushIfDue()
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

    private func stopFlushDriver() {
        flushTimer?.invalidate()
        flushTimer = nil
        pendingPublish = false
        #if DEBUG
        publishesPerSecond = 0
        #endif
    }

    private func flushIfDue() {
        let now = ProcessInfo.processInfo.systemUptime
        guard pendingPublish else { return }
        guard coalescer.shouldFlush(now: now, lastFlush: lastFlushTime) else { return }
        lastFlushTime = now
        pendingPublish = false
        updatePublishedValues()
        #if DEBUG
        flushCountInSecond += 1
        if now - flushSecondStart >= 1.0 {
            publishesPerSecond = Double(flushCountInSecond) / (now - flushSecondStart)
            flushCountInSecond = 0
            flushSecondStart = now
        }
        #endif
    }

    private func updatePublishedValues() {
        if isRecording {
            currentKilograms = accumulator.currentKilograms
            peakKilograms = accumulator.peakKilograms
            averageKilograms = accumulator.averageKilograms
            elapsedMilliseconds = accumulator.elapsedMilliseconds
        } else if handsFreeArmed {
            // Armed but not yet recording: samples feed the hands-free loop,
            // never the accumulator. The live reading comes from the last
            // sample that marked `pendingPublish`.
            currentKilograms = lastSampleKilograms
        }
        visibleSamples = Array(accumulator.visibleWindow())
    }
}

public enum BluetoothError: Error, LocalizedError {
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
                resetConnection(status: .interrupted("Bluetooth is off"))
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
            resetConnection(status: .interrupted(error?.localizedDescription ?? "Could not connect"))
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
            }
            isRecording = false
            handsFreeArmed = false
            let message = error?.localizedDescription ?? "Progressor disconnected"
            resetConnection(status: .interrupted(message))
        }
    }
}

extension TindeqBluetooth: CBPeripheralDelegate {
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                resetConnection(status: .interrupted(error.localizedDescription))
                return
            }
            guard let service = peripheral.services?.first(where: {
                $0.uuid == CBUUID(string: TindeqProtocolConstants.serviceUUID)
            }) else {
                resetConnection(status: .interrupted(BluetoothError.serviceMissing.localizedDescription))
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
                resetConnection(status: .interrupted(error.localizedDescription))
                return
            }
            notifyCharacteristic = service.characteristics?.first(where: {
                $0.uuid == CBUUID(string: TindeqProtocolConstants.notifyCharacteristicUUID)
            })
            controlCharacteristic = service.characteristics?.first(where: {
                $0.uuid == CBUUID(string: TindeqProtocolConstants.controlCharacteristicUUID)
            })
            guard let notifyCharacteristic, controlCharacteristic != nil else {
                resetConnection(status: .interrupted(BluetoothError.characteristicMissing.localizedDescription))
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
        // created with `queue: .main` (line 46), which is a documented
        // guarantee that every delegate callback runs on the main thread. The
        // old per-notification `Task { @MainActor in … }` hop is therefore
        // redundant (a Task allocation + actor hop per notification). We take
        // the main-actor call synchronously instead; in a DEBUG build
        // `assumeIsolated` traps if the thread ever isn't main, so a future
        // queue change fails loudly rather than silently hopping.
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
