import Foundation

public struct DailyHealthInputs {
    public var hrvSDNNms: Double?
    public var restingHR: Double?
    public var sleepHours: Double?
    public var bodyMassKg: Double?
    // Folded into the score as of SL-18 (respiratory rate + restorative
    // = deep+REM sleep), each against its own rolling baseline below.
    public var sleepDeepHours: Double?
    public var sleepRemHours: Double?
    public var respRateBpm: Double?
    // Baselines: one value per day over the trailing window.
    public var hrvLnBaseline: [Double]
    public var rhrBaseline: [Double]
    public var sleepBaseline: [Double]
    // SL-18 baselines. Defaulted to [] so callers/tests that predate these
    // (and days with no such history) simply drop the term.
    public var respBaseline: [Double]
    public var restorativeSleepBaseline: [Double]

    public init(
        hrvSDNNms: Double? = nil,
        restingHR: Double? = nil,
        sleepHours: Double? = nil,
        bodyMassKg: Double? = nil,
        sleepDeepHours: Double? = nil,
        sleepRemHours: Double? = nil,
        respRateBpm: Double? = nil,
        hrvLnBaseline: [Double],
        rhrBaseline: [Double],
        sleepBaseline: [Double],
        respBaseline: [Double] = [],
        restorativeSleepBaseline: [Double] = []
    ) {
        self.hrvSDNNms = hrvSDNNms
        self.restingHR = restingHR
        self.sleepHours = sleepHours
        self.bodyMassKg = bodyMassKg
        self.sleepDeepHours = sleepDeepHours
        self.sleepRemHours = sleepRemHours
        self.respRateBpm = respRateBpm
        self.hrvLnBaseline = hrvLnBaseline
        self.rhrBaseline = rhrBaseline
        self.sleepBaseline = sleepBaseline
        self.respBaseline = respBaseline
        self.restorativeSleepBaseline = restorativeSleepBaseline
    }

    /// Deep + REM hours combined (restorative sleep) — nil only when BOTH are
    /// missing, so a device reporting just one stage still contributes.
    public var restorativeSleepHours: Double? {
        if sleepDeepHours == nil && sleepRemHours == nil { return nil }
        return (sleepDeepHours ?? 0) + (sleepRemHours ?? 0)
    }
}

public enum ReadinessZone: String {
    case recover, maintain, push
}

public struct ReadinessResult {
    public let score: Int?          // nil = insufficient data
    public let zone: ReadinessZone?
    public let driver: String

    public init(score: Int?, zone: ReadinessZone?, driver: String) {
        self.score = score
        self.zone = zone
        self.driver = driver
    }
}
