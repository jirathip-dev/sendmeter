import Foundation

/// Unit presentation preference for the native app (#722). Mirrors the web's
/// `units` preference (metric/imperial) and `AppTheme`'s storage pattern:
/// persisted in UserDefaults under `sendmeter.native.units`, with the value
/// kept as a String so an unknown/missing entry never traps the app.
/// The preference is presentation-only for now — the shared conversion layer
/// that applies it across Force/readiness/weight display is a separate change.
public enum UnitsPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case metric
    case imperial

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .metric: return "Metric"
        case .imperial: return "Imperial"
        }
    }
}

public enum AppUnits {
    public static let storageKey = "sendmeter.native.units"

    /// Anything other than a stored "imperial" resolves to metric — the
    /// default unit system for a climbing/performance app.
    public static func normalize(_ value: String?) -> UnitsPreference {
        UnitsPreference(rawValue: value ?? "") ?? .metric
    }

    public static func storedChoice(defaults: UserDefaults = .standard) -> UnitsPreference {
        normalize(defaults.string(forKey: storageKey))
    }

    public static func store(_ choice: UnitsPreference, defaults: UserDefaults = .standard) {
        defaults.set(choice.rawValue, forKey: storageKey)
    }
}
