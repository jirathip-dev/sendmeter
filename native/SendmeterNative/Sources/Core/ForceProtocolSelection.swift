import Foundation

/// #710: the single-armed mode for the native Force RECORDING CONTEXT
/// protocol selector. Exactly one of free hold / a suggested zone protocol /
/// a suggested maintenance protocol / a saved user preset is active at a time
/// — the web's `withZoneSelected` / `withPresetSelected` mutual-exclusivity
/// rule (#296). ForceView maps this to its four selection `@State`s
/// (`selectedPresetID`, `zoneArmedPreset`, `armedZoneQuality`,
/// `armedMaintenanceZone`).
public enum ForceProtocolSelection: Equatable, Sendable {
    case free
    case suggestedZone(ZoneQuality)
    case suggestedMaintenance(RecordedZone)
    case savedPreset(UUID)

    /// The suggested protocol this selection arms, or nil for free/saved.
    public var suggested: SuggestedProtocol? {
        switch self {
        case .suggestedZone(let quality): return .zone(quality)
        case .suggestedMaintenance(let zone): return .maintenance(zone)
        case .free, .savedPreset: return nil
        }
    }
}

/// #710: the suggested protocols the RECORDING CONTEXT selector offers — the
/// four trainable zone qualities plus the Warm-up/Prehab maintenance
/// protocols (the web's `TargetZonesCard` box chips).
public enum SuggestedProtocol: Equatable, Sendable {
    case zone(ZoneQuality)
    case maintenance(RecordedZone)
}

/// #710: the pure mutually-exclusive selector reducer — the native sibling of
/// the web's `withZoneSelected` / `withPresetSelected`. Tapping the
/// already-active suggested/saved chip deselects back to free (web BoxChip
/// `onSelect(null)` / `onClear()`), and tapping any other target clears the
/// rest so exactly one mode is armed at a time. Kept pure so the
/// single-armed invariant is unit-tested rather than only exercised by the
/// view (#710 review).
public enum ForceProtocolPicker {
    public static func next(
        current: ForceProtocolSelection,
        tapped: ForceProtocolSelection
    ) -> ForceProtocolSelection {
        if tapped == current { return .free }
        return tapped
    }
}
