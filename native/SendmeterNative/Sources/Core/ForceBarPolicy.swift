import Foundation

/// #1028 D + F: the Force tab's sticky bottom bar — the ONLY place for
/// device status and Connect/Reconnect (F1), carrying the Guided |
/// Hands-free mode switch (F2) and the one big action that follows the
/// mode and the device:
///
///   Guided     → Connect → Start (the armed protocol) → Stop & save
///   Hands-free → Connect → Arm → (pull) → saves on release
///
/// Pure decision logic (no SwiftUI) so every state is unit-tested.
public enum ForceBarMode: String, CaseIterable, Sendable {
    case guided
    case handsFree

    public var title: String {
        switch self {
        case .guided: return "Guided"
        case .handsFree: return "Hands-free"
        }
    }
}

/// The transport states the bar distinguishes (mirrors
/// `TindeqBluetooth.Status` without importing the platform layer).
public enum ForceBarDevice: Equatable, Sendable {
    case disconnected
    /// The link dropped mid-use (`.interrupted`). Same word as
    /// `disconnected` — D3's "one word for the disconnected state" — but
    /// the action reads Reconnect.
    case interrupted
    case bluetoothOff
    case connecting
    case connected
    case measuring
}

public struct ForceBarInput: Equatable, Sendable {
    public var device: ForceBarDevice
    public var mode: ForceBarMode
    /// The armed guided protocol's name, if any.
    public var armedProtocolName: String?
    public var handsFreeArmed: Bool
    public var handsFreeMeasuring: Bool
    /// #1004: a completed or salvaged pull is held unsaved.
    public var hasHeldPull: Bool
    /// A guided session owns the device (running or minimized).
    public var guidedSessionActive: Bool
    public var saving: Bool
    /// A pull has been recorded on this account before (Reconnect vs Connect).
    public var hasRecordings: Bool

    public init(
        device: ForceBarDevice,
        mode: ForceBarMode,
        armedProtocolName: String? = nil,
        handsFreeArmed: Bool = false,
        handsFreeMeasuring: Bool = false,
        hasHeldPull: Bool = false,
        guidedSessionActive: Bool = false,
        saving: Bool = false,
        hasRecordings: Bool = false
    ) {
        self.device = device
        self.mode = mode
        self.armedProtocolName = armedProtocolName
        self.handsFreeArmed = handsFreeArmed
        self.handsFreeMeasuring = handsFreeMeasuring
        self.hasHeldPull = hasHeldPull
        self.guidedSessionActive = guidedSessionActive
        self.saving = saving
        self.hasRecordings = hasRecordings
    }
}

public enum ForceBarTone: Equatable, Sendable {
    case offline
    case working
    case ready
    case armed
    case live
    case attention
}

public enum ForceBarAction: Equatable, Sendable {
    case connect
    case reconnect
    case openBluetoothSettings
    case cancelConnecting
    /// Guided with nothing armed: open the protocol list.
    case chooseProtocol
    case startGuided
    case resumeGuided
    case armHandsFree
    case disarmHandsFree
    case stopAndSave
    /// #1004: settle the held pull (Discard stays on the Progressor card).
    case saveHeldPull
}

public struct ForceBarState: Equatable, Sendable {
    /// One word (or two) for the device + loop state.
    public let status: String
    public let tone: ForceBarTone
    public let action: ForceBarAction
    public let actionTitle: String
    public let actionSystemImage: String
    /// Filled (primary) vs outlined (secondary) big action.
    public let actionIsPrimary: Bool
    public let actionEnabled: Bool
    /// The mode switch locks while a pull, an arm or a guided session owns
    /// the device.
    public let modeLocked: Bool
    /// What the leading label shows: the armed protocol (Guided) or the
    /// free-pull line (Hands-free).
    public let subject: String
    /// Guided mode: tapping the subject opens the protocol list (D2).
    public let subjectOpensProtocolList: Bool
}

