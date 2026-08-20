import Foundation

public struct ForceCurvePoint: Codable, Equatable, Sendable {
    public let windowSeconds: Double
    public let kilograms: Double

    public init(windowSeconds: Double, kilograms: Double) {
        self.windowSeconds = windowSeconds
        self.kilograms = kilograms
    }
}

public struct ForceCurveConfidencePoint: Codable, Equatable, Sendable {
    public let windowSeconds: Double
    public let kilograms: Double
    public let lowKilograms: Double
    public let highKilograms: Double

    public init(
        windowSeconds: Double,
        kilograms: Double,
        lowKilograms: Double,
        highKilograms: Double
    ) {
        self.windowSeconds = windowSeconds
        self.kilograms = kilograms
        self.lowKilograms = lowKilograms
        self.highKilograms = highKilograms
    }
}

/// One result from the concurrent recording-sample fetch used by AppModel.
/// The candidate index is retained because TaskGroup completion order is not
/// an input-order contract, while the deterministic bootstrap is index-based.
public struct ForceCurveSampleFetch: Equatable, Sendable {
    public let candidateIndex: Int
    public let samples: [TindeqSample]?

    public init(candidateIndex: Int, samples: [TindeqSample]?) {
        self.candidateIndex = candidateIndex
        self.samples = samples
    }
}

public struct ForceCapabilityFit: Codable, Equatable, Sendable {
    public let criticalForceKilograms: Double
    public let maximumForceKilograms: Double
    public let tau: Double
    public let exponent: Double
    public let sumSquaredError: Double

    public init(
        criticalForceKilograms: Double,
        maximumForceKilograms: Double,
        tau: Double,
        exponent: Double,
        sumSquaredError: Double
    ) {
        self.criticalForceKilograms = criticalForceKilograms
        self.maximumForceKilograms = maximumForceKilograms
        self.tau = tau
        self.exponent = exponent
        self.sumSquaredError = sumSquaredError
    }
}

public struct ForceCurveModel: Codable, Equatable, Sendable {
    public let points: [ForceCurvePoint]
    public let maximumForceKilograms: Double
    public let criticalForceKilograms: Double?
    public let impulseAboveCriticalForceKilogramSeconds: Double?
    public let capabilityFit: ForceCapabilityFit?
    public let confidenceBand: [ForceCurveConfidencePoint]?

    public init(
        points: [ForceCurvePoint],
        maximumForceKilograms: Double,
        criticalForceKilograms: Double?,
        impulseAboveCriticalForceKilogramSeconds: Double?,
        capabilityFit: ForceCapabilityFit?,
        confidenceBand: [ForceCurveConfidencePoint]? = nil
    ) {
        self.points = points
        self.maximumForceKilograms = maximumForceKilograms
        self.criticalForceKilograms = criticalForceKilograms
        self.impulseAboveCriticalForceKilogramSeconds = impulseAboveCriticalForceKilogramSeconds
        self.capabilityFit = capabilityFit
        self.confidenceBand = confidenceBand
    }
}

public struct ForceReferences: Codable, Equatable, Sendable {
    public let personalRecordKilograms: Double?
    public let criticalForceKilograms: Double?
    public let impulseAboveCriticalForceKilogramSeconds: Double?
    public let maximumForceKilograms: Double?
    public let capabilityFit: ForceCapabilityFit?

    public init(
        personalRecordKilograms: Double?,
        criticalForceKilograms: Double?,
        impulseAboveCriticalForceKilogramSeconds: Double?,
        maximumForceKilograms: Double?,
        capabilityFit: ForceCapabilityFit?
    ) {
        self.personalRecordKilograms = personalRecordKilograms
        self.criticalForceKilograms = criticalForceKilograms
        self.impulseAboveCriticalForceKilogramSeconds = impulseAboveCriticalForceKilogramSeconds
        self.maximumForceKilograms = maximumForceKilograms
        self.capabilityFit = capabilityFit
    }

