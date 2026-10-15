import Foundation

/// #1038: the Free hold full screen's phase — the tab keeps no live force
/// (G1), so these three states are the whole recording surface.
///
/// `waiting` → armed, nothing held. `recording` → the pull is being measured.
/// `saved` → the release saved the pull and the screen is ready for the next
/// one (it stays presented until the user leaves).
public enum FreeHoldPhase: Equatable, Sendable {
    case waiting
    case recording
    case saved

    public var label: String {
        switch self {
        case .waiting: return "PULL TO START"
        case .recording: return "HOLDING"
        case .saved: return "SAVED"
        }
    }

    public var detail: String {
        switch self {
        case .waiting: return "Pull to record · release to stop and save"
        case .recording: return "Release to stop · saves on its own"
        case .saved: return "Pull again for the next one"
        }
    }

    public var symbol: String {
        switch self {
        case .waiting, .recording: return "hand.draw.fill"
        case .saved: return "checkmark.circle.fill"
        }
    }
}

/// #1038: the Free hold full screen's chart takes the height left after the
/// fixed sections, so the screen has no dead gap above the controls on any
/// phone, and never shrinks below a readable trace.
public enum FreeHoldLayout {
    public static let minimumChartHeight: Double = 150
    /// Phones always fill (the tallest phone cover leaves ~460 pt); the cap
    /// only bounds an iPad-size cover, where an unbounded chart reads as a
    /// wall. 360 under-filled the 17 Pro once the stop control left the
    /// between-pulls layout (a ~15 pt dead band above the safe area).
    public static let maximumChartHeight: Double = 480

    /// - Parameters:
    ///   - viewport: the cover's height (its safe-area rect).
    ///   - controls: the pinned controls row's measured height.
    ///   - nonChart: everything in the scroll stack except the chart itself
    ///     (nil until the first layout pass is measured).
    public static func chartHeight(viewport: Double, controls: Double, nonChart: Double?) -> Double {
        guard let nonChart else { return minimumChartHeight }
        let available = viewport - controls - nonChart
        return min(maximumChartHeight, max(minimumChartHeight, available.rounded(.down)))
    }
}

/// #1038 G3 + Safety: the full screen opens on the FIRST PULL, never on
/// arming. The decision is pure so a sub-threshold wobble can be proven to
/// open nothing, and it is deliberately keyed on the pull threshold the
/// machine already enforced (`isMeasuring`) rather than on raw kilograms.
public enum FreeHoldPresentation {
    public enum Request: Equatable, Sendable {
        case present
        case none
    }

    /// - Parameters:
    ///   - measuring: the hands-free machine says a pull is above the start
    ///     threshold and dwell — the only true trigger.
    ///   - alreadyPresented: the screen is already open (it stays for the
    ///     next pull).
    ///   - guidedSessionActive: a guided run owns the device.
    public static func request(
        measuring: Bool,
        alreadyPresented: Bool,
        guidedSessionActive: Bool
    ) -> Request {
        guard measuring, !alreadyPresented, !guidedSessionActive else { return .none }
        return .present
    }
}

/// #1038 G3: "every mode starts armed by default" — while connected in Free
/// hold there is no separate Arm step. The policy is guarded so it can never
/// arm into an unsafe moment (mid-recording, an unsaved held pull, a guided
/// run, or a save in flight), and it never fights a user's own Disarm: an
/// explicit disarm while this link stays up keeps the loop idle until the
/// user asks for it again.
public struct FreeHoldAutoArmInput: Equatable, Sendable {
    public var mode: ForceBarMode
    public var connected: Bool
    public var armed: Bool
    public var measuring: Bool
    public var hasHeldPull: Bool
    public var guidedSessionActive: Bool
    public var saving: Bool
    /// The user tapped Disarm on this link. Cleared by a reconnect or a
    /// switch away from Free hold.
    public var userDisarmed: Bool

    public init(
        mode: ForceBarMode,
        connected: Bool,
        armed: Bool,
        measuring: Bool,
        hasHeldPull: Bool,
        guidedSessionActive: Bool,
        saving: Bool,
        userDisarmed: Bool
    ) {
        self.mode = mode
        self.connected = connected
        self.armed = armed
        self.measuring = measuring
        self.hasHeldPull = hasHeldPull
        self.guidedSessionActive = guidedSessionActive
        self.saving = saving
        self.userDisarmed = userDisarmed
    }
}

public enum FreeHoldAutoArmPolicy {
    public static func shouldArm(_ input: FreeHoldAutoArmInput) -> Bool {
        input.mode == .handsFree
            && input.connected
            && !input.armed
            && !input.measuring
            && !input.hasHeldPull
            && !input.guidedSessionActive
            && !input.saving
            && !input.userDisarmed
    }
}

