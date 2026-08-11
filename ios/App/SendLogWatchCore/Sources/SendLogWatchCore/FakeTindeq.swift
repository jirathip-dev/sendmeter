import Foundation

/// The phases used by the simulator's deterministic Progressor waveform.
/// Keeping the phase decision in Core makes the fake useful to host tests and
/// keeps the watch transport from growing a second force-state machine.
public enum FakeTindeqWaveformPhase: String, Equatable, Sendable {
    case rest
    case ramp
    case hold
    case release
}

public struct FakeTindeqWaveformSample: Equatable, Sendable {
    public let elapsedMs: UInt32
    public let kg: Double
    public let phase: FakeTindeqWaveformPhase

    public init(elapsedMs: UInt32, kg: Double, phase: FakeTindeqWaveformPhase) {
        self.elapsedMs = elapsedMs
        self.kg = kg
        self.phase = phase
    }
}

/// Knobs for the simulator pull.  The defaults are long enough for the
/// hands-free 600 ms start window and 1.5 s release grace to be visible, but
/// short enough that a reviewer can exercise a full pull in a few seconds.
public struct FakeTindeqWaveformConfiguration: Equatable, Sendable {
    public var baselineKg: Double
    public var peakKg: Double
    public var rampMs: UInt32
    public var holdMs: UInt32
    public var releaseMs: UInt32
    public var restMs: UInt32
    public var sampleIntervalMs: UInt32
    public var noiseKg: Double
    public var seed: UInt64

    public init(
        baselineKg: Double = 0.35,
        peakKg: Double = 34,
        rampMs: UInt32 = 800,
        holdMs: UInt32 = 1_500,
        releaseMs: UInt32 = 2_500,
        restMs: UInt32 = 1_800,
        sampleIntervalMs: UInt32 = 50,
        noiseKg: Double = 0.08,
        seed: UInt64 = 0x53454E444D455445
    ) {
        self.baselineKg = max(0, baselineKg)
        self.peakKg = max(self.baselineKg, peakKg)
        self.rampMs = max(1, rampMs)
        self.holdMs = max(1, holdMs)
        self.releaseMs = max(1, releaseMs)
        self.restMs = max(1, restMs)
        self.sampleIntervalMs = max(1, sampleIntervalMs)
        self.noiseKg = max(0, noiseKg)
        self.seed = seed
    }

    public static let `default` = FakeTindeqWaveformConfiguration()
}

/// A repeatable ramp → hold → release waveform with deterministic noise.
/// `sample(at:)` is pure and indexed by timestamp, so asking for samples in
/// different batches cannot change the trace. This is deliberate: the app
/// transport can pace the same trace in real time while tests can consume it
/// synchronously.
public struct FakeTindeqWaveform: Equatable, Sendable {
    public let configuration: FakeTindeqWaveformConfiguration

    public init(configuration: FakeTindeqWaveformConfiguration = .default) {
        self.configuration = configuration
    }

    public var rampStartMs: UInt32 { 0 }
    public var holdStartMs: UInt32 { configuration.rampMs }
    public var releaseStartMs: UInt32 { configuration.rampMs + configuration.holdMs }
    public var restStartMs: UInt32 {
        releaseStartMs + configuration.releaseMs
    }
    public var cycleDurationMs: UInt32 {
        restStartMs + configuration.restMs
    }

    public func sample(at elapsedMs: UInt32) -> FakeTindeqWaveformSample {
        let offset = elapsedMs % cycleDurationMs
        let phase: FakeTindeqWaveformPhase
        let progress: Double
        let force: Double

        if offset < holdStartMs {
            phase = .ramp
            progress = Double(offset) / Double(configuration.rampMs)
            force = interpolate(
                from: configuration.baselineKg,
                to: configuration.peakKg,
                progress: progress
            )
        } else if offset < releaseStartMs {
            phase = .hold
            progress = Double(offset - holdStartMs) / Double(configuration.holdMs)
            // A small deterministic sag makes the hold visibly less synthetic
            // without changing the fact that it stays well above the start
            // threshold used by hands-free mode.
            let sag = 0.025 * sin(progress * .pi)
            force = configuration.peakKg * (1 - sag)
        } else if offset < restStartMs {
            phase = .release
            progress = Double(offset - releaseStartMs) / Double(configuration.releaseMs)
            force = interpolate(
                from: configuration.peakKg,
                to: configuration.baselineKg,
                progress: progress
            )
        } else {
            phase = .rest
            progress = 0
            force = configuration.baselineKg
        }

        let sampleIndex = UInt64(elapsedMs / configuration.sampleIntervalMs)
        let noisyForce = max(0, force + deterministicNoise(sampleIndex: sampleIndex))
        return FakeTindeqWaveformSample(elapsedMs: elapsedMs, kg: noisyForce, phase: phase)
    }

    /// Returns an inclusive, fixed-step trace. If `durationMs` is not on a
    /// sample boundary, the final exact timestamp is included as well.
    public func samples(forDurationMs durationMs: UInt32? = nil) -> [FakeTindeqWaveformSample] {
        let duration = durationMs ?? cycleDurationMs
        var result: [FakeTindeqWaveformSample] = []
        result.reserveCapacity(Int(duration / configuration.sampleIntervalMs) + 2)

        var elapsed: UInt32 = 0
        while elapsed <= duration {
            result.append(sample(at: elapsed))
            guard duration - elapsed >= configuration.sampleIntervalMs else { break }
            elapsed += configuration.sampleIntervalMs
        }
        if result.last?.elapsedMs != duration {
            result.append(sample(at: duration))
        }
        return result
    }

    private func interpolate(from: Double, to: Double, progress: Double) -> Double {
        from + (to - from) * min(1, max(0, progress))
    }

    /// SplitMix-style integer mixing gives a stable [-noise, +noise] value
    /// without mutable RNG state. The constants are fixed as part of the fake
    /// contract; changing them intentionally changes screenshot/test traces.
    private func deterministicNoise(sampleIndex: UInt64) -> Double {
        guard configuration.noiseKg > 0 else { return 0 }
        var value = configuration.seed &+ sampleIndex &* 0x9E3779B97F4A7C15
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        let unit = Double(value >> 11) / Double(1 << 53)
        return (unit * 2 - 1) * configuration.noiseKg
    }
}

public enum FakeTindeqScenario: String, Equatable, Sendable {
    case pull
    case midRepDisconnect = "mid-rep-disconnect"
}

/// Script selection belongs in Core so the app transport only schedules
/// samples and forwards a disconnect event; it never decides what a pull is.
public struct FakeTindeqScript: Equatable, Sendable {
    public let scenario: FakeTindeqScenario
    public let waveform: FakeTindeqWaveform

    public init(
        scenario: FakeTindeqScenario = .pull,
        waveform: FakeTindeqWaveform = FakeTindeqWaveform()
    ) {
        self.scenario = scenario
        self.waveform = waveform
    }

    public static let interactive = FakeTindeqScript()
    public static let midRepDisconnect = FakeTindeqScript(scenario: .midRepDisconnect)

    /// Disconnect after the ramp and halfway through the hold, leaving a
    /// genuine in-flight trace for the manager's salvage path.
    public var disconnectAfterMs: UInt32? {
        guard scenario == .midRepDisconnect else { return nil }
        return waveform.holdStartMs + waveform.configuration.holdMs / 2
    }
}
