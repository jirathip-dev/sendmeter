import Foundation

/// #710: the single-armed mode for the native Force RECORDING CONTEXT
/// protocol selector. Exactly one of free hold / a suggested zone protocol /
/// a suggested maintenance protocol / the resisted-movement (reverse-action)
/// suggestion / a saved user preset is active at a time — the web's
/// `withZoneSelected` / `withPresetSelected` mutual-exclusivity rule (#296).
/// ForceView maps this to its selection `@State`s (`selectedPresetID`,
/// `zoneArmedPreset`, `armedZoneQuality`, `armedMaintenanceZone`,
/// `movementArmedPreset`).
public enum ForceProtocolSelection: Equatable, Sendable {
    case free
    case suggestedZone(ZoneQuality)
    case suggestedMaintenance(RecordedZone)
    /// #711: the resisted-movement (reverse-action) measurement mode. Arming
    /// it builds the transient `Movement Starter` preset (web
    /// `MOVEMENT_STARTER_PRESET`), which launches as a reverse-action run.
    case movement
    case savedPreset(UUID)

    /// The suggested protocol this selection arms, or nil for free/saved.
    public var suggested: SuggestedProtocol? {
        switch self {
        case .suggestedZone(let quality): return .zone(quality)
        case .suggestedMaintenance(let zone): return .maintenance(zone)
        case .movement: return .movement
        case .free, .savedPreset: return nil
        }
    }
}

/// #710: the suggested protocols the RECORDING CONTEXT selector offers — the
/// four trainable zone qualities, the Warm-up/Prehab maintenance protocols
/// (the web's `TargetZonesCard` box chips), and the resisted-movement
/// suggestion (#711, the web's `Movement Starter`).
public enum SuggestedProtocol: Equatable, Sendable {
    case zone(ZoneQuality)
    case maintenance(RecordedZone)
    case movement
}

/// #711: the native sibling of the web's `ForceMeasurementMode`
/// (`"static" | "movement"`). The mode is a *presentation* of the armed
/// protocol's modality (web `forceMeasurementMode`), and choosing Movement
/// arms a reverse-action protocol (web `forceProtocolMode`).
public enum ForceMeasurementMode: String, Sendable, Equatable {
    case `static`
    case movement

    public init(protocolMode: ForceProtocolMode) {
        self = protocolMode == .reverseAction ? .movement : .static
    }

    /// Mirrors web `forceProtocolMode(_:)`.
    public var protocolMode: ForceProtocolMode {
        switch self {
        case .static: return .hold
        case .movement: return .reverseAction
        }
    }

    /// The badge label — the native `ProtocolBadge` (web `MOVEMENT_LABEL` /
    /// `STATIC`).
    public var badgeLabel: String {
        switch self {
        case .static: return "STATIC"
        case .movement: return "MOVEMENT"
        }
    }
}

/// #711: shared movement-terminology labels — the native sibling of the web's
/// `movementProtocol.ts` constants. Kept in Core so the recording-context and
/// progress layers cannot drift apart.
public enum MovementTerminology {
    public static let resistedMovement = "Resisted movement"
    public static let movement = "MOVEMENT"
    public static let concentric = "Concentric"
    public static let eccentric = "Eccentric"
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
