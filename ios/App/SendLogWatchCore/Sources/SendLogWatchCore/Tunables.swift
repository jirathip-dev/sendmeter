import Foundation

/// Every detection / effort / RPE constant lives here so a later ML model can
/// replace the math without touching the state machine.
public struct Tunables: Sendable {
    // Fusion
    public var tickHz: Double = 1.0
    public var motionWindowS: Double = 2.0      // RMS window of |userAcceleration| (g)

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
    // #473: HR contributes at most +1 (was +1 for this AND +1 more past
    // startStrongHRRiseBPM=25, so a decaying post-climb HR alone could hit
    // startConfidenceRequired=2 with zero altitude evidence — the phantom
    // re-open). Strong altitude still contributes +2; motion stays the hard
    // candidate gate below.
    // #473: a sustained-motion second confidence point (paired with the HR
    // rise, to restore zero-altitude "traverse" detection) was tried and
    // reverted — measured to open on ordinary walking between boulders with
    // an elevated HR, which shipped code correctly rejected. See
    // AttemptDetector.shouldStartAttempt. HR-only traverse detection is
    // retired as a result; log one with the Boulder/Stop button instead.
    public var startHRRiseBPM: Double = 12.0
    public var startConfidenceRequired: Int = 2 // low altitude + HR, or strong altitude

    // Attempt end
    public var endReturnM: Double = 0.35        // back within local floor + this ...
    public var endReturnTicks: Int = 3          // ... for this many consecutive ticks
    public var quietMotionG: Double = 0.05      // HR-only fallback: motion below this ...
    public var quietTicks: Int = 10             // ... for this many consecutive ticks
    public var establishedAltitudeGainM: Double = 0.4
    public var assistedManualMinS: Double = 12.0
    public var maxAttemptS: Double = 300.0
    // #473: a floor-level (never-established) attempt gets a realistic close
    // path instead of falling through to maxAttemptS's 300s hard cap.
    public var unestablishedMaxS: Double = 60.0
    // #473: an attempt that DID establish altitude but never returns within
    // endReturnM of its startline (real barometric drift over a long hold —
    // whether the climber is standing still or has already walked on) used
    // to run to the full maxAttemptS. Pure duration bound, deliberately not
    // gated on quiet (a walking climber never goes quiet). Must stay
    // comfortably above any legitimate quiet pause mid-climb (see
    // testQuietPauseWhileElevatedDoesNotClose, ~29s).
    public var establishedDriftMaxS: Double = 90.0

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
