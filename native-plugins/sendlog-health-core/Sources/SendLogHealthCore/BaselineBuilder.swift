import Foundation

/// One night's raw aggregates as read from HealthKit — pure data, no queries.
/// Mirrors the reader's per-night fetch (night-window HRV/sleep/resp, full
/// local-day RHR); nil = the store had no samples for that metric that night.
public struct NightSample {
    public var hrv: Double?
    public var rhr: Double?
    public var sleepTotal: Double?
    public var sleepDeep: Double?
    public var sleepRem: Double?
    public var resp: Double?

    public init(
        hrv: Double? = nil,
        rhr: Double? = nil,
        sleepTotal: Double? = nil,
        sleepDeep: Double? = nil,
        sleepRem: Double? = nil,
        resp: Double? = nil
    ) {
        self.hrv = hrv
        self.rhr = rhr
        self.sleepTotal = sleepTotal
        self.sleepDeep = sleepDeep
        self.sleepRem = sleepRem
        self.resp = resp
    }
}

/// Builds the five readiness baselines from per-night samples (#111).
///
/// The per-night usability rules are moved verbatim from the reader loops
/// (previously duplicated between `readToday` and `readHistory`). Each
/// baseline keeps only the **newest `baselineDays` usable** nights, so with a
/// healthy trailing window the output is identical to the old fixed-window
/// loops — and an extended scan past a wearable-data gap never inflates a
/// baseline beyond its normal size.
public enum BaselineBuilder {
    public struct Result {
        public let hrvLnBaseline: [Double]
        public let rhrBaseline: [Double]
        public let sleepBaseline: [Double]
        public let respBaseline: [Double]
        public let restorativeSleepBaseline: [Double]
        /// True when BOTH autonomic baselines (HRV and RHR) are under
        /// `minBaselineDays` — deliberately mirrors the engine's OR-guard:
        /// one autonomic z-term suffices to score, so a permanently absent
        /// secondary metric (e.g. no respiratory rate from a Garmin) must
        /// NOT trigger the extended lookback.
        public let isAutonomicStarved: Bool
    }

    /// `nights` is ordered newest→oldest: `nights[0]` = 1 day before the
    /// scored day.
    public static func build(nights: [NightSample], t: RecoveryTunables = .default) -> Result {
        var hrvBase: [Double] = []
        var rhrBase: [Double] = []
        var sleepBase: [Double] = []
        var respBase: [Double] = []
        var restBase: [Double] = []
        for n in nights {
            if hrvBase.count < t.baselineDays, let h = n.hrv, h > 0 {
                hrvBase.append(log(h))
            }
            if rhrBase.count < t.baselineDays, let r = n.rhr {
                rhrBase.append(r)
            }
            if sleepBase.count < t.baselineDays, let s = n.sleepTotal, s > 0 {
                sleepBase.append(s)
            }
            if respBase.count < t.baselineDays, let rp = n.resp, rp > 0 {
                respBase.append(rp)
            }
            let rest = (n.sleepDeep ?? 0) + (n.sleepRem ?? 0)
            if restBase.count < t.baselineDays, rest > 0 {
                restBase.append(rest)
            }
        }
        return Result(
            hrvLnBaseline: hrvBase,
            rhrBaseline: rhrBase,
            sleepBaseline: sleepBase,
            respBaseline: respBase,
            restorativeSleepBaseline: restBase,
            isAutonomicStarved: hrvBase.count < t.minBaselineDays
                && rhrBase.count < t.minBaselineDays
        )
    }
}
