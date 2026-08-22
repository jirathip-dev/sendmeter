import Foundation

/// Slice 1 of #543: per-exercise policy for which `TindeqSide` values are
/// valid, so a selector can adapt to the exercise instead of always offering
/// all four choices. Legacy/unconfigured exercises (including a missing
/// registry row) default to `unilateralOrBilateral` — the pre-#543 behavior
/// of allowing every side. `""` ("unspecified") and `both` stay distinct
/// everywhere: historical empty sides are never reinterpreted as `both`.
///
/// Swift port of `src/lib/sideMode.ts` (web #584).
public enum ExerciseSideMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case unilateralOrBilateral = "unilateral_or_bilateral"
    case unilateralOnly = "unilateral_only"
    case bilateralOnly = "bilateral_only"
    case notApplicable = "not_applicable"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .unilateralOrBilateral: return "Either or both"
        case .unilateralOnly: return "One side only"
        case .bilateralOnly: return "Both sides only"
        case .notApplicable: return "Not applicable"
        }
    }

    /// The default for a legacy/unconfigured exercise — every side valid.
    public static let defaultMode: ExerciseSideMode = .unilateralOrBilateral

    /// Unknown/legacy mode strings (including a value that predates a later
    /// mode being added) fall back to the default, never to an arbitrary
    /// guess. Mirrors `normalizeSideMode`.
    public static func normalize(_ mode: String?) -> ExerciseSideMode {
        guard let mode, let parsed = ExerciseSideMode(rawValue: mode) else {
            return ExerciseSideMode.defaultMode
        }
        return parsed
    }
}

/// The shared side-applicability policy. Views and save paths must consult
/// this rather than hardcoding mode→side mappings — it is the single source
/// of truth for what side choices an exercise offers.
public enum ExerciseSidePolicy {
    /// The valid `TindeqSide` values for a mode. `""` (unspecified) is always
    /// included — it means "not chosen yet", not "not applicable". Mirrors
    /// `allowedSides`.
    public static func allowedSides(_ mode: ExerciseSideMode) -> [TindeqSide] {
        switch mode {
        case .unilateralOrBilateral: return [.unspecified, .left, .right, .both]
        case .unilateralOnly: return [.unspecified, .left, .right]
        case .bilateralOnly: return [.unspecified, .both]
        case .notApplicable: return [.unspecified]
        }
    }

    public static func isSideAllowed(_ mode: ExerciseSideMode, _ side: TindeqSide) -> Bool {
        allowedSides(mode).contains(side)
    }

    /// Deterministic fallback for a remembered side that's no longer valid
    /// under `mode` (e.g. the exercise's side mode changed, or a preset
    /// carries a side from before this exercise had a mode). `both` and `""`
    /// are never substituted for each other. Mirrors `normalizeSide`.
    public static func normalizeSide(_ mode: ExerciseSideMode, _ side: TindeqSide) -> TindeqSide {
        if isSideAllowed(mode, side) { return side }
        switch mode {
        case .bilateralOnly: return .both
        case .notApplicable: return .unspecified
        case .unilateralOnly: return .unspecified
        // Unreachable: every side is allowed for this mode.
        case .unilateralOrBilateral: return side
        }
    }

    /// The canonical side to stamp on a NEW recording under `mode`. Distinct
    /// from `normalizeSide` (which keeps `""` as "not chosen yet" for the
    /// selector): a bilateral-only exercise is inherently both-sided, so an
    /// unchosen side records as `both`. `not_applicable` always records the
    /// no-side value.
    public static func recordedSide(_ mode: ExerciseSideMode, _ side: TindeqSide) -> TindeqSide {
        switch mode {
        case .bilateralOnly: return .both
        case .notApplicable: return .unspecified
        case .unilateralOnly, .unilateralOrBilateral: return normalizeSide(mode, side)
        }
    }
}

/// Device-local persistence for a tag's side mode. The native app keeps the
/// choice off the account (web parity for the concept, but deliberately not
/// account-migrated) — same UserDefaults pattern as `AppTheme`.
public enum TagSideModeStore {
    public static func storageKey(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return "sendmeter.native.side-mode.\(trimmed)"
    }

    public static func storedMode(for name: String, defaults: UserDefaults = .standard) -> ExerciseSideMode {
        ExerciseSideMode.normalize(defaults.string(forKey: storageKey(for: name)))
    }

    public static func store(_ mode: ExerciseSideMode, for name: String, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: storageKey(for: name))
    }

    public static func remove(for name: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey(for: name))
    }

    /// Every configured tag → side mode, for the exercise manager. A tag with
    /// no stored value is intentionally absent (reads as the default).
    public static func allStoredModes(defaults: UserDefaults = .standard) -> [String: ExerciseSideMode] {
        var out: [String: ExerciseSideMode] = [:]
        let prefix = "sendmeter.native.side-mode."
        for (key, value) in defaults.dictionaryRepresentation() {
            guard let value = value as? String,
                  let mode = ExerciseSideMode(rawValue: value),
                  key.hasPrefix(prefix) else { continue }
            let tag = String(key.dropFirst(prefix.count))
            guard !tag.isEmpty else { continue }
            out[tag] = mode
        }
        return out
    }
}
