import Foundation

/// Appearance preference — web parity for the native app (#631): System /
/// Light / Dark, persisted in UserDefaults under `sendmeter.native.theme`
/// (the web's `theme` localStorage key, namespaced for native). The choice
/// is applied pre-paint by the App scene's `preferredColorScheme`; this type
/// owns the storage + resolution logic so the round-trip is unit-tested.
public enum AppThemeChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

public enum AppTheme {
    public static let storageKey = "sendmeter.native.theme"

    /// Anything other than a stored "light"/"dark" resolves to system —
    /// mirrors the web's `normalizeThemeChoice` (an unknown or missing value
    /// must never trap the app in an unreadable scheme).
    public static func normalize(_ value: String?) -> AppThemeChoice {
        if value == AppThemeChoice.light.rawValue { return .light }
        if value == AppThemeChoice.dark.rawValue { return .dark }
        return .system
    }

    public static func storedChoice(defaults: UserDefaults = .standard) -> AppThemeChoice {
        normalize(defaults.string(forKey: storageKey))
    }

    public static func store(_ choice: AppThemeChoice, defaults: UserDefaults = .standard) {
        defaults.set(choice.rawValue, forKey: storageKey)
    }

    /// Resolve the choice against the system appearance — mirrors the web's
    /// `resolvedTheme`: an explicit choice wins, system follows the OS.
    public static func resolved(choice: AppThemeChoice, prefersDark: Bool) -> AppThemeChoice {
        switch choice {
        case .light, .dark: return choice
        case .system: return prefersDark ? .dark : .light
        }
    }
}