    public static let empty = ForceReferences(
        personalRecordKilograms: nil,
        criticalForceKilograms: nil,
        impulseAboveCriticalForceKilogramSeconds: nil,
        maximumForceKilograms: nil,
        capabilityFit: nil
    )
}

public struct ForceTargetBand: Codable, Equatable, Sendable {
    public let kilograms: Double
    public let lowKilograms: Double
    public let highKilograms: Double

    public init(kilograms: Double, lowKilograms: Double, highKilograms: Double) {
        self.kilograms = kilograms
        self.lowKilograms = lowKilograms
        self.highKilograms = highKilograms
    }

    public var range: ClosedRange<Double> { lowKilograms...highKilograms }
}

public struct ForceTargetKey: Hashable, Codable, Sendable {
    public let setNumber: Int
    public let side: TindeqSide

    public init(setNumber: Int, side: TindeqSide) {
        self.setNumber = setNumber
        self.side = side
    }
}

public struct ForceTargetPlan: Codable, Equatable, Sendable {
    public let targets: [ForceTargetKey: ForceTargetBand]

    public init(targets: [ForceTargetKey: ForceTargetBand] = [:]) {
        self.targets = targets
    }

    public func band(forSet setNumber: Int, side: TindeqSide) -> ForceTargetBand? {
        targets[ForceTargetKey(setNumber: setNumber, side: side)]
            ?? targets[ForceTargetKey(setNumber: setNumber, side: .unspecified)]
    }

    public static let empty = ForceTargetPlan()
}

public enum ForceCurveEngine {
    public static let windowsSeconds: [Double] = [1, 3, 5, 7, 10, 15, 20, 30, 45, 60, 90, 120]
    private static let resampleHertz = 10.0
    private static let fitMinimumWindowSeconds = 10.0
    private static let fitMinimumDistinctWindows = 3
    private static let displayBandWindowsSeconds: [Double] = (0...64).map { index in
        if index == 0 { return 1 }
        if index == 64 { return 120 }
        return exp(log(120) * Double(index) / 64)
    }
    /// The fixed LCG seed shared with `src/lib/force-curve.ts`.
    public static let bootstrapSeed: UInt32 = 0x0352c0de
    private static let pickWindowDays = 90.0
    private static let pickPerBucket = 3
    private static let pickLongest = 3
    private static let pickBucketEdgesSeconds: [Double] = [5, 10, 20, 45, 90]

    /// Mean-max force using the same 10 Hz step-resampling contract as the
    /// TypeScript client. Prefix sums keep every candidate window O(n).
    public static func meanMaxForce(
        samples: [TindeqSample],
        windowSeconds: Double
    ) -> Double? {
        let grid = resample(samples)
        let count = Int((windowSeconds * resampleHertz).rounded())
        guard count >= 1, grid.count >= count else { return nil }

        var prefix = Array(repeating: 0.0, count: grid.count + 1)
        for index in grid.indices {
            prefix[index + 1] = prefix[index] + grid[index]
        }

        var best = -Double.infinity
        for index in 0...(grid.count - count) {
            best = max(best, (prefix[index + count] - prefix[index]) / Double(count))
        }
        return best.isFinite ? best : nil
    }

    /// Rebuild sample sets in candidate order after a concurrent fetch.
    /// Missing/empty results are omitted, but successful results never inherit
    /// the completion order of the task group that produced them.
    public static func orderedSampleSets(
        candidateCount: Int,
        completed: [ForceCurveSampleFetch]
    ) -> [[TindeqSample]] {
        guard candidateCount > 0 else { return [] }
        var byCandidate = Array<[TindeqSample]?>(repeating: nil, count: candidateCount)
        for result in completed where byCandidate.indices.contains(result.candidateIndex) {
            guard let samples = result.samples, !samples.isEmpty else { continue }
            byCandidate[result.candidateIndex] = samples
        }
        return byCandidate.compactMap { $0 }
    }

