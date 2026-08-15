import Foundation

public enum TindeqProtocolConstants {
    public static let namePrefix = "Progressor"
    public static let serviceUUID = "7e4e1701-1ea6-40c9-9dcc-13d34ffead57"
    public static let notifyCharacteristicUUID = "7e4e1702-1ea6-40c9-9dcc-13d34ffead57"
    public static let controlCharacteristicUUID = "7e4e1703-1ea6-40c9-9dcc-13d34ffead57"

    public enum Command: UInt8, Sendable {
        case tare = 0x64
        case startWeight = 0x65
        case stop = 0x66
        case sampleBattery = 0x6f
    }
}

public struct TindeqWireSample: Equatable, Sendable {
    public let microseconds: UInt32
    public let kilograms: Double

    public init(microseconds: UInt32, kilograms: Double) {
        self.microseconds = microseconds
        self.kilograms = kilograms
    }
}

public enum TindeqFrame: Equatable, Sendable {
    case weight([TindeqWireSample])
    case response(Data)
    case lowBattery
    case unknown(tag: Int)
}

public enum TindeqFrameParser {
    public static func parse(_ data: Data) -> TindeqFrame {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return .unknown(tag: -1) }
        let tag = bytes[0]
        let declaredLength = Int(bytes[1])
        let availableLength = max(0, bytes.count - 2)
        let payloadLength = min(declaredLength, availableLength)

        switch tag {
        case 0x01:
            let pairCount = payloadLength / 8
            var samples: [TindeqWireSample] = []
            samples.reserveCapacity(pairCount)
            for index in 0..<pairCount {
                let offset = 2 + index * 8
                let forceBits = readUInt32LE(bytes, offset: offset)
                let force = Float(bitPattern: forceBits)
                let timestamp = readUInt32LE(bytes, offset: offset + 4)
                guard force.isFinite else { continue }
                samples.append(
                    TindeqWireSample(
                        microseconds: timestamp,
                        kilograms: max(0, Double(force))
                    )
                )
            }
            return .weight(samples)
        case 0x00:
            return .response(Data(bytes.dropFirst(2)))
        case 0x02:
            return .lowBattery
        default:
            return .unknown(tag: Int(tag))
        }
    }

    private static func readUInt32LE(_ bytes: [UInt8], offset: Int) -> UInt32 {
        guard offset >= 0, offset + 3 < bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}

public struct ForceSummary: Codable, Equatable, Sendable {
    public let durationMilliseconds: Int
    public let peakKilograms: Double
    public let averageKilograms: Double
    public let samples: [TindeqSample]

    public init(
        durationMilliseconds: Int,
        peakKilograms: Double,
        averageKilograms: Double,
        samples: [TindeqSample]
    ) {
        self.durationMilliseconds = durationMilliseconds
        self.peakKilograms = peakKilograms
        self.averageKilograms = averageKilograms
        self.samples = samples
    }
}

public struct ForceSessionAccumulator: Codable, Equatable, Sendable {
    public static let maximumRecordingMilliseconds = 1_800_000

    private var startMicroseconds: UInt32?
    private var runningSumKilograms: Double
    private var runningPeakKilograms: Double
    public private(set) var samples: [TindeqSample]

    public init() {
        self.startMicroseconds = nil
        self.runningSumKilograms = 0
        self.runningPeakKilograms = 0
        self.samples = []
    }

    public mutating func reset() {
        startMicroseconds = nil
        runningSumKilograms = 0
        runningPeakKilograms = 0
        samples.removeAll(keepingCapacity: true)
    }

    @discardableResult
    public mutating func append(_ incoming: [TindeqWireSample]) -> Int {
        var accepted = 0
        for sample in incoming {
            if startMicroseconds == nil { startMicroseconds = sample.microseconds }
            guard let startMicroseconds else { continue }
            // The Progressor timestamp is a UInt32 device clock. Wrapping
            // subtraction keeps the result correct across one wrap; a normal
            // Sendmeter recording is capped at 30 minutes, far below a second
            // wrap of the microsecond clock.
            let elapsedMicroseconds = sample.microseconds &- startMicroseconds
            let elapsedMilliseconds = Double(elapsedMicroseconds) / 1_000.0
            guard elapsedMilliseconds <= Double(Self.maximumRecordingMilliseconds) else { continue }
            if let last = samples.last, elapsedMilliseconds < last.milliseconds {
                // Ignore out-of-order frames rather than making the persisted
                // trace non-monotonic and breaking duration/graph logic.
                continue
            }
            let kilograms = max(0, sample.kilograms)
            samples.append(
                TindeqSample(
                    milliseconds: elapsedMilliseconds,
                    kilograms: kilograms
                )
            )
            runningSumKilograms += kilograms
            runningPeakKilograms = max(runningPeakKilograms, kilograms)
            accepted += 1
        }
        return accepted
    }

