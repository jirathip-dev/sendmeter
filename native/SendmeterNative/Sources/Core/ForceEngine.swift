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

/// Reference-backed storage for a live force trace.
///
/// The BLE accumulator and the SwiftUI chart share this object. The producer
/// appends in place while the chart reads individual samples through a range;
/// no `Array` or `ArraySlice` is retained across the next append, so a live
/// pull never triggers copy-on-write of the accumulated trace. The native app
/// owns this buffer on `MainActor`; `@unchecked Sendable` keeps the enclosing
/// value types usable at their existing concurrency boundaries without
/// pretending that the mutable buffer is independently thread-safe.
public final class ForceSampleBuffer: Codable, Equatable, @unchecked Sendable {
    private var storage: [TindeqSample]

    public init() {
        storage = []
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    public var last: TindeqSample? { storage.last }

    public subscript(index: Int) -> TindeqSample {
        storage[index]
    }

    /// A full-array view for non-live consumers such as final-summary
    /// serialization and tests. The live chart must use `subscript` with a
    /// range instead; retaining this value while appending would intentionally
    /// reintroduce copy-on-write.
    public var array: [TindeqSample] { storage }

    public func append(_ sample: TindeqSample) {
        storage.append(sample)
    }

    public func removeAll(keepingCapacity: Bool = true) {
        storage.removeAll(keepingCapacity: keepingCapacity)
    }

    /// The half-open range of the most recent `milliseconds` of samples. The
    /// buffer is monotonic, so binary search keeps each display flush O(log n).
    public func visibleRange(milliseconds: Double = 10_000) -> Range<Int> {
        guard let last else { return 0..<0 }
        let threshold = max(0, last.milliseconds - milliseconds)
        var low = 0
        var high = storage.count
        while low < high {
            let midpoint = (low + high) / 2
            if storage[midpoint].milliseconds < threshold {
                low = midpoint + 1
            } else {
                high = midpoint
            }
        }
        return low..<storage.count
    }

    public static func == (lhs: ForceSampleBuffer, rhs: ForceSampleBuffer) -> Bool {
        lhs.storage == rhs.storage
    }
}

public struct ForceSessionAccumulator: Codable, Equatable, Sendable {
    /// Cut 30 min -> 10 min (#682): always-armed hands-free makes a sustained
    /// non-human load accidentally reachable, so a tighter safety ceiling is
    /// the backstop behind the static-load watchdog. Mirrors
    /// `TindeqRecordingLimit.maxRecordingMs` on the watch.
    public static let maximumRecordingMilliseconds = 600_000

    private var startMicroseconds: UInt32?
    private var runningSumKilograms: Double
    private var runningPeakKilograms: Double
    /// Shared with the live chart by `TindeqBluetooth`. Keeping this storage
    /// behind a reference preserves the accumulator's cheap append path while
    /// allowing the chart to consume an index range without copying it.
    public let sampleBuffer: ForceSampleBuffer

    /// Compatibility view for summaries, persistence, and existing pure-core
    /// call sites. The live stream never reads this property for rendering.
    public var samples: [TindeqSample] { sampleBuffer.array }

    public init(sampleBuffer: ForceSampleBuffer = ForceSampleBuffer()) {
        self.startMicroseconds = nil
        self.runningSumKilograms = 0
        self.runningPeakKilograms = 0
        self.sampleBuffer = sampleBuffer
    }

    public mutating func reset() {
        startMicroseconds = nil
        runningSumKilograms = 0
        runningPeakKilograms = 0
        sampleBuffer.removeAll(keepingCapacity: true)
    }