    public static func compute(
        recordings: [[TindeqSample]],
        fitDepth: Int = 3,
        bootstrapSamples: Int = 200,
        seed: UInt32 = bootstrapSeed
    ) -> ForceCurveModel? {
        let prepared = recordings.map { samples in
            PreparedEffort(
                values: windowsSeconds.map { meanMaxForce(samples: samples, windowSeconds: $0) },
                durationMilliseconds: samples.last?.milliseconds ?? 0
            )
        }
        guard let model = computeCore(efforts: prepared, fitDepth: fitDepth) else { return nil }

        // KEEP-IN-SYNC with src/lib/force-curve.ts: the point estimate above
        // is computed once from the full data. The fixed-seed, recording-level
        // bootstrap below only supplies the display uncertainty band; it must
        // never change CF, W′, or the Hill fit used for targets/RPE.
        guard model.capabilityFit != nil,
              recordings.count >= 3,
              bootstrapSamples > 0
        else { return model }

        let firstWindow = model.points[0].windowSeconds
        let lastWindow = model.points[model.points.count - 1].windowSeconds
        let bandWindows = displayBandWindowsSeconds.filter {
            $0 >= firstWindow && $0 <= lastWindow
        }
        var predictions = Array(repeating: [Double](), count: bandWindows.count)
        var randomState = seed

        for _ in 0..<bootstrapSamples {
            var sample: [PreparedEffort] = []
            sample.reserveCapacity(prepared.count)
            for _ in prepared.indices {
                // JavaScript's `Math.imul(... ) >>> 0` is a wrapping UInt32
                // multiply/add. Dividing by 2^32 preserves the web's [0, 1)
                // LCG draw and therefore the exact resample sequence.
                randomState = randomState &* 1_664_525 &+ 1_013_904_223
                let random = Double(randomState) / 4_294_967_296
                let index = min(prepared.count - 1, Int(random * Double(prepared.count)))
                sample.append(prepared[index])
            }
            guard let fitted = computeCore(efforts: sample, fitDepth: fitDepth),
                  let capabilityFit = fitted.capabilityFit
            else { continue }
            for (index, windowSeconds) in bandWindows.enumerated() {
                predictions[index].append(
                    predictCapabilityFit(capabilityFit, seconds: windowSeconds)
                )
            }
        }

        let minimumPredictions = max(20.0, Double(bootstrapSamples) * 0.2)
        var confidenceBand: [ForceCurveConfidencePoint] = []
        confidenceBand.reserveCapacity(bandWindows.count)
        for (index, windowSeconds) in bandWindows.enumerated() {
            var values = predictions[index]
            guard Double(values.count) >= minimumPredictions else { continue }
            values.sort()
            confidenceBand.append(
                ForceCurveConfidencePoint(
                    windowSeconds: windowSeconds,
                    kilograms: predictCapabilityFit(model.capabilityFit!, seconds: windowSeconds),
                    lowKilograms: percentile(values, p: 0.025),
                    highKilograms: percentile(values, p: 0.975)
                )
            )
        }

        return ForceCurveModel(
            points: model.points,
            maximumForceKilograms: model.maximumForceKilograms,
            criticalForceKilograms: model.criticalForceKilograms,
            impulseAboveCriticalForceKilogramSeconds: model.impulseAboveCriticalForceKilogramSeconds,
            capabilityFit: model.capabilityFit,
            confidenceBand: confidenceBand.isEmpty ? nil : confidenceBand
        )
    }

    public static func predictCapabilityFit(
        _ fit: ForceCapabilityFit,
        seconds: Double
    ) -> Double {
        let safeSeconds = max(0.001, seconds)
        let scale = 1 + pow(1 / fit.tau, fit.exponent)
        return fit.criticalForceKilograms
            + (fit.maximumForceKilograms - fit.criticalForceKilograms)
            * scale
            / (1 + pow(safeSeconds / fit.tau, fit.exponent))
    }

    private struct PreparedEffort: Sendable {
        let values: [Double?]
        let durationMilliseconds: Double
    }

