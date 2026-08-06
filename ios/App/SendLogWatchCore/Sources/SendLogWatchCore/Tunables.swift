import Foundation

/// Every detection / effort / RPE constant lives here so a later ML model can
/// replace the math without touching the state machine.
public struct Tunables: Sendable {
    // Fusion
    public var tickHz: Double = 1.0
    public var motionWindowS: Double = 2.0      // RMS window of |userAcceleration| (g)
    // #477: past this age a held HR reading reads as absent (nil), not stale-but-live —
    // applied at the single point every consumer (detector sample, rawTrace, phone/Supabase
    // heartbeat) reads HR from.
    public var hrStaleAfterS: Double = 30.0

    // Baseline altitude (pressure-drift tracking; updated only while resting)
    public var baselineTauS: Double = 60.0
    public var localFloorWindowS: Double = 60.0

    // Attempt start
    public var startWindowS: Double = 45.0
    public var startMotionG: Double = 0.08
    public var startMotionWindowS: Double = 8.0
    public var startMotionTicks: Int = 5
    public var startAltitudeSupportM: Double = 0.45
    public var startStrongAltitudeM: Double = 1.0
    public var startHRRiseBPM: Double = 12.0
    public var startStrongHRRiseBPM: Double = 25.0
    public var startConfidenceRequired: Int = 2 // low altitude + HR, or strong altitude

    // Attempt end
    public var endReturnM: Double = 0.35        // back within local floor + this ...
    public var endReturnTicks: Int = 3          // ... for this many consecutive ticks
    public var quietMotionG: Double = 0.05      // HR-only fallback: motion below this ...
    public var quietTicks: Int = 10             // ... for this many consecutive ticks
    public var establishedAltitudeGainM: Double = 0.4
    public var assistedManualMinS: Double = 12.0
    public var maxAttemptS: Double = 300.0

    // Post-processing
    public var mergeGapS: Double = 15.0
    public var minAttemptS: Double = 8.0
    public var minActiveMotionTicks: Int = 8
    public var hrLagS: Double = 15.0            // extend HR window past attempt end

    // Effort & RPE (simple math v1; swap for ML later)
    public var restHR: Double = 65.0
    public var maxHR: Double = 190.0
    public var effortDurW: Double = 3.0
    public var effortDurCapS: Double = 45.0
    public var effortGainW: Double = 2.0
    public var effortGainCapM: Double = 4.0
    public var effortHRW: Double = 5.0
    public var rpeBase: Double = 1.0
    public var rpeHRRW: Double = 4.5
    public var rpeEffortW: Double = 0.45
    public var rpeDensityW: Double = 0.25

    // RPE ridge model (on-device fit over confirmed workouts)
    public var rpeRidgeLambda: Double = 1.0
    public var rpeMinTrainingSamples: Int = 10
    public var rpeModelMaxAgeS: Double = 86_400

    // Debug
    public var keepRawTrace: Bool = true        // store the trace on climb_workouts.raw
    // Downsample the raw HR/motion trace: keep 1 sample every N ticks (tickHz=1
    // → every 3s). A 2-hour session drops from ~7200 rows to ~2400 — a much
    // smaller upload — while HR still reads smoothly on the phone's chart.
    public var rawTraceStride: Int = 3

    public static let `default` = Tunables()

    public init() {}
}
