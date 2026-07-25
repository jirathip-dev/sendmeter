import Foundation

// KEEP-IN-SYNC: mirrors `ewmaAcwr` in src/lib/metrics.ts:157 — same
// mean-seeded EWMA recurrence, same 7/28-day spans, same nil rules (empty or
// all-zero window → nil). Issue #189: the watch used to compute ACWR with a
// different algorithm (28-day series, seeded at the first day's raw value)
// than the web app (90-day series, mean-seeded), so the two surfaces
// disagreed even when the underlying session data matched exactly. Any
// change to the math on either side must be mirrored on the other or the
// two will silently drift apart again.

/// Exponentially-weighted moving average over a dense (non-null) daily
/// series. `series[0]` is used as the seed (matches metrics.ts's `ewma`,
/// which seeds at the first non-null value) — callers that want the
/// mean-seeded recurrence (like `ewmaAcwr` below) prepend the window mean
/// themselves before calling this.
private func ewma(_ series: [Double], span: Int) -> Double {
    let alpha = 2.0 / (Double(span) + 1.0)
    var v = series[0]
    for x in series.dropFirst() { v = alpha * x + (1 - alpha) * v }
    return v
}

/// Exponentially-weighted acute:chronic ratio (Williams et al. 2016) over a
/// trailing daily-load series — the same algorithm as metrics.ts's
/// `ewmaAcwr`: seed both EWMAs with the window's mean load (not the raw
/// first-day value) to shrink EWMA start-up bias, then take EMA(7) / EMA(28)
/// of `[seed] + dailyLoads`. `nil` when there's no load anywhere in the
/// window (nothing to compute a ratio from) or the chronic EWMA is 0
/// (nothing to divide by).
func ewmaAcwr(dailyLoads: [Double]) -> Double? {
    guard !dailyLoads.isEmpty, dailyLoads.contains(where: { $0 != 0 }) else { return nil }
    let seed = dailyLoads.reduce(0, +) / Double(dailyLoads.count)
    let series = [seed] + dailyLoads
    let acute = ewma(series, span: 7)
    let chronic = ewma(series, span: 28)
    return chronic > 0 ? acute / chronic : nil
}

/// Builds the trailing `days`-day daily-load series (oldest → newest,
/// missing days = 0 load) from raw session-load rows — extracted from
/// `WidgetBridge`'s old inline loop so it's testable without a live
/// Repo/Supabase call. `now` is injectable for tests; defaults to the real
/// clock.
func dailyLoadSeries(rows: [SessionLoadRow], days: Int, now: Date = Date()) -> [Double] {
    let cal = Calendar.gregorianLocal
    var byDate: [String: Double] = [:]
    for r in rows { byDate[r.date, default: 0] += Double(r.load ?? 0) }
    var series: [Double] = []
    for i in stride(from: days - 1, through: 0, by: -1) {
        let d = cal.date(byAdding: .day, value: -i, to: now)!
        series.append(byDate[d.localDateString] ?? 0)
    }
    return series
}