public enum ForceBarPolicy {
    /// D3: the one word for "no Progressor link", everywhere.
    public static let disconnectedWord = "Disconnected"
    public static let nothingArmedSubject = "Choose a protocol"
    public static let freePullSubject = "Free pull"

    public static func state(_ input: ForceBarInput) -> ForceBarState {
        let modeLocked = input.handsFreeArmed || input.handsFreeMeasuring
            || input.device == .measuring || input.guidedSessionActive || input.saving
        let subject: String
        let opensList: Bool
        switch input.mode {
        case .guided:
            subject = input.armedProtocolName ?? nothingArmedSubject
            opensList = !input.guidedSessionActive
        case .handsFree:
            subject = freePullSubject
            opensList = false
        }

        func make(
            _ status: String,
            _ tone: ForceBarTone,
            _ action: ForceBarAction,
            _ title: String,
            _ image: String,
            primary: Bool = true,
            enabled: Bool = true
        ) -> ForceBarState {
            ForceBarState(
                status: status,
                tone: tone,
                action: action,
                actionTitle: title,
                actionSystemImage: image,
                actionIsPrimary: primary,
                actionEnabled: enabled,
                modeLocked: modeLocked,
                subject: subject,
                subjectOpensProtocolList: opensList
            )
        }

        // A running guided session owns the device in either mode.
        if input.guidedSessionActive {
            return make("Guided session", .live, .resumeGuided, "Resume", "arrow.up.left.and.arrow.down.right")
        }
        // A live pull: Stop & save, in either mode (the hands-free loop also
        // saves on release; the button is the manual stop).
        if input.device == .measuring || input.handsFreeMeasuring {
            return make(
                "Recording",
                .live,
                .stopAndSave,
                "Stop & save",
                "stop.fill",
                enabled: !input.saving
            )
        }
        // #1004: a held pull is settled before anything new starts.
        if input.hasHeldPull {
            return make(
                "Unsaved pull",
                .attention,
                .saveHeldPull,
                "Save pull",
                "square.and.arrow.down",
                enabled: !input.saving
            )
        }

        switch input.device {
        case .bluetoothOff:
            return make("Bluetooth off", .attention, .openBluetoothSettings, "Settings", "gear", primary: false)
        case .connecting:
            return make("Connecting…", .working, .cancelConnecting, "Cancel", "xmark", primary: false)
        case .disconnected:
            return input.hasRecordings
                ? make(disconnectedWord, .offline, .reconnect, "Reconnect", "antenna.radiowaves.left.and.right")
                : make(disconnectedWord, .offline, .connect, "Connect", "antenna.radiowaves.left.and.right")
        case .interrupted:
            return make(disconnectedWord, .attention, .reconnect, "Reconnect", "antenna.radiowaves.left.and.right")
        case .connected, .measuring:
            switch input.mode {
            case .guided:
                if input.armedProtocolName == nil {
                    return make("Connected", .ready, .chooseProtocol, "Choose", "list.bullet", primary: false)
                }
                return make("Connected", .ready, .startGuided, "Start", "play.fill")
            case .handsFree:
                if input.handsFreeArmed {
                    return make("Armed · pull to start", .armed, .disarmHandsFree, "Disarm", "xmark", primary: false)
                }
                return make("Connected", .ready, .armHandsFree, "Arm", "scope")
            }
        }
    }
}

/// #1028 F3: what the recording-context card may honestly claim. It never
/// says "Live readout" or "Armed now" without a live link, and the
/// hands-free line follows the bar's mode instead of always claiming it.
public struct ForceContextReadiness: Equatable, Sendable {
    public enum Claim: Equatable, Sendable {
        /// No live link: "Waiting for Progressor".
        case waitingForProgressor
        /// Linked, Guided mode: the bar's Start runs the armed protocol.
        case guidedReady
        /// Linked, Hands-free mode, not yet armed.
        case handsFreeReady
        /// Linked, Hands-free armed: pull to start, release to stop.
        case handsFreeArmed
    }

