import Foundation

/// Every detection / effort / RPE constant lives here so a later ML model can
/// replace the math without touching the state machine.
struct Tunables {
    // Fusion
    var tickHz: Double = 1.0
    var motionWindowS: Double = 2.0      // RMS window of |userAcceleration| (g)

    // Baseline altitude (pressure-drift tracking; updated only while resting)
    var baselineTauS: Double = 60.0

    // Attempt start
    var startGainM: Double = 1.5         // altitude - baseline within trailing window
    var startWindowS: Double = 10.0
    var startMotionG: Double = 0.08
    var startMotionTicks: Int = 3        // of the last 5 ticks

    // Attempt end
    var endReturnM: Double = 1.0         // back within baseline + this ...
    var endReturnTicks: Int = 3          // ... for this many consecutive ticks
    var quietMotionG: Double = 0.05      // OR motion below this ...
    var quietTicks: Int = 10             // ... for this many consecutive ticks
    var maxAttemptS: Double = 300.0

    // Post-processing
    var mergeGapS: Double = 15.0
    var minAttemptS: Double = 8.0
    var minGainM: Double = 1.2
    var hrLagS: Double = 15.0            // extend HR window past attempt end

    // Effort & RPE (simple math v1; swap for ML later)
    var restHR: Double = 65.0
    var maxHR: Double = 190.0
    var effortDurW: Double = 3.0
    var effortDurCapS: Double = 45.0
    var effortGainW: Double = 2.0
    var effortGainCapM: Double = 4.0
    var effortHRW: Double = 5.0
    var rpeBase: Double = 1.0
    var rpeHRRW: Double = 4.5
    var rpeEffortW: Double = 0.45
    var rpeDensityW: Double = 0.25

    // RPE ridge model (on-device fit over confirmed workouts)
    var rpeRidgeLambda: Double = 1.0
    var rpeMinTrainingSamples: Int = 10
    var rpeModelMaxAgeS: Double = 86_400

    // Debug
    var keepRawTrace: Bool = true        // store the trace on climb_workouts.raw
    // Downsample the raw HR/motion trace: keep 1 sample every N ticks (tickHz=1
    // → every 3s). A 2-hour session drops from ~7200 rows to ~2400 — a much
    // smaller upload — while HR still reads smoothly on the phone's chart.
    var rawTraceStride: Int = 3

    static let `default` = Tunables()
}
