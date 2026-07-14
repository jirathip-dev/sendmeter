import Foundation

/// Pure readiness math — no HealthKit, unit-testable.
public enum RecoveryEngine {
    public static func compute(
        inputs: DailyHealthInputs,
        acwr: Double?,
        t: RecoveryTunables = .default
    ) -> ReadinessResult {
        let zHRV = zScore(
            value: inputs.hrvSDNNms.map { log($0) },
            baseline: inputs.hrvLnBaseline,
            sigmaFloor: nil, t: t
        )
        let zRHR = zScore(
            value: inputs.restingHR,
            baseline: inputs.rhrBaseline,
            sigmaFloor: nil, t: t
        )
        let zSleep = zScore(
            value: inputs.sleepHours,
            baseline: inputs.sleepBaseline,
            sigmaFloor: t.sleepSigmaFloorH, t: t
        )

        // Without either autonomic signal there is nothing to score.
        guard zHRV != nil || zRHR != nil else {
            return ReadinessResult(score: nil, zone: nil, driver: "Insufficient data")
        }

        let pLoad: Double
        if let acwr, acwr > t.acwrPenaltyStart {
            pLoad = min(1, (acwr - t.acwrPenaltyStart) / (t.acwrPenaltyFull - t.acwrPenaltyStart))
        } else {
            pLoad = 0
        }

        let cHRV = t.wHRV * (zHRV ?? 0)
        let cRHR = -t.wRHR * (zRHR ?? 0)
        let cSleep = t.wSleep * min(zSleep ?? 0, t.sleepPosCapZ)
        let cLoad = -t.loadPenaltyMax * pLoad

        let raw = 50 + cHRV + cRHR + cSleep + cLoad
        let score = max(0, min(100, Int(raw.rounded())))

        let zone: ReadinessZone =
            score < t.zoneRecoverBelow ? .recover
            : score > t.zonePushAbove ? .push
            : .maintain

        return ReadinessResult(
            score: score,
            zone: zone,
            driver: driverLine(cHRV: cHRV, cRHR: cRHR, cSleep: cSleep, cLoad: cLoad)
        )
    }

    /// z-score of today's value vs the baseline, clamped ±zClamp.
    /// nil when the value is missing, history is too short, or σ ≈ 0
    /// (unless a floor is supplied, as for sleep).
    private static func zScore(
        value: Double?,
        baseline: [Double],
        sigmaFloor: Double?,
        t: RecoveryTunables
    ) -> Double? {
        guard let value, baseline.count >= t.minBaselineDays else { return nil }
        let n = Double(baseline.count)
        let mean = baseline.reduce(0, +) / n
        var sigma = (baseline.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n).squareRoot()
        if let sigmaFloor { sigma = max(sigma, sigmaFloor) }
        guard sigma > 1e-6 else { return nil }
        return max(-t.zClamp, min(t.zClamp, (value - mean) / sigma))
    }

    private static func driverLine(cHRV: Double, cRHR: Double, cSleep: Double, cLoad: Double) -> String {
        let terms: [(Double, String)] = [
            (cHRV, cHRV >= 0 ? "HRV well above baseline" : "HRV below baseline"),
            (cRHR, cRHR >= 0 ? "Resting HR low" : "Resting HR elevated"),
            (cSleep, cSleep >= 0 ? "Well slept" : "Short sleep"),
            (cLoad, "High training load"),
        ]
        let dominant = terms.max { abs($0.0) < abs($1.0) }!
        return abs(dominant.0) < 5 ? "Feeling fresh" : dominant.1
    }
}
