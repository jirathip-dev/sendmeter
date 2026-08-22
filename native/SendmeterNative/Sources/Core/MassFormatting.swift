import Foundation

/// Mass display units the shared conversion layer can present.
///
/// Canonical storage is always kg (`body_mass_kg`, force loads, presets).
/// These units exist only for presentation; they are never written back.
public enum MassUnit: String, CaseIterable, Sendable {
    case kilograms
    case pounds

    /// Short symbol used in formatted output (`kg` / `lb`).
    public var symbol: String {
        switch self {
        case .kilograms: return "kg"
        case .pounds: return "lb"
        }
    }
}

/// The single shared mass conversion + formatting layer (#721).
///
/// All kg→display-unit math and the body-mass rounding live here and only
/// here — no per-component `2.20462`. It is presentation-only: a value is
/// converted for the user's chosen unit (`AppUnits.storedChoice()`), but the
/// canonical kg value is never mutated or re-stored.
///
/// Metric output is byte-identical to the pre-#721 kg rendering (one decimal,
/// e.g. `62.8 kg`), so switching between units never changes what metric
/// users see.
public enum MassFormatting {
    /// Standard kg→lb conversion factor. Isolated here so a converter, a
    /// formatter, and a round-trip all agree on the same constant.
    public static let poundsPerKilogram = 2.204_622_621_848_775

    /// The mass display unit that a preference maps to. Anything other than
    /// imperial resolves to kilograms (the app default, mirrors `AppUnits`).
    public static func unit(for preference: UnitsPreference) -> MassUnit {
        preference == .imperial ? .pounds : .kilograms
    }

    /// Convert a canonical kg value into the given display unit.
    ///
    /// Not rounded: rounding is the formatter's job, so the same converted
    /// value can be reused for both display and math without double rounding.
    public static func value(_ kilograms: Double, in unit: MassUnit) -> Double {
        switch unit {
        case .kilograms: return kilograms
        case .pounds: return kilograms * poundsPerKilogram
        }
    }

    /// Convert a display-unit value back to canonical kg. Used by the
    /// round-trip tolerance proof; storage never leaves kg so the UI does
    /// not call this.
    public static func kilograms(from value: Double, in unit: MassUnit) -> Double {
        switch unit {
        case .kilograms: return value
        case .pounds: return value / poundsPerKilogram
        }
    }

    /// One-decimal display string, e.g. `62.8 kg` / `138.5 lb`.
    public static func format(_ kilograms: Double, in unit: MassUnit) -> String {
        String(format: "%.1f %@", value(kilograms, in: unit), unit.symbol)
    }

    /// Format a canonical kg value in the unit a preference selects.
    public static func format(_ kilograms: Double, for preference: UnitsPreference) -> String {
        format(kilograms, in: unit(for: preference))
    }

    /// Format a canonical kg value using the user's currently stored choice
    /// (`AppUnits.storedChoice`). A missing/unreadable preference falls back
    /// to metric via `AppUnits.normalize`.
    public static func storedFormatted(
        _ kilograms: Double,
        defaults: UserDefaults = .standard
    ) -> String {
        format(kilograms, for: AppUnits.storedChoice(defaults: defaults))
    }
}
