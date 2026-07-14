import Foundation

public struct DailyHealthInputs {
    public var hrvSDNNms: Double?
    public var restingHR: Double?
    public var sleepHours: Double?
    public var bodyMassKg: Double?
    // Additive metrics: stored and displayed, not yet folded into the
    // readiness score (no baseline computed yet — see RecoveryStatsCard on
    // web). Defaulted so existing call sites (tests) don't need updating.
    public var sleepDeepHours: Double?
    public var sleepRemHours: Double?
    public var respRateBpm: Double?
    // Baselines: one value per day over the trailing window.
    public var hrvLnBaseline: [Double]
    public var rhrBaseline: [Double]
    public var sleepBaseline: [Double]

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
        sleepBaseline: [Double]
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
