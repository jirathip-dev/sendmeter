import Foundation

/// One sample of a workout's 1 Hz heart-rate trace — the native counterpart
/// of the web's `WorkoutHrSample` (`{t, hr}`): `t` is seconds since the
/// workout started, `hr` is nil where the sensor lagged (a gap, not a zero).
public struct WorkoutHrSample: Codable, Equatable, Sendable {
    public let t: Double
    public let hr: Double?

    public init(t: Double, hr: Double?) {
        self.t = t
        self.hr = hr
    }
}

/// Parsing + chart-axis math for the workout HR trace (#645). Pure, so the
/// raw→series shaping is unit-testable without a backend. Web counterparts:
/// `fetchWorkoutRaw` in `src/lib/repo/workouts.ts` and the axis helpers in
/// `src/lib/workoutChartAxis.ts`.
public enum WorkoutRawTrace {
    /// A plausible resting-to-max HR range for the clamp. Anything outside is
    /// a sensor artifact and becomes a gap, the same way the web keeps
    /// `hr === null` samples — the chart splits its line at them rather than
    /// inventing data.
    public static let plausibleHeartRate = 30.0...250.0

    /// Parse the `climb_workouts.raw` 1 Hz trace —
    /// `[[t_s, alt_m, motion_rms, hr], ...]` — into the HR series the charts
    /// draw, with the same shape the web uses (`{t, hr}`).
    ///
    /// The web maps entries verbatim (`t = s[0]`, `hr = s[3] ?? null`); the
    /// native side is defensively clean because the DB can hold older or
    /// noisier rows:
    /// - entries with fewer than 4 elements are dropped (the web reads
    ///   `s[0]`/`s[3]` and would trap on them);
    /// - `t` must be finite and ≥ 0, else the entry is dropped;
    /// - a null `hr` stays null (sensor gap — the chart breaks its line);
    /// - a non-finite or out-of-`plausibleHeartRate` `hr` also becomes null.
    /// Extra elements beyond the fourth are ignored, matching the web.
    public static func hrSeries(_ raw: [[Double?]]?) -> [WorkoutHrSample] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.compactMap { entry in
            guard entry.count >= 4,
                  let t = entry[0], t.isFinite, t >= 0
            else { return nil }
            guard let hr = entry[3], hr.isFinite, plausibleHeartRate.contains(hr) else {
                return WorkoutHrSample(t: t, hr: nil)
            }
            return WorkoutHrSample(t: t, hr: hr)
        }
    }

    /// Whether a series has enough valid samples for the HR chart — the web's
    /// `< 2` guard (a line needs at least two points; the chart renders
    /// nothing below that).
    public static func isChartRenderable(_ samples: [WorkoutHrSample]) -> Bool {
        var valid = 0
        for sample in samples {
            if sample.hr != nil {
                valid += 1
                if valid >= 2 { return true }
            }
        }
        return false
    }
}

/// Shared x-axis maths for the workout-detail charts (web
/// `src/lib/workoutChartAxis.ts`): every chart in the stack plots the same
/// seconds-since-workout-start domain, or a given x reads as a different
/// instant in each.
public enum WorkoutChartAxis {
    /// The shared x domain, [0, tMax], in seconds from the workout start.
    /// Driven by the *data* — the end of the HR trace and the last attempt —
    /// rather than by `endedAt`, so a workout left running long after the last
    /// climb doesn't squash the trace into a sliver. `endedAt` is only the
    /// fallback when there is neither a trace nor an attempt. Always ≥ 1 so
    /// the scale never collapses to a zero-width domain (web
    /// `workoutTimeMaxS`).
    public static func timeMaxS(
        startedAt: Date,
        endedAt: Date,
        attempts: [WorkoutAttempt],
        samples: [WorkoutHrSample]
    ) -> Double {
        let traceEnd = samples.last?.t ?? 0
        let attemptEnd = attempts.reduce(0) { currentMax, attempt in
            let start = attempt.startedAt.timeIntervalSince(startedAt)
            return max(currentMax, start + Double(attempt.durationSeconds))
        }
        let dataEnd = max(traceEnd, attemptEnd)
        if dataEnd > 0 { return dataEnd }
        return max(1, endedAt.timeIntervalSince(startedAt))
    }

    /// Tick positions along the shared time axis (web `workoutXTicks`).
    public static func xTicks(tMax: Double) -> [Double] {
        [0, tMax / 2, tMax]
    }

    /// m:ss for an axis label (web `fmtMinSec`). Rounds the total seconds
    /// first, so a tick at 119.6 s reads "2:00" rather than the web's "0:60"
    /// (floor-minute + rounded-second remainder).
    public static func fmtMinSec(_ tS: Double) -> String {
        let total = Int(tS.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