    private static func computeCore(
        efforts: [PreparedEffort],
        fitDepth: Int
    ) -> ForceCurveModel? {
        var points: [ForceCurvePoint] = []
        var regressionX: [Double] = []
        var regressionY: [Double] = []
        var fitWindows = Set<Double>()

        for (windowIndex, windowSeconds) in windowsSeconds.enumerated() {
            let values = efforts.compactMap { effort -> Double? in
                guard effort.values.indices.contains(windowIndex),
                      let value = effort.values[windowIndex],
                      value > 0
                else {
                    return nil
                }
                return value
            }.sorted(by: >)
            guard let maximum = values.first else { continue }
            points.append(
                ForceCurvePoint(
                    windowSeconds: windowSeconds,
                    kilograms: round(maximum, places: 2)
                )
            )
            if windowSeconds >= fitMinimumWindowSeconds {
                for value in values.prefix(max(1, fitDepth)) {
                    regressionX.append(1 / windowSeconds)
                    regressionY.append(value)
                }
                fitWindows.insert(windowSeconds)
            }
        }

        guard !points.isEmpty else { return nil }
        let maximumForce = points.map(\.kilograms).max() ?? 0
        var criticalForce: Double?
        var impulse: Double?

        if fitWindows.count >= fitMinimumDistinctWindows,
           regressionX.count == regressionY.count,
           !regressionX.isEmpty {
            let count = Double(regressionX.count)
            let meanX = regressionX.reduce(0, +) / count
            let meanY = regressionY.reduce(0, +) / count
            var sxx = 0.0
            var sxy = 0.0
            for index in regressionX.indices {
                let dx = regressionX[index] - meanX
                sxx += dx * dx
                sxy += dx * (regressionY[index] - meanY)
            }
            if sxx > 1e-12 {
                let slope = sxy / sxx
                let intercept = meanY - slope * meanX
                if intercept > 0, slope >= 0, intercept.isFinite, slope.isFinite {
                    criticalForce = round(intercept, places: 2)
                    impulse = round(slope, places: 2)
                }
            }
        }

        let capability = fitCapability(points: points, criticalForceKilograms: criticalForce)
        return ForceCurveModel(
            points: points,
            maximumForceKilograms: maximumForce,
            criticalForceKilograms: criticalForce,
            impulseAboveCriticalForceKilogramSeconds: impulse,
            capabilityFit: capability,
            confidenceBand: nil
        )
    }

    private static func percentile(_ sorted: [Double], p: Double) -> Double {
        let index = min(
            sorted.count - 1,
            max(0, Int(floor(p * Double(sorted.count))))
        )
        return sorted[index]
    }

    public static func references(
        metadata: [TindeqRecording],
        sampleSets: [[TindeqSample]]
    ) -> ForceReferences {
        let personalRecord = metadata.compactMap(\.peakKilograms).filter { $0 > 0 }.max()
        // References drive targets/RPE and do not render the chart; keep this
        // hot path on the existing point-estimate cost. The tag-curve cache
        // computes the full confidence band for the Force card.
        let model = compute(recordings: sampleSets, bootstrapSamples: 0)
        return ForceReferences(
            personalRecordKilograms: personalRecord,
            criticalForceKilograms: model?.criticalForceKilograms,
            impulseAboveCriticalForceKilogramSeconds: model?.impulseAboveCriticalForceKilogramSeconds,
            maximumForceKilograms: model?.maximumForceKilograms ?? personalRecord,
            capabilityFit: model?.capabilityFit
        )
    }

    /// Duration-bucket selection prevents a flood of short repetitions from
    /// evicting the long efforts required for a stable critical-force fit.
    public static func pickCurveRecordings(
        _ recordings: [TindeqRecording],
        now: Date = Date(),
        fallbackToAll: Bool = true
    ) -> [TindeqRecording] {
        let cutoff = now.addingTimeInterval(-pickWindowDays * 86_400)
        let eligible = recordings.filter {
            ($0.averageKilograms ?? 0) > 0 && $0.durationMilliseconds > 0
        }
        let recent = eligible.filter { $0.recordedAt >= cutoff }
        let pool: [TindeqRecording]
        if recent.isEmpty {
            pool = fallbackToAll ? eligible : []
        } else {
            pool = recent
        }

        var picked: [UUID: TindeqRecording] = [:]
        let grouped = Dictionary(grouping: pool, by: { durationBucket(milliseconds: $0.durationMilliseconds) })
        for group in grouped.values {
            for recording in group.sorted(by: {
                ($0.averageKilograms ?? 0) > ($1.averageKilograms ?? 0)
            }).prefix(pickPerBucket) {
                picked[recording.id] = recording
            }
        }
        for recording in pool.sorted(by: { $0.durationMilliseconds > $1.durationMilliseconds }).prefix(pickLongest) {
            picked[recording.id] = recording
        }
        return picked.values.sorted { $0.recordedAt > $1.recordedAt }
    }