    public var currentKilograms: Double { samples.last?.kilograms ?? 0 }
    public var peakKilograms: Double { runningPeakKilograms }
    public var averageKilograms: Double {
        guard !samples.isEmpty else { return 0 }
        return runningSumKilograms / Double(samples.count)
    }
    public var elapsedMilliseconds: Double { samples.last?.milliseconds ?? 0 }

    public func visibleWindow(milliseconds: Double = 10_000) -> [TindeqSample] {
        guard let last = samples.last else { return [] }
        let threshold = max(0, last.milliseconds - milliseconds)
        var low = 0
        var high = samples.count
        while low < high {
            let midpoint = (low + high) / 2
            if samples[midpoint].milliseconds < threshold {
                low = midpoint + 1
            } else {
                high = midpoint
            }
        }
        return Array(samples[low...])
    }

    public func summary() -> ForceSummary? {
        guard !samples.isEmpty else { return nil }
        let rounded = samples.map {
            TindeqSample(
                milliseconds: $0.milliseconds.rounded(),
                kilograms: ($0.kilograms * 100).rounded() / 100
            )
        }
        let duration = max(1, Int(rounded.last?.milliseconds ?? 1))
        return ForceSummary(
            durationMilliseconds: duration,
            peakKilograms: (runningPeakKilograms * 100).rounded() / 100,
            averageKilograms: (averageKilograms * 100).rounded() / 100,
            samples: rounded
        )
    }
}

// MARK: - Guided force protocol

public enum ForceProtocolStageKind: String, Codable, Sendable {
    case prepare
    case work
    case switchSide
    case restBetweenRepetitions
    case restBetweenSets
    case complete
}

public struct ForceProtocolStage: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let kind: ForceProtocolStageKind
    public let setNumber: Int
    public let repetitionNumber: Int
    public let side: TindeqSide
    public let durationSeconds: Double
    public let label: String

    public init(
        id: UUID = UUID(),
        kind: ForceProtocolStageKind,
        setNumber: Int,
        repetitionNumber: Int,
        side: TindeqSide,
        durationSeconds: Double,
        label: String
    ) {
        self.id = id
        self.kind = kind
        self.setNumber = setNumber
        self.repetitionNumber = repetitionNumber
        self.side = side
        self.durationSeconds = durationSeconds
        self.label = label
    }
}