/// #1038 G4: picking a protocol in the context card selects Guided
/// immediately — including when the bar was in Free hold.
public enum ForceProtocolSelectionRouting {
    public static func mode(afterSelecting selection: ForceProtocolSelection) -> ForceBarMode? {
        switch selection {
        case .free:
            // Panning to "Free" is a Guided-mode choice (the armed slot);
            // Free hold is picked on the bar's switch, not here.
            return nil
        case .suggestedZone, .suggestedMaintenance, .movement, .savedPreset:
            return .guided
        }
    }
}

/// #1038 H1: the intensity dial's reference ticks. The scale is 60–110, so
/// 100 sits at 80 % of the track — not at its centre. The slider's thumb
/// travels between its own radius and the track width minus that radius, so
/// the label positions have to inset by the same amount.
public enum IntensityScale {
    public static let minimum = 60
    public static let maximum = 110
    /// The UISlider thumb's radius at the default metrics (28 pt thumb).
    public static let thumbRadius: Double = 14
    public static let tickValues = [60, 100, 110]

    /// Where the value sits on the 0…1 domain of the scale.
    public static func fraction(_ value: Double) -> Double {
        let span = Double(maximum - minimum)
        guard span > 0 else { return 0 }
        let clamped = Swift.min(Swift.max(value, Double(minimum)), Double(maximum))
        return (clamped - Double(minimum)) / span
    }

    /// The tick's centre, in points, along a track of `trackWidth` — the
    /// same mapping the thumb uses.
    public static func center(value: Double, trackWidth: Double) -> Double {
        let inset = Swift.min(thumbRadius, trackWidth / 2)
        let usable = Swift.max(0, trackWidth - inset * 2)
        return inset + fraction(value) * usable
    }

    public static let step = 5

    /// The inverse of `center`: a touch at `x` → the nearest 5 % step,
    /// clamped to the scale. Dragging and the drawn thumb share one mapping.
    public static func value(atX x: Double, trackWidth: Double) -> Int {
        let inset = Swift.min(thumbRadius, trackWidth / 2)
        let usable = Swift.max(0, trackWidth - inset * 2)
        guard usable > 0 else { return minimum }
        let fraction = Swift.min(1, Swift.max(0, (x - inset) / usable))
        let raw = Double(minimum) + fraction * Double(maximum - minimum)
        let snapped = Int((raw / Double(step)).rounded()) * step
        return Swift.min(maximum, Swift.max(minimum, snapped))
    }

    /// VoiceOver increment/decrement: one 5 % step, clamped.
    public static func stepped(_ value: Int, by steps: Int) -> Int {
        Swift.min(maximum, Swift.max(minimum, value + steps * step))
    }
}

/// #1038 H2 / picker proposal: the movement rows carry a short area hint so
/// the list reads as climbing movements, not identifiers. The hints are
/// deliberately conservative, general vocabulary — no anatomy claims beyond
/// the area a climber names the movement by.
public enum MovementAreaHint {
    public static func hint(for movement: String) -> String? {
        let normalized = movement
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }
        for entry in table where normalized.contains(entry.key) || entry.key.contains(normalized) {
            return entry.value
        }
        return nil
    }

    private static let table: [(key: String, value: String)] = [
        ("fdp", "Fingers · deep flexor"),
        ("fds", "Fingers · superficial flexor"),
        ("half crimp", "Fingers · half crimp grip"),
        ("open hand", "Fingers · open-hand grip"),
        ("pinch", "Thumb and fingers"),
        ("sloper", "Fingers · open grip"),
        ("edge block", "Fingers · block hold"),
        ("wrist", "Forearm"),
        ("pull-up", "Back and arms"),
        ("lock-off", "Back and arms"),
        ("campus", "Back and arms"),
        ("core", "Trunk")
    ]
}

/// #1038 (Conductor sheet review): the Free hold chart's kg axis, fitted to
/// what is drawn.
///
/// The guided chart keeps its zero-based domain (`ForceChartYDomain`: a stage
/// band needs its absolute level). Free hold has no band, so a zero-based
/// axis parked a late-hold window (26–30 kg) in the top fifth of the card,
/// and its unlabelled quarter-lines (9 / 18 / 27 kg) made the Best line at
/// 31.5 read as "about 35". The fit:
/// - spans the drawn samples AND the Best line (the line is always on the
///   canvas, before the first sample too);
/// - starts at 0 kg when the data comes near zero (the first seconds of a
///   pull, while the ramp is most of the window): a floor under a third of
///   the top is not worth a broken axis. The extent it fits is the hold, not
///   the ramp (`holdExtent`);
/// - never spans less than `minimumSpanKilograms`, so a steady hold's tremor
///   is not blown up into drama;
/// - snaps both ends to a whole-kg step (1 / 2 / 5 / 10 …), so every gridline
///   is a round number, at most four are labelled, and the scale moves in
///   whole steps a few times a pull, not every frame.
public struct FreeHoldChartDomain: Equatable, Sendable {
    public static let floorKilograms = 10.0
    public static let minimumSpanKilograms = 8.0
    public static let paddingFraction = 0.1
    public static let zeroSnapFraction = 0.35
    public static let maxIntervals = 4
    /// Outward snapping may add up to one interval (24–33 kg in steps of 2).
    public static let maxSnappedIntervals = 5.0

