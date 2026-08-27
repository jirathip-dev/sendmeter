/// How a structural tap is recognized. The production path deliberately uses
/// SwiftUI's native tap/button recognition instead of a zero-distance drag,
/// so a vertical scroll can win immediately. The legacy case exists only for
/// the DEBUG-only #816 diagnostic arms.
public enum StructuralHapticAttachment: Equatable, Sendable {
    case scrollSafe
    case legacyZeroDistance
}

/// Launch-selectable, DEBUG-only A/B policy for the native structural-haptics
/// investigation (#816). The app is responsible for keeping the resolver
/// behind `#if DEBUG`; the `debugBuild` argument makes that release boundary
/// explicit and directly testable in this pure module.
public enum StructuralHapticDiagnosticMode: String, CaseIterable, Equatable, Sendable {
    /// No diagnostic argument was supplied. This is the scroll-safe shipped path.
    case normal
    /// A: a faithful legacy structural-gesture control, with a visible label.
    case control
    /// B: disable only the legacy root default-button structural gesture.
    case rootGestureDisabled
    /// B′: keep the legacy root gesture, but disable explicit HapticTapModifier paths.
    case explicitTapDisabled
    /// B+B′: remove every legacy structural gesture attachment.
    case allStructuralGesturesDisabled

    public static let launchArgument = "-sendmeter-structural-haptics"

    public static func resolve(arguments: [String], debugBuild: Bool) -> Self {
        guard debugBuild,
              let index = arguments.firstIndex(of: launchArgument),
              arguments.indices.contains(arguments.index(after: index))
        else {
            return .normal
        }

        switch arguments[arguments.index(after: index)].lowercased() {
        case "a":
            return .control
        case "b":
            return .rootGestureDisabled
        case "b-prime", "b′":
            return .explicitTapDisabled
        case "b-plus-prime", "b+b-prime", "b+b′":
            return .allStructuralGesturesDisabled
        default:
            return .normal
        }
    }

    public var tapPolicy: StructuralHapticTapPolicy {
        switch self {
        case .normal:
            return .allEnabled
        case .control:
            return StructuralHapticTapPolicy(
                rootDefaultEnabled: true,
                explicitEnabled: true,
                attachment: .legacyZeroDistance
            )
        case .rootGestureDisabled:
            return StructuralHapticTapPolicy(
                rootDefaultEnabled: false,
                explicitEnabled: true,
                attachment: .legacyZeroDistance
            )
        case .explicitTapDisabled:
            return StructuralHapticTapPolicy(
                rootDefaultEnabled: true,
                explicitEnabled: false,
                attachment: .legacyZeroDistance
            )
        case .allStructuralGesturesDisabled:
            return StructuralHapticTapPolicy(
                rootDefaultEnabled: false,
                explicitEnabled: false,
                attachment: .legacyZeroDistance
            )
        }
    }

    public var usesLegacyStructuralGesture: Bool {
        tapPolicy.attachment == .legacyZeroDistance
    }

    public var displayLabel: String? {
        switch self {
        case .normal:
            return nil
        case .control:
            return "TOUCH A/B DIAGNOSTIC • A — legacy control"
        case .rootGestureDisabled:
            return "TOUCH A/B DIAGNOSTIC • B — legacy root gesture OFF"
        case .explicitTapDisabled:
            return "TOUCH A/B DIAGNOSTIC • B′ — legacy explicit gesture OFF"
        case .allStructuralGesturesDisabled:
            return "TOUCH A/B DIAGNOSTIC • B+B′ — all legacy gestures OFF"
        }
    }
}

public struct StructuralHapticTapPolicy: Equatable, Sendable {
    public let rootDefaultEnabled: Bool
    public let explicitEnabled: Bool
    public let attachment: StructuralHapticAttachment

    public init(
        rootDefaultEnabled: Bool,
        explicitEnabled: Bool,
        attachment: StructuralHapticAttachment = .scrollSafe
    ) {
        self.rootDefaultEnabled = rootDefaultEnabled
        self.explicitEnabled = explicitEnabled
        self.attachment = attachment
    }

    public static let allEnabled = Self(
        rootDefaultEnabled: true,
        explicitEnabled: true,
        attachment: .scrollSafe
    )
}