public enum ForceProtocolSchedule {
    public static func stages(
        preset: TindeqPreset,
        startingSide: TindeqSide = .left
    ) -> [ForceProtocolStage] {
        let sets = max(1, preset.sets)
        let repetitions = max(1, preset.repetitions)
        var stages: [ForceProtocolStage] = []

        if preset.prepareSeconds > 0 {
            stages.append(
                ForceProtocolStage(
                    kind: .prepare,
                    setNumber: 1,
                    repetitionNumber: 1,
                    side: preset.alternateSides ? startingSide : .unspecified,
                    durationSeconds: Double(preset.prepareSeconds),
                    label: "Prepare"
                )
            )
        }

        for setNumber in 1...sets {
            let workDuration: Double
            if preset.protocolMode == .reverseAction {
                workDuration = Double(repetitions) * (preset.cadenceOutSeconds + preset.cadenceReturnSeconds)
            } else {
                workDuration = Double(preset.holdSeconds(forSet: setNumber))
            }

            for repetition in 1...repetitions {
                if preset.protocolMode == .reverseAction && repetition > 1 {
                    // Reverse Action is persisted as one continuous set. Its
                    // repetitions are cadence markers inside that set, not
                    // separate work/rest stages.
                    continue
                }

                let sides: [TindeqSide]
                if preset.alternateSides {
                    let second: TindeqSide = startingSide == .right ? .left : .right
                    sides = [startingSide, second]
                } else {
                    sides = [.unspecified]
                }

                for (sideIndex, side) in sides.enumerated() {
                    stages.append(
                        ForceProtocolStage(
                            kind: .work,
                            setNumber: setNumber,
                            repetitionNumber: repetition,
                            side: side,
                            durationSeconds: workDuration,
                            label: preset.protocolMode == .reverseAction
                                ? "Reverse Action"
                                : "Hold"
                        )
                    )
                    if sideIndex < sides.count - 1 {
                        stages.append(
                            ForceProtocolStage(
                                kind: .switchSide,
                                setNumber: setNumber,
                                repetitionNumber: repetition,
                                side: sides[sideIndex + 1],
                                durationSeconds: 3,
                                label: "Switch side"
                            )
                        )
                    }
                }

                if repetition < repetitions && preset.protocolMode == .hold {
                    stages.append(
                        ForceProtocolStage(
                            kind: .restBetweenRepetitions,
                            setNumber: setNumber,
                            repetitionNumber: repetition,
                            side: .unspecified,
                            durationSeconds: Double(max(0, preset.restBetweenRepetitionsSeconds)),
                            label: "Rest"
                        )
                    )
                }
            }

            if setNumber < sets {
                stages.append(
                    ForceProtocolStage(
                        kind: .restBetweenSets,
                        setNumber: setNumber,
                        repetitionNumber: repetitions,
                        side: .unspecified,
                        durationSeconds: Double(max(0, preset.restBetweenSetsSeconds)),
                        label: "Set rest"
                    )
                )
            }
        }

        stages.append(
            ForceProtocolStage(
                kind: .complete,
                setNumber: sets,
                repetitionNumber: repetitions,
                side: .unspecified,
                durationSeconds: 0,
                label: "Complete"
            )
        )
        return stages
    }
}

public struct ForceProtocolRun: Codable, Equatable, Sendable {
    public let runID: UUID
    public let presetID: UUID
    public let stages: [ForceProtocolStage]
    public private(set) var stageIndex: Int
    public private(set) var stageStartedAt: Date?
    public private(set) var pausedElapsedSeconds: Double
    public private(set) var isPaused: Bool

    public init(preset: TindeqPreset, startingSide: TindeqSide = .left) {
        self.runID = UUID()
        self.presetID = preset.id
        self.stages = ForceProtocolSchedule.stages(preset: preset, startingSide: startingSide)
        self.stageIndex = 0
        self.stageStartedAt = nil
        self.pausedElapsedSeconds = 0
        self.isPaused = false
    }

    public var currentStage: ForceProtocolStage { stages[stageIndex] }
    public var isComplete: Bool { currentStage.kind == .complete }

    public mutating func start(at date: Date = Date()) {
        guard !isComplete else { return }
        stageStartedAt = date
        pausedElapsedSeconds = 0
        isPaused = false
    }

    public mutating func pause(at date: Date = Date()) {
        guard !isPaused, let stageStartedAt, !isComplete else { return }
        pausedElapsedSeconds += max(0, date.timeIntervalSince(stageStartedAt))
        self.stageStartedAt = nil
        isPaused = true
    }

    public mutating func resume(at date: Date = Date()) {
        guard isPaused, !isComplete else { return }
        stageStartedAt = date
        isPaused = false
    }

    public func elapsedSeconds(at date: Date = Date()) -> Double {
        pausedElapsedSeconds + (stageStartedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }

    public func remainingSeconds(at date: Date = Date()) -> Double {
        max(0, currentStage.durationSeconds - elapsedSeconds(at: date))
    }

    @discardableResult
    public mutating func advanceIfNeeded(at date: Date = Date()) -> Bool {
        guard !isComplete, elapsedSeconds(at: date) >= currentStage.durationSeconds else {
            return false
        }
        advance(at: date)
        return true
    }

    public mutating func advance(at date: Date = Date()) {
        guard stageIndex < stages.count - 1 else { return }
        stageIndex += 1
        pausedElapsedSeconds = 0
        isPaused = false
        stageStartedAt = isComplete ? nil : date
    }
}
