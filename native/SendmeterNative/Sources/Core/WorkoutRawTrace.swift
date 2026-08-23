import Foundation

/// One sample of a workout's heart-rate trace — the native counterpart
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
    /// Upper bound on the marks the HR chart emits — the watch writes the
    /// trace at a 3 s stride, so a long session is thousands of samples and
    /// two marks per sample is a visible hitch (F11). Runs are decimated
    /// uniformly to keep the total under this.
    public static let maxChartPoints = 600

    /// Parse the `climb_workouts.raw` trace —
    /// `[[t_s, alt_m, motion_rms, hr], ...]` — into the HR series the charts
    /// draw, with the same shape the web uses (`{t, hr}`).
    ///
    /// The web maps entries verbatim (`t = s[0]`, `hr = s[3] ?? null`); the
    /// native side is defensively clean because the DB can hold older or
    /// noisier rows:
    /// - entries with fewer than 4 elements are dropped (the web reads
    ///   `s[0]`/`s[3]` and would trap on them);
    /// - `t` must be finite and ≥ 0, else the entry is dropped;
    /// - a null `hr` stays null (sensor gap — the chart breaks its line).
    /// Unlike an earlier draft, there is NO plausibility clamp on `hr`: a
    /// genuine low/high reading (a fit athlete's deep-rest 28 bpm) is kept
    /// verbatim like the web, so the two platforms draw the same chart for
    /// identical data (#645 review F9). Only a non-finite `hr` is nulled —
    /// jsonb cannot hold NaN/Infinity, so this is purely defensive.
    /// Extra elements beyond the fourth are ignored, matching the web.
    public static func hrSeries(_ raw: [[Double?]]?) -> [WorkoutHrSample] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.compactMap { entry in
            guard entry.count >= 4,
                  let t = entry[0], t.isFinite, t >= 0
            else { return nil }
            guard let hr = entry[3], hr.isFinite else {
                return WorkoutHrSample(t: t, hr: nil)
            }
            return WorkoutHrSample(t: t, hr: hr)
        }
    }

    /// Split a series into contiguous non-nil-HR runs — the unit the chart
    /// draws (web `WorkoutHrChart.tsx`'s run loop). A nil `hr` means the
    /// sensor lagged; drawing across it would invent data. Every run keeps
    /// its own identity so the chart can render each as a separate series.
    /// Single-sample runs are included — the chart skips those (< 2 points).
    public static func hrRuns(_ samples: [WorkoutHrSample]) -> [[WorkoutHrSample]] {
        var result: [[WorkoutHrSample]] = []
        var current: [WorkoutHrSample] = []
        for sample in samples {
            if sample.hr == nil {
                if !current.isEmpty {
                    result.append(current)
                    current = []
                }
            } else {
                current.append(sample)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Decimate a run uniformly to at most `maxPoints`, always keeping the
    /// first and last sample. Used to bound the Swift Charts mark count
    /// (F11); the decimation preserves each run's boundaries, so a sensor
    /// gap is never bridged by dropping the nil that separates two runs.
    public static func downsample(
        _ samples: [WorkoutHrSample],
        maxPoints: Int
    ) -> [WorkoutHrSample] {
        guard samples.count > maxPoints, maxPoints > 0 else { return samples }
        let step = Double(samples.count - 1) / Double(maxPoints - 1)
        var result: [WorkoutHrSample] = []
        result.reserveCapacity(maxPoints)
        var index = 0.0
        while result.count < maxPoints {
            result.append(samples[Int(index.rounded())])
            index += step
        }
        return result
    }

    /// Split + bound a trace for rendering: `hrRuns`, dropping single-sample
    /// runs (a line needs ≥ 2 points), then decimate each run to a
    /// proportional share of `maxPoints` total (at least 2 per run, so a
    /// run never collapses). The sum is ≤ `maxPoints` whenever the run count
    /// allows — only a pathological trace with more 2-point runs than
    /// `maxPoints / 2` exceeds it, and no decimation can fix that.
    public static func downsampleRuns(
        _ samples: [WorkoutHrSample],
        maxPoints: Int
    ) -> [[WorkoutHrSample]] {
        let runs = hrRuns(samples).filter { $0.count >= 2 }
        guard maxPoints > 0, !runs.isEmpty else { return runs }
        let total = runs.reduce(0) { $0 + $1.count }
        guard total > maxPoints else { return runs }
        let scale = Double(maxPoints) / Double(total)
        var budgets = runs.map { run in
            max(2, Int((Double(run.count) * scale).rounded()))
        }
        var sum = budgets.reduce(0, +)
        while sum > maxPoints {
            guard let index = budgets.indices.max(by: { budgets[$0] < budgets[$1] }),
                  budgets[index] > 2
            else { break }
            budgets[index] -= 1
            sum -= 1
        }
        return zip(runs, budgets).map { downsample($0, maxPoints: $1) }
    }

    /// The nearest actual HR sample for a scrubbed position, but only when
    /// that position is inside a rendered run's span (#755). A sensor gap
    /// between runs therefore returns nil instead of borrowing a reading from
    /// the other side of the gap; a long run still uses a real measured value
    /// rather than interpolating one.
    public static func selectedSample(
        at t: Double,
        inRuns runs: [[WorkoutHrSample]]
    ) -> WorkoutHrSample? {
        guard t.isFinite else { return nil }
        var nearest: WorkoutHrSample?
        var nearestDistance = Double.infinity
        for run in runs {
            guard let first = run.first, let last = run.last else { continue }
            let runLow = min(first.t, last.t)
            let runHigh = max(first.t, last.t)
            guard t >= runLow, t <= runHigh else { continue }
            for sample in run where sample.hr != nil {
                let distance = abs(sample.t - t)
                if distance < nearestDistance {
                    nearest = sample
                    nearestDistance = distance
                }
            }
        }
        return nearest
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
    /// One attempt placed on the workout timeline, in trace seconds (web
    /// `AttemptWindow`).
    public struct AttemptWindow: Equatable, Sendable {
        public let start: Double
        public let end: Double
        public let manual: Bool

        public init(start: Double, end: Double, manual: Bool) {
            self.start = start
            self.end = end
            self.manual = manual
        }
    }

    /// Attempt start/end in seconds from the workout start (web
    /// `attemptWindows`).
    public static func attemptWindows(
        startedAt: Date,
        attempts: [WorkoutAttempt]
    ) -> [AttemptWindow] {
        attempts.map { attempt in
            let start = attempt.startedAt.timeIntervalSince(startedAt)
            return AttemptWindow(
                start: start,
                end: start + Double(attempt.durationSeconds),
                manual: attempt.source == "manual"
            )
        }
    }

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
        let attemptEnd = attemptWindows(startedAt: startedAt, attempts: attempts)
            .reduce(0) { currentMax, window in
                max(currentMax, window.end)
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
    /// first, so a tick at 119.6 s reads "2:00" — the web side was aligned to
    /// this behaviour (#645 review F15), so both platforms format the same
    /// axis identically.
    public static func fmtMinSec(_ tS: Double) -> String {
        let total = Int(tS.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
