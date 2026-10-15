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
        case .waiting: return "Release to stop the recording"
        case .recording: return "Release to stop · saved automatically"
        case .saved: return "Pull again for the next recording"
        }
    }

    public var symbol: String {
        switch self {
        case .waiting, .recording: return "hand.draw.fill"
        case .saved: return "checkmark.circle.fill"
        }
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
        ("wrist", "Wrist"),
        ("pull-up", "Back and arms"),
        ("lock-off", "Back and arms"),
        ("campus", "Back and arms"),
        ("core", "Trunk")
    ]
}
