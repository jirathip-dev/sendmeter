import Foundation

/// One time/force point from a continuous resisted-movement set trace.
public struct MovementSample: Sendable, Equatable {
    public let tMs: Double
    public let kg: Double

    public init(tMs: Double, kg: Double) {
        self.tMs = tMs
        self.kg = kg
    }
}

/// Optional prescribed force range. Cadence-led movement can omit this while
/// still producing honest completion, mean-force, stability, and drift data.
public struct MovementTargetBand: Sendable, Equatable {
    public let kg: Double
    public let lowKg: Double
    public let highKg: Double

    public init(kg: Double, lowKg: Double, highKg: Double) {
        self.kg = kg
        self.lowKg = lowKg
        self.highKg = highKg
    }
}

/// JSON shape stored in `tindeq_recordings.set_metrics`. Property names match
/// the web app so either client can read a set recorded by the other.
public struct MovementSetMetrics: Sendable, Codable, Equatable {
    public let meanKg: Double?
    public let coefficientVariationPct: Double?
    public let inTargetPct: Double?
    public let timeUnderTensionMs: Int
    public let driftPct: Double?
    public let cadenceAdherencePct: Double

    public init(
        meanKg: Double?,
        coefficientVariationPct: Double?,
        inTargetPct: Double?,
        timeUnderTensionMs: Int,
        driftPct: Double?,
        cadenceAdherencePct: Double
    ) {
        self.meanKg = meanKg
        self.coefficientVariationPct = coefficientVariationPct
        self.inTargetPct = inTargetPct
        self.timeUnderTensionMs = timeUnderTensionMs
        self.driftPct = driftPct
        self.cadenceAdherencePct = cadenceAdherencePct
    }

    private enum CodingKeys: String, CodingKey {
        case meanKg
        case coefficientVariationPct
        case inTargetPct
        case timeUnderTensionMs
        case driftPct
        case cadenceAdherencePct
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if let meanKg { try values.encode(meanKg, forKey: .meanKg) }
        else { try values.encodeNil(forKey: .meanKg) }
        if let coefficientVariationPct {
            try values.encode(coefficientVariationPct, forKey: .coefficientVariationPct)
        } else {
            try values.encodeNil(forKey: .coefficientVariationPct)
        }
        if let inTargetPct { try values.encode(inTargetPct, forKey: .inTargetPct) }
        else { try values.encodeNil(forKey: .inTargetPct) }
        try values.encode(timeUnderTensionMs, forKey: .timeUnderTensionMs)
        if let driftPct { try values.encode(driftPct, forKey: .driftPct) }
        else { try values.encodeNil(forKey: .driftPct) }
        try values.encode(cadenceAdherencePct, forKey: .cadenceAdherencePct)
    }
}

/// Persisted cadence boundary. Database values intentionally remain `out` and
/// `return` for compatibility; the UI presents them as Concentric/Eccentric.
public struct WatchCadenceMarker: Sendable, Codable, Equatable {
    public enum Direction: String, Sendable, Codable, Equatable {
        case out
        case `return`
    }

    public let tMs: Int
    public let rep: Int
    public let direction: Direction

    public init(tMs: Int, rep: Int, direction: Direction) {
        self.tMs = tMs
        self.rep = rep
        self.direction = direction
    }
}

private struct MovementWeightedAccumulator {
    var durationMs = 0.0
    var forceMs = 0.0
    var squareForceMs = 0.0

    mutating func add(kg: Double, durationMs: Double) {
        self.durationMs += durationMs
        forceMs += kg * durationMs
        squareForceMs += kg * kg * durationMs
    }

    var mean: Double? {
        durationMs > 0 ? forceMs / durationMs : nil
    }
}

private func movementRound(_ value: Double, places: Int) -> Double {
    let scale = pow(10.0, Double(places))
    return (value * scale).rounded() / scale
}