    public static func predictCapability(_ fit: ForceCapabilityFit, seconds: Double) -> Double {
        let safeSeconds = max(0.001, seconds)
        let scale = 1 + pow(1 / fit.tau, fit.exponent)
        return fit.criticalForceKilograms
            + (fit.maximumForceKilograms - fit.criticalForceKilograms)
            * scale
            / (1 + pow(safeSeconds / fit.tau, fit.exponent))
    }

    /// Priority is identical to the existing product: smart Hill curve,
    /// percentage of PR/CF, then fixed kilograms.
    public static func targetKilograms(
        preset: TindeqPreset,
        references: ForceReferences,
        setNumber: Int
    ) -> Double? {
        let clampedSet = max(1, min(max(1, preset.sets), setNumber))
        if preset.targetFromCurve {
            guard let fit = references.capabilityFit else { return nil }
            let seconds = prescriptionWorkSeconds(preset: preset, setNumber: clampedSet)
            return round(predictCapability(fit, seconds: seconds), places: 1)
        }
        if let targetPercentage = preset.targetPercentage {
            let base: Double?
            switch preset.percentageBasis {
            case .personalRecord: base = references.personalRecordKilograms
            case .criticalForce: base = references.criticalForceKilograms
            }
            guard let base, base > 0 else { return nil }
            let percentage = min(150, targetPercentage + Double(clampedSet - 1) * preset.percentageStep)
            return round((percentage / 100) * base, places: 1)
        }
        return preset.targetKilograms
    }

    public static func targetBand(
        targetKilograms: Double?,
        toleranceMode: String,
        toleranceValue: Double
    ) -> ForceTargetBand? {
        guard let targetKilograms, targetKilograms.isFinite, targetKilograms > 0 else { return nil }
        let safeTolerance = max(0, toleranceValue)
        let toleranceKilograms = toleranceMode == "kg"
            ? safeTolerance
            : targetKilograms * safeTolerance / 100
        return ForceTargetBand(
            kilograms: round(targetKilograms, places: 3),
            lowKilograms: round(max(0, targetKilograms - toleranceKilograms), places: 3),
            highKilograms: round(targetKilograms + toleranceKilograms, places: 3)
        )
    }

    public static func targetBand(
        preset: TindeqPreset,
        references: ForceReferences,
        setNumber: Int
    ) -> ForceTargetBand? {
        targetBand(
            targetKilograms: targetKilograms(
                preset: preset,
                references: references,
                setNumber: setNumber
            ),
            toleranceMode: preset.toleranceMode,
            toleranceValue: preset.toleranceValue
        )
    }

    public static func prescriptionWorkSeconds(preset: TindeqPreset, setNumber: Int) -> Double {
        if preset.protocolMode == .reverseAction {
            return Double(max(1, preset.repetitions))
                * (max(0.25, preset.cadenceOutSeconds) + max(0.25, preset.cadenceReturnSeconds))
        }
        return Double(preset.holdSeconds(forSet: setNumber))
    }

    private static func resample(_ samples: [TindeqSample]) -> [Double] {
        let clean = samples
            .filter { $0.milliseconds.isFinite && $0.kilograms.isFinite && $0.milliseconds >= 0 }
            .sorted { $0.milliseconds < $1.milliseconds }
        guard let end = clean.last?.milliseconds else { return [] }
        let stepMilliseconds = 1_000 / resampleHertz
        var grid: [Double] = []
        grid.reserveCapacity(Int(end / stepMilliseconds) + 1)
        var sampleIndex = 0
        var time = 0.0
        while time <= end {
            while sampleIndex + 1 < clean.count,
                  clean[sampleIndex + 1].milliseconds <= time {
                sampleIndex += 1
            }
            grid.append(max(0, clean[sampleIndex].kilograms))
            time += stepMilliseconds
        }
        return grid
    }