    public let claim: Claim
    /// The bar's own word for the way out ("Connect" / "Reconnect"), so the
    /// card and the bar never disagree.
    private let connectWord: String
    private let device: ForceBarDevice

    public init(
        device: ForceBarDevice,
        mode: ForceBarMode,
        handsFreeArmed: Bool,
        connectWord: String = "Connect"
    ) {
        self.device = device
        self.connectWord = connectWord
        switch device {
        case .disconnected, .interrupted, .bluetoothOff, .connecting:
            claim = .waitingForProgressor
        case .connected, .measuring:
            switch mode {
            case .guided: claim = .guidedReady
            case .handsFree: claim = handsFreeArmed ? .handsFreeArmed : .handsFreeReady
            }
        }
    }

    public init(claim: Claim) {
        self.claim = claim
        self.connectWord = "Connect"
        self.device = claim == .waitingForProgressor ? .disconnected : .connected
    }

    /// The "Live readout" chip renders only with a live link.
    public var showsLiveReadout: Bool { claim != .waitingForProgressor }

    public var title: String {
        switch claim {
        case .waitingForProgressor: return "Waiting for Progressor"
        case .guidedReady: return "Ready · Start from the bar"
        case .handsFreeReady: return "Pull to start · release to stop"
        case .handsFreeArmed: return "Pull to start · release to stop"
        }
    }

    public var detail: String {
        switch claim {
        case .waitingForProgressor:
            switch device {
            case .bluetoothOff: return "Turn Bluetooth on in Settings"
            case .connecting: return "Connecting…"
            default: return "\(connectWord) from the bar below"
            }
        case .guidedReady: return "After Start, each rep begins when you pull"
        case .handsFreeReady: return "Arm from the bar below"
        case .handsFreeArmed: return "Armed now · no confirmation step"
        }
    }

    public var systemImage: String {
        switch claim {
        case .waitingForProgressor: return "antenna.radiowaves.left.and.right.slash"
        case .guidedReady: return "play.circle"
        case .handsFreeReady, .handsFreeArmed: return "hand.draw"
        }
    }

    /// The mode chip on the armed hero.
    public var modeChip: String {
        switch claim {
        case .handsFreeReady, .handsFreeArmed: return "Hands-free"
        case .waitingForProgressor, .guidedReady: return "Guided"
        }
    }
}

/// F4: the live hold-time label.
public enum ForceReadoutFormat {
    public static func hold(milliseconds: Double) -> String {
        let seconds = max(0, milliseconds) / 1_000
        return "Hold " + seconds.formatted(.number.precision(.fractionLength(1))) + " s"
    }
}

/// #1028 F4: the trace chart's light kg scale — at most four "nice" ticks
/// (1/2/2.5/5 × 10ⁿ) above zero, labels only, hairline guides.
public enum ForceTraceScale {
    public static let maxTicks = 4

    public static func ticks(maxValue: Double) -> [Double] {
        guard maxValue.isFinite, maxValue > 0 else { return [] }
        let rough = maxValue / Double(maxTicks)
        let magnitude = pow(10, floor(log10(rough)))
        let step = [1.0, 2.0, 2.5, 5.0, 10.0]
            .map { $0 * magnitude }
            .first { maxValue / $0 <= Double(maxTicks) } ?? 10 * magnitude
        var result: [Double] = []
        var value = step
        // Skip a tick that would sit on the top edge (its label would clip).
        while value <= maxValue * 0.97, result.count < maxTicks {
            result.append(value)
            value += step
        }
        return result
    }

    public static func label(_ kilograms: Double, isTop: Bool) -> String {
        let number = kilograms.rounded() == kilograms
            ? kilograms.formatted(.number.precision(.fractionLength(0)))
            : kilograms.formatted(.number.precision(.fractionLength(1)))
        return isTop ? "\(number) kg" : number
    }
}