    @discardableResult
    public mutating func append(_ incoming: [TindeqWireSample]) -> Int {
        var accepted = 0
        for sample in incoming {
            if startMicroseconds == nil { startMicroseconds = sample.microseconds }
            guard let startMicroseconds else { continue }
            // The Progressor timestamp is a UInt32 device clock. Wrapping
            // subtraction keeps the result correct across one wrap; a normal
            // Sendmeter recording is capped at 10 minutes, far below a second
            // wrap of the microsecond clock.
            let elapsedMicroseconds = sample.microseconds &- startMicroseconds
            let elapsedMilliseconds = Double(elapsedMicroseconds) / 1_000.0
            guard elapsedMilliseconds <= Double(Self.maximumRecordingMilliseconds) else { continue }
            if let last = sampleBuffer.last, elapsedMilliseconds < last.milliseconds {
                // Ignore out-of-order frames rather than making the persisted
                // trace non-monotonic and breaking duration/graph logic.
                continue
            }
            let kilograms = max(0, sample.kilograms)
            sampleBuffer.append(
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

    public var currentKilograms: Double { sampleBuffer.last?.kilograms ?? 0 }
    public var peakKilograms: Double { runningPeakKilograms }
    public var averageKilograms: Double {
        guard !sampleBuffer.isEmpty else { return 0 }
        return runningSumKilograms / Double(sampleBuffer.count)
    }
    public var elapsedMilliseconds: Double { sampleBuffer.last?.milliseconds ?? 0 }

    /// The half-open index range of the most recent `milliseconds` of samples,
    /// bounded by the accumulated buffer's end (#671). The live chart reads
    /// this range over `sampleBuffer` instead of copying a window array per
    /// BLE notification.
    public func visibleRange(milliseconds: Double = 10_000) -> Range<Int> {
        sampleBuffer.visibleRange(milliseconds: milliseconds)
    }

    /// A compatibility convenience for non-live callers. The live chart must
    /// use `sampleBuffer` plus `visibleRange`; this legacy slice asks for the
    /// full-array compatibility view and can therefore trigger copy-on-write
    /// if the returned slice is retained while the stream appends.
    public func visibleWindow(milliseconds: Double = 10_000) -> ArraySlice<TindeqSample> {
        sampleBuffer.array[visibleRange(milliseconds: milliseconds)]
    }

    public func summary() -> ForceSummary? {
        guard !sampleBuffer.isEmpty else { return nil }
        let rounded = sampleBuffer.array.map {
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

// MARK: - Force publish coalescing (#671)

/// The flush driver's cadence — the single throttle on force-surface
/// publishes. BLE notifications can arrive faster than the display can
/// redraw; without this the hot path assigned all of the observed values
/// (including the chart window) once per notification, and a fresh window
/// array at stream rate. This mirrors the web app's rAF throttle
/// (`src/hooks/useTindeq.ts:257-268`), which native previously lacked.
///
/// #671 fix direction: the transport schedules a Timer at
/// `displayIntervalSeconds` (display rate) and a fire publishes exactly when
/// a notification has marked samples pending. There is NO second time-gate:
/// two throttles with the same period beat against each other and drop a
/// large fraction of the timer's fires (the shipped bug this removes). One
/// cadence source, and a fire always publishes — true display rate.
///
/// The type is pure so the cadence is provable in `swift test`; the
/// transport (`TindeqBluetooth`) schedules its real Timer with this interval
/// and calls `shouldPublishOnFire(pending:)` per fire.
public struct ForcePublishScheduler {
    /// The flush timer's fire cadence, in seconds (~60 Hz). The timer IS the
    /// throttle: publishes can never exceed one per interval, and every fire
    /// with pending samples publishes.
    public var displayIntervalSeconds: Double

    public init(displayIntervalSeconds: Double = 1.0 / 60.0) {
        precondition(displayIntervalSeconds > 0)
        self.displayIntervalSeconds = displayIntervalSeconds
    }

    /// The shipped publish rule for one timer fire: publish iff a notification
    /// has marked samples pending since the last publish. Pure so the bench can
    /// drive it with a simulated fire sequence (including jitter) and prove the
    /// display-rate bound.
    public func shouldPublishOnFire(pending: Bool) -> Bool {
        pending
    }
}

/// What one flush publishes, decided off the accumulator (the source of truth)
/// by the transport's flush driver. Pure and testable in `swift test` even
/// though the timer that drives it lives on the transport.
public struct ForcePublishSnapshot: Equatable, Sendable {
    /// Which observed properties this flush refreshes. Recording refreshes
    /// all five; an armed-but-not-recording stream refreshes only the live
    /// reading — a single Observation update per flush (F8); an idle stream
    /// refreshes nothing.
    public struct Fields: OptionSet, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let currentKilograms = Fields(rawValue: 1 << 0)
        public static let peakKilograms = Fields(rawValue: 1 << 1)
        public static let averageKilograms = Fields(rawValue: 1 << 2)
        public static let elapsedMilliseconds = Fields(rawValue: 1 << 3)
        public static let window = Fields(rawValue: 1 << 4)
        /// Everything a recording flush publishes.
        public static let all: Fields = [
            .currentKilograms, .peakKilograms, .averageKilograms,
            .elapsedMilliseconds, .window
        ]
    }

    public let fields: Fields
    public let currentKilograms: Double
    public let peakKilograms: Double
    public let averageKilograms: Double
    public let elapsedMilliseconds: Double
    /// The half-open index range of the accumulator's `sampleBuffer` the chart
    /// window should show. The live Canvas indexes that stable buffer directly
    /// and never materializes a visible-window array.
    public let visibleRange: Range<Int>

    public init(
        fields: Fields,
        currentKilograms: Double,
        peakKilograms: Double,
        averageKilograms: Double,
        elapsedMilliseconds: Double,
        visibleRange: Range<Int>
    ) {
        self.fields = fields
        self.currentKilograms = currentKilograms
        self.peakKilograms = peakKilograms
        self.averageKilograms = averageKilograms
        self.elapsedMilliseconds = elapsedMilliseconds
        self.visibleRange = visibleRange
    }

    public static let idle = ForcePublishSnapshot(
        fields: [],
        currentKilograms: 0,
        peakKilograms: 0,
        averageKilograms: 0,
        elapsedMilliseconds: 0,
        visibleRange: 0..<0
    )
}

/// Builds the observed snapshot from the stream's branch state. Recording
/// publishes the full force surface + window; an armed-but-not-recording
/// stream publishes only the live reading; an idle stream publishes nothing.
public enum ForcePublishSnapshotBuilder {
    public static func snapshot(
        isRecording: Bool,
        handsFreeArmed: Bool,
        lastSampleKilograms: Double,
        accumulator: ForceSessionAccumulator,
        windowMilliseconds: Double = 10_000
    ) -> ForcePublishSnapshot {
        if isRecording {
            return ForcePublishSnapshot(
                fields: .all,
                currentKilograms: accumulator.currentKilograms,
                peakKilograms: accumulator.peakKilograms,
                averageKilograms: accumulator.averageKilograms,
                elapsedMilliseconds: accumulator.elapsedMilliseconds,
                visibleRange: accumulator.visibleRange(milliseconds: windowMilliseconds)
            )
        }
        if handsFreeArmed {
            // Pre-start samples feed the hands-free loop, never the
            // accumulator; the live reading comes from the last sample that
            // marked `pendingPublish`.
            return ForcePublishSnapshot(
                fields: .currentKilograms,
                currentKilograms: lastSampleKilograms,
                peakKilograms: 0,
                averageKilograms: 0,
                elapsedMilliseconds: 0,
                visibleRange: 0..<0
            )
        }
        return .idle
    }
}

// MARK: - Live force trace Y-domain (#900)

/// The live force trace's Y-domain (the chart's top value in kg).
///
/// #900: the domain must be a stable function of the stage/target band, not
/// of whatever samples happen to sit in the sliding window. Every guided rep
/// records through its own accumulator, so a rep boundary resets the buffer
/// and the visible window empties; a window-derived scale collapsed with it
/// and the target band visibly jumped between reps and across surfaces.
///
/// The domain is therefore anchored to the band's upper bound (× headroom,
/// never below the old 10 kg absolute floor) and only expands for a real
/// in-window peak or a held recent-pull peak. Window contents at or below
/// the anchor cannot move the scale. A held peak is only honored while a
/// target band is present — with no band there is no level to stabilize, and
/// the scale keeps its original fit-the-window behavior.
public enum ForceChartYDomain {
    /// The absolute lowest domain top (kg), preserved from the original
    /// per-frame formula so a bandless trace never collapses to zero.
    public static let floorKilograms = 10.0
    /// Headroom above the anchor/peaks so the strongest drawn value stays
    /// inside the chart instead of touching its top edge.
    public static let headroom = 1.15

    /// The Y-domain top for one rendered window.
    ///
    /// - Parameters:
    ///   - bandUpperBoundKilograms: the stage/target band's upper bound, or
    ///     nil when no band is shown (hands-free without a plan, watch
    ///     mirror, saved recordings).
    ///   - windowPeakKilograms: the strongest sample in the visible window.
    ///   - heldPeakKilograms: the strongest peak seen since the current
    ///     target context began (rep-boundary hysteresis); ignored when no
    ///     band is present.
    public static func maxValue(
        bandUpperBoundKilograms: Double?,
        windowPeakKilograms: Double,
        heldPeakKilograms: Double
    ) -> Double {
        let anchor = max(floorKilograms, bandUpperBoundKilograms ?? 0)
        let held = bandUpperBoundKilograms == nil ? 0 : heldPeakKilograms
        return max(anchor, windowPeakKilograms, held) * headroom
    }
}

/// Rep-boundary hysteresis for `ForceChartYDomain`: remembers the strongest
/// window peak of the current target context so the scale stays open after
/// the window empties, and re-anchors the moment the target band changes
/// (the level may move only when the numeric target changes).
public struct ForceChartYDomainTracker: Equatable, Sendable {
    public private(set) var heldPeakKilograms: Double
    private var bandUpperBoundKilograms: Double?

    public init() {
        heldPeakKilograms = 0
        bandUpperBoundKilograms = nil
    }

    /// Feed one displayed window (call once per visible-window change).
    ///
    /// A changed band upper bound starts a new target context: the held peak
    /// resets so the domain re-anchors to the new band. Otherwise the held
    /// peak only grows — a monotone hold never collapses under an empty
    /// window and converges identically from either live chart feed.
    public mutating func frame(
        bandUpperBoundKilograms: Double?,
        windowPeakKilograms: Double
    ) {
        if bandUpperBoundKilograms != self.bandUpperBoundKilograms {
            self.bandUpperBoundKilograms = bandUpperBoundKilograms
            heldPeakKilograms = 0
        }
        heldPeakKilograms = max(heldPeakKilograms, windowPeakKilograms)
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

/// #901: the SELECTED side decides the schedule. A single-side selection
/// (Left/Right) always runs that side alone — even when the preset declares
/// `alternateSides` — so no opposite-side work or switch-hands stages are
/// ever produced. Alternation is a Both-mode behavior (and the legacy path
/// for an unspecified selection); `startingSide` only picks the first hand
/// of an alternating pair.
public enum ForceProtocolSidePolicy {
    public static func isSingleSide(_ side: TindeqSide) -> Bool {
        side == .left || side == .right
    }

    public static func alternatingPair(startingSide: TindeqSide) -> [TindeqSide] {
        startingSide == .right ? [.right, .left] : [.left, .right]
    }

    /// The work-stage sides of the executed schedule. Left/Right resolve to
    /// that side ONLY, stamped explicitly (never `.unspecified`), so target
    /// bands and saved attribution are exact. Both/unspecified fall back to
    /// the legacy rule: alternate when the preset declares it, else run the
    /// `.unspecified` stages attributed at save time.
    public static func scheduleWorkSides(
        selectedSide: TindeqSide,
        presetAlternates: Bool,
        startingSide: TindeqSide
    ) -> [TindeqSide] {
        if isSingleSide(selectedSide) {
            return [selectedSide]
        }
        guard presetAlternates else { return [.unspecified] }
        return alternatingPair(startingSide: startingSide)
    }

    /// The side set the target plan must resolve — the mirror of
    /// `scheduleWorkSides` for `resolveForceTargetPlan` (#901): Left/Right
    /// resolve ONLY the selected side's bands; Both/unspecified keep the
    /// alternating pair when the preset alternates, else resolve the
    /// selected side's own band (the app's `fallbackSide`).
    public static func planWorkSides(
        selectedSide: TindeqSide,
        presetAlternates: Bool,
        startingSide: TindeqSide
    ) -> [TindeqSide] {
        if isSingleSide(selectedSide) {
            return [selectedSide]
        }
        guard presetAlternates else { return [selectedSide] }
        return alternatingPair(startingSide: startingSide)
    }
}

public enum ForceProtocolSchedule {
    public static func stages(
        preset: TindeqPreset,
        startingSide: TindeqSide = .left,
        selectedSide: TindeqSide = .unspecified
    ) -> [ForceProtocolStage] {
        let sets = max(1, preset.sets)
        let repetitions = max(1, preset.repetitions)
        // #901: the work sides are decided once, up front — the prepare stage
        // mirrors the first work side so an explicit Left/Right selection is
        // stamped on the whole run, not only the measurement stages.
        let workSides = ForceProtocolSidePolicy.scheduleWorkSides(
            selectedSide: selectedSide,
            presetAlternates: preset.alternateSides,
            startingSide: startingSide
        )
        var stages: [ForceProtocolStage] = []

        if preset.prepareSeconds > 0 {
            stages.append(
                ForceProtocolStage(
                    kind: .prepare,
                    setNumber: 1,
                    repetitionNumber: 1,
                    side: workSides.first ?? .unspecified,
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

                for (sideIndex, side) in workSides.enumerated() {
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
                    if sideIndex < workSides.count - 1 {
                        stages.append(
                            ForceProtocolStage(
                                kind: .switchSide,
                                setNumber: setNumber,
                                repetitionNumber: repetition,
                                side: workSides[sideIndex + 1],
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

    public init(
        preset: TindeqPreset,
        startingSide: TindeqSide = .left,
        selectedSide: TindeqSide = .unspecified
    ) {
        self.runID = UUID()
        self.presetID = preset.id
        self.stages = ForceProtocolSchedule.stages(
            preset: preset,
            startingSide: startingSide,
            selectedSide: selectedSide
        )
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

    /// Re-anchor the current stage at a load-triggered hands-free start.
    /// Arming intentionally happens before a real pull, so the stage clock
    /// must not spend its duration while the user is still waiting to pull.
    public mutating func restartCurrentStage(at date: Date = Date()) {
        guard !isComplete else { return }
        stageStartedAt = date
        pausedElapsedSeconds = 0
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