    private static func fitCapability(
        points: [ForceCurvePoint],
        criticalForceKilograms: Double?
    ) -> ForceCapabilityFit? {
        let data = points.filter { $0.windowSeconds >= 1 && $0.kilograms > 0 }
        guard data.count >= 3,
              let criticalForceKilograms,
              criticalForceKilograms > 0
        else { return nil }
        let maximumForce = data.map(\.kilograms).max() ?? 0
        guard criticalForceKilograms < maximumForce else { return nil }

        let span = maximumForce - criticalForceKilograms
        var bestSSE = Double.infinity
        var bestExponent = 0.4
        var bestTau = pow(10, -0.5)
        var isFirst = true

        for exponentIndex in 0...24 {
            let exponent = 0.4 + Double(exponentIndex) * 0.1
            for tauIndex in 0...100 {
                let tau = pow(10, -0.5 + 3 * Double(tauIndex) / 100)
                let scale = 1 + pow(1 / tau, exponent)
                var sse = 0.0
                for point in data {
                    let predicted = criticalForceKilograms
                        + span * scale / (1 + pow(point.windowSeconds / tau, exponent))
                    let error = point.kilograms - predicted
                    sse += error * error
                }
                if isFirst || sse < bestSSE {
                    bestSSE = sse
                    bestExponent = exponent
                    bestTau = tau
                    isFirst = false
                }
            }
        }

        return ForceCapabilityFit(
            criticalForceKilograms: criticalForceKilograms,
            maximumForceKilograms: maximumForce,
            tau: bestTau,
            exponent: bestExponent,
            sumSquaredError: bestSSE
        )
    }

    private static func durationBucket(milliseconds: Int) -> Int {
        let seconds = Double(milliseconds) / 1_000
        for (index, edge) in pickBucketEdgesSeconds.enumerated() where seconds < edge {
            return index
        }
        return pickBucketEdgesSeconds.count
    }

    private static func round(_ value: Double, places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }
}

public enum ReverseActionEngine {
    public static func plannedDurationMilliseconds(preset: TindeqPreset) -> Int {
        Int((ForceCurveEngine.prescriptionWorkSeconds(preset: preset, setNumber: 1) * 1_000).rounded())
    }

    public static func cadenceMarkers(preset: TindeqPreset) -> [CadenceMarker] {
        guard preset.protocolMode == .reverseAction else { return [] }
        let outMilliseconds = Int((max(0.25, preset.cadenceOutSeconds) * 1_000).rounded())
        let returnMilliseconds = Int((max(0.25, preset.cadenceReturnSeconds) * 1_000).rounded())
        var elapsed = 0
        var markers: [CadenceMarker] = []
        markers.reserveCapacity(max(1, preset.repetitions) * 2)
        for repetition in 1...max(1, preset.repetitions) {
            markers.append(CadenceMarker(milliseconds: elapsed, repetition: repetition, direction: .out))
            elapsed += outMilliseconds
            markers.append(CadenceMarker(milliseconds: elapsed, repetition: repetition, direction: .return))
            elapsed += returnMilliseconds
        }
        return markers
    }

    public static func completion(
        preset: TindeqPreset,
        actualDurationMilliseconds: Int
    ) -> (actual: Int, completedRepetitions: Int, status: String, markers: [CadenceMarker]) {
        let planned = max(1, plannedDurationMilliseconds(preset: preset))
        let actual = max(1, min(actualDurationMilliseconds, planned))
        let cadence = Int(((max(0.25, preset.cadenceOutSeconds) + max(0.25, preset.cadenceReturnSeconds)) * 1_000).rounded())
        let completed = cadence > 0 ? min(max(1, preset.repetitions), actual / cadence) : 0
        let markers = cadenceMarkers(preset: preset).filter { $0.milliseconds <= actual }
        return (actual, completed, actual >= planned ? "complete" : "partial", markers)
    }

