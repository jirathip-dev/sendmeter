import Foundation

/// Per-workout summary stats (#645) — pure and testable. Native counterpart
/// of the web's `src/lib/workoutStats.ts`.
public enum WorkoutStats {
    /// Mean HR recovery after attempts: HR at the attempt's end minus the
    /// LOWEST HR reached within the next `windowS` seconds — how fast the
    /// heart comes down between climbs (web `hrRecoveryBpm`). Trace `t` is
    /// seconds from workout start.
    ///
    /// `hrAtOrAfter(t)` scans for the FIRST sample with `s.t >= t && s.t <=
    /// t + 10` (the web's 10-second grace window — not the nearest sample),
    /// then the min HR in `(endT, endT + windowS]`. Only positive drops are
    /// averaged; nil when no attempt yields one.
    public static func hrRecoveryBpm(
        trace: [WorkoutHrSample],
        startedAt: Date,
        attempts: [WorkoutAttempt],
        windowS: Double = 60
    ) -> Double? {
        func hrAtOrAfter(_ t: Double) -> Double? {
            for sample in trace {
                if sample.t >= t, sample.t <= t + 10, let hr = sample.hr {
                    return hr
                }
            }
            return nil
        }

        var drops: [Double] = []
        for attempt in attempts {
            let endT = attempt.startedAt.timeIntervalSince(startedAt)
                + Double(attempt.durationSeconds)
            guard let hrEnd = hrAtOrAfter(endT) else { continue }
            var low: Double?
            for sample in trace {
                if sample.t > endT, sample.t <= endT + windowS, let hr = sample.hr {
                    low = min(low ?? hr, hr)
                }
            }
            if let low, hrEnd - low > 0 {
                drops.append(hrEnd - low)
            }
        }
        return drops.isEmpty ? nil : drops.reduce(0, +) / Double(drops.count)
    }
}
