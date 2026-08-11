#if DEBUG && targetEnvironment(simulator)

import Foundation
import SendLogWatchCore

/// Launch-time opt-in for the simulator-only Progressor transport. The
/// `DEBUG` + simulator compilation gate is intentional: release/device builds
/// do not contain a path that can manufacture force samples.
enum FakeTindeqLaunchConfiguration {
    static func script() -> FakeTindeqScript? {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-sendmeter-fake-tindeq") {
            let value = arguments.indices.contains(index + 1)
                ? arguments[index + 1]
                : "pull"
            return script(for: value)
        }
        if arguments.contains("-sendmeter-fake-tindeq-mid-rep-disconnect") {
            return .midRepDisconnect
        }
        guard let value = ProcessInfo.processInfo.environment["SENDMETER_FAKE_TINDEQ"] else {
            return nil
        }
        return script(for: value)
    }

    private static func script(for rawValue: String) -> FakeTindeqScript? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on", "pull", "normal":
            return .interactive
        case "disconnect", "mid-rep", "mid-rep-disconnect", "salvage":
            return .midRepDisconnect
        default:
            // An explicit but unknown value is safer than silently enabling a
            // fake device with a script the reviewer did not ask for.
            return nil
        }
    }
}

/// Main-thread transport that behaves like a Progressor at the manager's
/// notification boundary. It sends real Tindeq weight frames, so the manager
/// still parses them and runs the same recording, guided, hands-free, and
/// disconnect-salvage paths as CoreBluetooth.
final class FakeTindeqTransport {
    let script: FakeTindeqScript
    private(set) var connected = false

    var onConnect: (() -> Void)?
    var onNotification: ((Data) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    private var timer: Timer?
    private var elapsedMs: UInt32 = 0
    private var connectionGeneration: UInt64 = 0
    private var streamGeneration: UInt64 = 0

    init(script: FakeTindeqScript) {
        self.script = script
    }

    deinit {
        timer?.invalidate()
    }

    func connect() {
        guard !connected else { return }
        connectionGeneration &+= 1
        let generation = connectionGeneration
        connected = true
        // CoreBluetooth reports didConnect asynchronously. Mirroring that
        // ordering prevents a synchronous first fake sample from racing the
        // manager's connected state.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.connected,
                  self.connectionGeneration == generation
            else { return }
            self.onConnect?()
        }
    }

    /// Intentional teardown is silent; `TindeqManager.disconnect()` already
    /// owns the no-salvage cleanup. Unplanned drops use
    /// `simulateUnplannedDisconnect()` below and do invoke the manager's real
    /// disconnect handler.
    func disconnect() {
        connectionGeneration &+= 1
        connected = false
        stopStream()
    }

    func write(_ command: Tindeq.Cmd) {
        guard connected else { return }
        switch command {
        case .startWeight:
            startStream()
        case .stop:
            stopStream()
        case .tare, .sampleBattery:
            break
        }
    }

    private func startStream() {
        stopStream()
        streamGeneration &+= 1
        let generation = streamGeneration
        elapsedMs = 0
        let interval = TimeInterval(script.waveform.configuration.sampleIntervalMs) / 1000
        let next = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.emitSample(streamGeneration: generation)
        }
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }

    private func stopStream() {
        streamGeneration &+= 1
        timer?.invalidate()
        timer = nil
    }

    private func emitSample(streamGeneration: UInt64) {
        guard connected, self.streamGeneration == streamGeneration else { return }
        let sample = script.waveform.sample(at: elapsedMs)
        onNotification?(Self.weightFrame(for: sample))

        // A notification can cause the manager to stop the stream (hands-free
        // release) while this callback is running. Do not continue the script,
        // manufacture a disconnect, or advance elapsed time after that
        // synchronous stop.
        guard connected, self.streamGeneration == streamGeneration else { return }
        if let disconnectAt = script.disconnectAfterMs, elapsedMs >= disconnectAt {
            simulateUnplannedDisconnect()
            return
        }
        elapsedMs &+= script.waveform.configuration.sampleIntervalMs
    }

    private func simulateUnplannedDisconnect() {
        guard connected else { return }
        connectionGeneration &+= 1
        connected = false
        stopStream()
        let error = NSError(
            domain: "FakeTindeqTransport",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Simulated Progressor disconnect"]
        )
        onDisconnect?(error)
    }

    private static func weightFrame(for sample: FakeTindeqWaveformSample) -> Data {
        var data = Data([0x01, 0x08])
        var kg = Float(sample.kg).bitPattern.littleEndian
        var us = (sample.elapsedMs &* 1_000).littleEndian
        withUnsafeBytes(of: &kg) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &us) { data.append(contentsOf: $0) }
        return data
    }
}

#endif