/// Time-weighted execution metrics matching `src/lib/reverseAction.ts`.
/// Intervals below 1 kg are treated as unloaded by default. Cadence adherence
/// describes clock coverage only; v1 does not pretend a force sensor measures
/// joint position or range of motion.
public func movementSetMetrics(
    samples: [MovementSample],
    band: MovementTargetBand?,
    plannedDurationMs: Double,
    loadedThresholdKg: Double = 1
) -> MovementSetMetrics {
    let clean = samples
        .filter { $0.tMs.isFinite && $0.kg.isFinite && $0.tMs >= 0 }
        .sorted { $0.tMs < $1.tMs }
    let actualDurationMs = clean.last?.tMs ?? 0
    let durationBasis = plannedDurationMs == 0 ? actualDurationMs : plannedDurationMs
    let comparisonDurationMs = max(1, durationBasis)
    let earlyEnd = comparisonDurationMs * 0.25
    let lateStart = comparisonDurationMs * 0.75

    var total = MovementWeightedAccumulator()
    var early = MovementWeightedAccumulator()
    var late = MovementWeightedAccumulator()
    var inTargetMs = 0.0

    guard clean.count > 1 else {
        return MovementSetMetrics(
            meanKg: nil,
            coefficientVariationPct: nil,
            inTargetPct: nil,
            timeUnderTensionMs: 0,
            driftPct: nil,
            cadenceAdherencePct: movementRound(
                min(1, max(0, actualDurationMs / comparisonDurationMs)) * 100,
                places: 1
            )
        )
    }

    for index in 1..<clean.count {
        let previous = clean[index - 1]
        let current = clean[index]
        let durationMs = current.tMs - previous.tMs
        guard durationMs > 0 else { continue }
        let midpointT = previous.tMs + durationMs / 2
        let midpointKg = (previous.kg + current.kg) / 2
        guard midpointKg >= loadedThresholdKg else { continue }
        total.add(kg: midpointKg, durationMs: durationMs)
        if midpointT <= earlyEnd { early.add(kg: midpointKg, durationMs: durationMs) }
        if midpointT >= lateStart { late.add(kg: midpointKg, durationMs: durationMs) }
        if let band, midpointKg >= band.lowKg, midpointKg <= band.highKg {
            inTargetMs += durationMs
        }
    }

    let mean = total.mean
    let variance = mean.map { max(0, total.squareForceMs / total.durationMs - $0 * $0) }
    let coefficientVariation: Double? = if let mean, mean > 0, let variance {
        movementRound((sqrt(variance) / mean) * 100, places: 1)
    } else {
        nil
    }
    let drift: Double? = if let earlyMean = early.mean, earlyMean > 0, let lateMean = late.mean {
        movementRound(((lateMean - earlyMean) / earlyMean) * 100, places: 1)
    } else {
        nil
    }
    let inTarget: Double? = if band != nil, total.durationMs > 0 {
        movementRound((inTargetMs / total.durationMs) * 100, places: 1)
    } else {
        nil
    }

    return MovementSetMetrics(
        meanKg: mean.map { movementRound($0, places: 2) },
        coefficientVariationPct: coefficientVariation,
        inTargetPct: inTarget,
        timeUnderTensionMs: Int(total.durationMs.rounded()),
        driftPct: drift,
        cadenceAdherencePct: movementRound(
            min(1, max(0, actualDurationMs / comparisonDurationMs)) * 100,
            places: 1
        )
    )
}

public extension WatchForceProtocol {
    /// Expected direction/rep boundaries normalized to the beginning of one
    /// continuously recorded movement set.
    func cadenceMarkers(forSet set: Int) -> [WatchCadenceMarker] {
        let segments = timeline.filter { segment in
            segment.set == set && (segment.phase == .concentric || segment.phase == .eccentric)
        }
        guard let first = segments.first else { return [] }
        return segments.compactMap { segment in
            let direction: WatchCadenceMarker.Direction
            switch segment.phase {
            case .concentric: direction = .out
            case .eccentric: direction = .return
            default: return nil
            }
            return WatchCadenceMarker(
                tMs: Int(((segment.startS - first.startS) * 1_000).rounded()),
                rep: segment.rep,
                direction: direction
            )
        }
    }
}
