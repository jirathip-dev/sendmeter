import CoreBluetooth
import Foundation
import Observation
import WatchConnectivity

/// CoreBluetooth central for the Tindeq Progressor. Mirrors the web app's
/// useTindeq hook: same statuses, 120 s recording cap, t rounded to ms int,
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

    // Gauge session grouping (SL-58 #5): every rep saved during one connect
    // shares a group_id, minted lazily on the first save. Lives on the manager
    // (which is owned app-level) — not on the view — so it survives navigating
    // away from the Force screen while the Progressor stays connected.
    var sessionId: UUID?
    var sessionStartedAt: Date?
    var sessionCount = 0
    /// Set when an unplanned disconnect (or the Finish button) should surface
    /// the "log this session?" prompt. Presented at the root so it shows even
    /// after the user has navigated away from the Force screen.
    var pendingFinish = false

    // SL-87 live mirror: the phone Force tab shows what the watch gauge is
    // doing. The view keeps these in sync with its pickers so beats carry the
    // exercise context.
    var liveTag = "" { didSet { pushForceBeat() } }
    var liveSide = "" { didSet { pushForceBeat() } }
    private var beatTick = 0

    private static let maxRecordingMs: Double = 120_000

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var controlChar: CBCharacteristic?
    private var measuring = false
    private var t0us: UInt32?
    private var samples: [(t: Double, kg: Double)] = []
    private var uiTimer: Timer?
    // Distinguishes an app-initiated disconnect from a real BLE drop, so only
    // the latter triggers the finish-on-disconnect prompt.
    private var intentionalDisconnect = false

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
        pendingFinish = false
    }

    // MARK: Controls

    func connect() {
        errorMsg = nil
        status = .scanning
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            startScanIfPoweredOn()
        }
    }

    func disconnect() {
        stopUITimer()
        measuring = false
        if let p = peripheral {
            // Flag only when a delegate callback will follow, so it can't go
            // stale and mask a later real drop.
            intentionalDisconnect = true
            central?.cancelPeripheralConnection(p)
        }
        peripheral = nil
        controlChar = nil
        status = .idle
        pushForceBeat()
    }

    func tare() {
        write(.tare)
    }

    func start() {
        samples.removeAll()
        t0us = nil
        currentKg = 0
        peakKg = 0
        elapsedMs = 0
        errorMsg = nil
        write(.startWeight)
        measuring = true
        status = .measuring
        startUITimer()
        pushForceBeat()
    }

    func stop() -> StoppedRecording? {
        measuring = false
        stopUITimer()
        write(.stop)
        status = peripheral != nil ? .connected : .idle
        guard let summary = makeSummary() else { return nil }
        currentKg = 0
        peakKg = summary.peakKg
        elapsedMs = Double(summary.durationMs)
        pushForceBeat()
        return summary
    }

    /// Rounding/derivation shared by `stop()` and the disconnect-salvage path
    /// (issue #151) so a recovered rep looks identical to a manually-stopped
    /// one: t rounded to ms int, kg to 2 dp, duration/peak/avg from the same
    /// samples.
    private func makeSummary() -> StoppedRecording? {
        guard !samples.isEmpty else { return nil }
        let rounded = samples.map { (t: ($0.t).rounded(), kg: ($0.kg * 100).rounded() / 100) }
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

    /// Downsampled trailing window for the phone mirror's sparkline (SL-95,
    /// follow-up to SL-87). The on-watch `Sparkline` (ForceGaugeView) already
    /// reads full-rate `recentSamples()` at its own 10 Hz timer; WC beats
    /// instead carry a much coarser slice — the same ~3 s trailing window,
    /// thinned to at most ~15 points — so a ~2 Hz beat stays a tiny JSON array
    /// rather than shipping raw 80 Hz BLE samples over WatchConnectivity.
    /// Each point is `[t, kg]` with `t` still milliseconds (same clock as
    /// `elapsed_ms`, relative to this hold's start) so the phone can re-anchor
    /// every point to wall-clock time using the beat's `updated_at` and
    /// `elapsed_ms`, then accumulate its own rolling buffer client-side (see
    /// `useLiveForce.ts`) — no single beat's window is trusted as the whole
    /// history.
    private func sparkWindow() -> [[Double]] {
        let recent = recentSamples(windowMs: 3_000)
        guard !recent.isEmpty else { return [] }
        let step = max(1, recent.count / 15)
        var out: [[Double]] = []
        var i = 0
        while i < recent.count {
            let s = recent[i]
            out.append([s.t.rounded(), (s.kg * 100).rounded() / 100])
            i += step
        }
        return out
    }

    // MARK: Internals

    private func write(_ cmd: Tindeq.Cmd) {
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
            if last.t >= Self.maxRecordingMs, self.measuring {
                _ = self.stop()
            }
        }
    }

    /// SL-87: fire one live-force beat over WatchConnectivity when the phone
    /// is reachable — same Bluetooth-fast mirror path as the workout beat
    /// (the auth-bridge plugin forwards it to the WebView). Fire-and-forget;
    /// there's deliberately no Supabase fallback (an 80 Hz gauge has no
    /// business heartbeating the network).
    private func pushForceBeat() {
        let wc = WCSession.default
        guard wc.activationState == .activated, wc.isReachable else { return }
        let statusStr: String
        switch status {
        case .measuring: statusStr = "measuring"
        case .connected: statusStr = "connected"
        default: statusStr = "idle"
        }
        wc.sendMessage(
            [
                "kind": "liveForce",
                "status": statusStr,
                "kg": (currentKg * 100).rounded() / 100,
                "peak_kg": (peakKg * 100).rounded() / 100,
                "elapsed_ms": elapsedMs.rounded(),
                "session_count": sessionCount,
                "tag": liveTag,
                "side": liveSide,
                "updated_at": Date().timeIntervalSince1970,
                // SL-95: only meaningful mid-hold — omitted (empty) otherwise
                // so idle/connected beats stay tiny.
                "spark": status == .measuring ? sparkWindow() : [],
            ],
            replyHandler: nil, errorHandler: nil
        )
    }

    private func stopUITimer() {
        uiTimer?.invalidate()
        uiTimer = nil
    }

    private func handleNotification(_ data: Data) {
        switch parseTindeqNotification(data) {
        case .weight(let incoming):
            guard measuring else { return }
            for s in incoming {
                if t0us == nil { t0us = s.us }
                let t = Double(s.us &- (t0us ?? 0)) / 1000.0
                samples.append((t: t, kg: Double(s.kg)))
            }
        case .lowBattery:
            lowBattery = true
        case .response, .unknown:
            break
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
            status = .unsupported
            errorMsg = "Bluetooth unavailable"
        case .poweredOff:
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
        status = .idle
        errorMsg = error?.localizedDescription ?? "Connection failed"
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        // Keep samples so an interrupted recording can still be saved.
        stopUITimer()
        let wasMeasuring = measuring
        measuring = false
        self.peripheral = nil
        controlChar = nil
        status = .idle
        let wasIntentional = intentionalDisconnect
        intentionalDisconnect = false
        if error != nil { errorMsg = "Device disconnected" }
        // Finish-on-disconnect: an unplanned drop mid-session with saved reps
        // surfaces the log prompt (mirrors the web status→idle effect). SL-58 #5.
        // Issue #151: a drop mid-hold used to silently lose the in-flight rep —
        // the samples buffer survived but nothing wrote it, and the next
        // start() wiped it. Salvage it like a manual Stop & Save when there's
        // enough of a hold to be worth keeping; otherwise fall back to the
        // existing drop-with-saved-reps prompt unchanged.
        if TindeqSalvagePolicy.shouldSalvage(
            wasIntentional: wasIntentional, wasMeasuring: wasMeasuring, sampleCount: samples.count
        ), let summary = makeSummary() {
            salvageInterruptedRecording(summary)
        } else if !wasIntentional, sessionId != nil, sessionCount > 0 {
            pendingFinish = true
        }
        pushForceBeat()
    }

    /// Salvages the in-flight rep after an unplanned BLE drop mid-hold
    /// (issue #151), mirroring the web app's interruption-salvage
    /// (`useTindeq.ts`/`ForceView.tsx`): saved with the same note text so it
    /// reads identically in History. Claims `samples` immediately so a late
    /// duplicate delegate callback can't double-save, then inserts on the
    /// existing per-connect session group (minting one if this is the first
    /// rep of the connect) just like `ForceGaugeView.saveStop()`. Does NOT
    /// show any new discard/save prompt — `pendingFinish` at the end just
    /// surfaces the existing `GaugeFinishSheet`, same as a manual Finish.
    private func salvageInterruptedRecording(_ summary: StoppedRecording) {
        currentKg = 0
        peakKg = summary.peakKg
        elapsedMs = Double(summary.durationMs)
        samples.removeAll()
        let groupId = ensureSession()
        let tag = liveTag
        let side = liveSide
        Task { @MainActor in
            do {
                try await Repo.insertTindeqRecording(
                    summary,
                    note: "Recovered after connection loss",
                    tag: tag,
                    side: side,
                    groupId: groupId
                )
                sessionCount += 1
            } catch {
                errorMsg = ErrorText.friendly(error)
                if sessionCount == 0 { clearSession() }
            }
            pendingFinish = sessionCount > 0
        }
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