    /// Time-weighted metrics. Irregular BLE notification intervals therefore
    /// do not bias the result. Cadence adherence measures prescribed clock
    /// coverage only; a force sensor cannot infer joint position.
    public static func metrics(
        samples: [TindeqSample],
        targetBand: ForceTargetBand?,
        plannedDurationMilliseconds: Int,
        loadedThresholdKilograms: Double = 1
    ) -> ReverseActionMetrics {
        let clean = samples
            .filter { $0.milliseconds.isFinite && $0.kilograms.isFinite && $0.milliseconds >= 0 }
            .sorted { $0.milliseconds < $1.milliseconds }
        let actualDuration = clean.last?.milliseconds ?? 0
        let comparisonDuration = max(1, plannedDurationMilliseconds > 0
            ? Double(plannedDurationMilliseconds)
            : actualDuration)
        let earlyEnd = comparisonDuration * 0.25
        let lateStart = comparisonDuration * 0.75

        var total = WeightedAccumulator()
        var early = WeightedAccumulator()
        var late = WeightedAccumulator()
        var inTargetMilliseconds = 0.0

        if clean.count >= 2 {
            for index in 1..<clean.count {
                let previous = clean[index - 1]
                let current = clean[index]
                let duration = current.milliseconds - previous.milliseconds
                guard duration > 0 else { continue }
                let midpointTime = previous.milliseconds + duration / 2
                let midpointKilograms = (previous.kilograms + current.kilograms) / 2
                guard midpointKilograms >= loadedThresholdKilograms else { continue }
                total.add(kilograms: midpointKilograms, durationMilliseconds: duration)
                if midpointTime <= earlyEnd {
                    early.add(kilograms: midpointKilograms, durationMilliseconds: duration)
                }
                if midpointTime >= lateStart {
                    late.add(kilograms: midpointKilograms, durationMilliseconds: duration)
                }
                if let targetBand, targetBand.range.contains(midpointKilograms) {
                    inTargetMilliseconds += duration
                }
            }
        }

        let mean = total.mean
        let variance = mean.map { max(0, total.squareForceMilliseconds / max(1, total.durationMilliseconds) - $0 * $0) }
        let coefficient: Double?
        if let mean, mean > 0, let variance {
            coefficient = round((sqrt(variance) / mean) * 100, places: 1)
        } else {
            coefficient = nil
        }
        let drift: Double?
        if let earlyMean = early.mean, earlyMean > 0, let lateMean = late.mean {
            drift = round(((lateMean - earlyMean) / earlyMean) * 100, places: 1)
        } else {
            drift = nil
        }
        let inTarget: Double?
        if targetBand != nil, total.durationMilliseconds > 0 {
            inTarget = round((inTargetMilliseconds / total.durationMilliseconds) * 100, places: 1)
        } else {
            inTarget = nil
        }

        return ReverseActionMetrics(
            meanKilograms: mean.map { round($0, places: 2) },
            coefficientOfVariationPercent: coefficient,
            inTargetPercent: inTarget,
            timeUnderTensionMilliseconds: Int(total.durationMilliseconds.rounded()),
            driftPercent: drift,
            cadenceAdherencePercent: round(
                min(1, max(0, actualDuration / comparisonDuration)) * 100,
                places: 1
            )
        )
    }

    private struct WeightedAccumulator {
        var durationMilliseconds = 0.0
        var forceMilliseconds = 0.0
        var squareForceMilliseconds = 0.0

        mutating func add(kilograms: Double, durationMilliseconds: Double) {
            self.durationMilliseconds += durationMilliseconds
            forceMilliseconds += kilograms * durationMilliseconds
            squareForceMilliseconds += kilograms * kilograms * durationMilliseconds
        }

        var mean: Double? {
            durationMilliseconds > 0 ? forceMilliseconds / durationMilliseconds : nil
        }
    }

    private static func round(_ value: Double, places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }
}