    public let lower: Double
    public let upper: Double
    public let step: Double

    /// - Parameters:
    ///   - lowKilograms / highKilograms: the drawn samples' range (nil when
    ///     nothing is drawn yet).
    ///   - referenceKilograms: the dashed Best line, if any.
    public init(lowKilograms: Double?, highKilograms: Double?, referenceKilograms: Double?) {
        let top = max(Self.floorKilograms, highKilograms ?? 0, referenceKilograms ?? 0)
        var bottom = min(lowKilograms ?? 0, referenceKilograms ?? .infinity)
        if bottom <= top * Self.zeroSnapFraction { bottom = 0 }
        let span = max(top - bottom, Self.minimumSpanKilograms)
        let rawUpper = top + span * Self.paddingFraction
        var rawLower = bottom == 0 ? 0 : max(0, bottom - span * Self.paddingFraction)
        if rawUpper - rawLower < Self.minimumSpanKilograms {
            rawLower = max(0, rawUpper - Self.minimumSpanKilograms)
        }
        // Snap outward to the step; a snap that adds an interval re-picks
        // the step (two rounds settle every case).
        var step = Self.niceStep(for: rawUpper - rawLower)
        var lower = (rawLower / step).rounded(.down) * step
        var upper = (rawUpper / (step / 2) - 1e-9).rounded(.up) * (step / 2)
        if (upper - lower) / step > Self.maxSnappedIntervals {
            step = Self.niceStep(for: upper - lower)
            lower = (rawLower / step).rounded(.down) * step
            upper = (rawUpper / (step / 2) - 1e-9).rounded(.up) * (step / 2)
        }
        self.lower = lower
        self.upper = upper
        self.step = step
    }

    /// Round-number gridlines above the bottom edge (an edge label would
    /// clip); a line within 4 % of the top is skipped for the same reason.
    /// A fitted axis that starts above 0 shows it by its first label (25,
    /// not 10), never by pretending to start at 0.
    public var ticks: [Double] {
        var result: [Double] = []
        var value = lower + step
        while value <= upper - (upper - lower) * 0.04 + 1e-9 {
            result.append((value * 1_000).rounded() / 1_000)
            value += step
        }
        return result
    }

    /// Share of the lowest samples the fit leaves out: the climb from 0 at
    /// the start of a pull and the drop at release.
    public static let rampExclusionFraction = 0.05

    /// The extent the axis fits: the HOLD, not the ramp. A saved pull starts
    /// at 0 kg, so fitting its true minimum parked the whole plateau in the
    /// top sixth of the card (the same squash as the late-hold window). The
    /// lowest 5 % of samples are left out; they run off the bottom edge, and
    /// the axis says it does not start at 0 by its first label. The high is
    /// the true maximum: the peak is never cut. Early in a pull, while the
    /// ramp is still most of the window, the low stays near 0 and the axis
    /// stays zero-based.
    public static func holdExtent(of kilograms: [Double]) -> (low: Double, high: Double)? {
        guard !kilograms.isEmpty else { return nil }
        let sorted = kilograms.sorted()
        let index = Int((Double(sorted.count - 1) * rampExclusionFraction).rounded(.down))
        return (sorted[index], sorted[sorted.count - 1])
    }

    /// 0 at the bottom edge, 1 at the top; values under the floor sit on it.
    public func fraction(of kilograms: Double) -> Double {
        Self.fraction(of: kilograms, lower: lower, upper: upper)
    }

    /// The one y-mapping every force trace uses (guided: `lower` 0, so the
    /// zero-based domain maps exactly as before).
    public static func fraction(of kilograms: Double, lower: Double, upper: Double) -> Double {
        guard upper > lower, kilograms.isFinite else { return 0 }
        return (max(lower, kilograms) - lower) / (upper - lower)
    }

    static func niceStep(for span: Double) -> Double {
        guard span.isFinite, span > 0 else { return 5 }
        let magnitude = pow(10, (log10(span / Double(maxIntervals))).rounded(.down))
        // Whole kg (no 2.5 / 7.5 labels) — the guided scale keeps its own.
        return [1.0, 2.0, 5.0, 10.0]
            .map { $0 * magnitude }
            .first { span / $0 <= Double(maxIntervals) } ?? 10 * magnitude
    }
}
