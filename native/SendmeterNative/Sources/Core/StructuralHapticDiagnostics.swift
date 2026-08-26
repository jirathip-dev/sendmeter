/// Launch-selectable, DEBUG-only A/B policy for the native structural-haptics
/// investigation (#816). The app is responsible for keeping the resolver
/// behind `#if DEBUG`; the `debugBuild` argument makes that release boundary
/// explicit and directly testable in this pure module.
public enum StructuralHapticDiagnosticMode: String, CaseIterable, Equatable, Sendable {
    /// No diagnostic argument was supplied. This is the shipped default.
    case normal
    /// A: the current structural haptic behavior, with a visible diagnostic label.
    case control
    /// B: disable only the root default-button structural gesture.
    case rootGestureDisabled
    /// B′: keep the root gesture, but disable explicit HapticTapModifier paths.
    case explicitTapDisabled

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
        default:
            return .normal
        }
    }

    public var tapPolicy: StructuralHapticTapPolicy {
        switch self {
        case .normal, .control:
            return .allEnabled
        case .rootGestureDisabled:
            return StructuralHapticTapPolicy(
                rootDefaultEnabled: false,
                explicitEnabled: true
            )
        case .explicitTapDisabled:
            return StructuralHapticTapPolicy(
                rootDefaultEnabled: true,
                explicitEnabled: false
            )
        }
    }

    public var isDeviceDiagnostic: Bool {
        self != .normal
    }

    public var displayLabel: String? {
        switch self {
        case .normal:
            return nil
        case .control:
            return "TOUCH A/B DIAGNOSTIC • A — structural haptics ON"
        case .rootGestureDisabled:
            return "TOUCH A/B DIAGNOSTIC • B — root structural gesture OFF"
        case .explicitTapDisabled:
            return "TOUCH A/B DIAGNOSTIC • B′ — explicit HapticTapModifier OFF"
        }
    }
}

public struct StructuralHapticTapPolicy: Equatable, Sendable {
    public let rootDefaultEnabled: Bool
    public let explicitEnabled: Bool

    public init(rootDefaultEnabled: Bool, explicitEnabled: Bool) {
        self.rootDefaultEnabled = rootDefaultEnabled
        self.explicitEnabled = explicitEnabled
    }

    public static let allEnabled = Self(
        rootDefaultEnabled: true,
        explicitEnabled: true
    )
}
