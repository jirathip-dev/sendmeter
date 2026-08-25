import Foundation

/// Per-exercise policy for which side values are valid on the WATCH.
///
/// This is the watch's mirror of the iPhone's #720 `ExerciseSideMode` /
/// `ExerciseSidePolicy` (which live in `SendmeterNative` and are typed with the
/// iPhone's `TindeqSide`). The watch stores and transports sides as plain
/// strings (`"left"`, `"right"`, `"both"`, `""`), and `SendLogWatchCore` is the
/// shared layer both the watch app and the iPhone native app already depend on,
/// so the policy is expressed here in string terms and unit-tested on Linux CI.
///
/// The load-bearing contracts, pinned by `ForceSidePolicyTests`:
///  - An unconfigured / legacy exercise (missing `tindeq_tags` row, unknown
///    `side_mode`) reads as `.unilateralOrBilateral` — every side allowed.
///  - `""` ("unspecified") and `"both"` stay semantically distinct everywhere.
///    Historical empty sides are NEVER reinterpreted as `"both"`.
public enum ForceSideMode: String, Codable, CaseIterable, Sendable {
    case unilateralOrBilateral = "unilateral_or_bilateral"
    case unilateralOnly = "unilateral_only"
    case bilateralOnly = "bilateral_only"
    case notApplicable = "not_applicable"

    /// The default for legacy/unconfigured exercises — every side valid.
    public static let defaultMode: ForceSideMode = .unilateralOrBilateral

    /// Whether the exercise is sided at all. `not_applicable` exercises have no
    /// side decision to make; everything else (including `bilateral_only`) is
    /// sided. Views use this to decide whether a side summary line belongs.
    public var isSided: Bool { self != .notApplicable }

    /// Unknown/legacy mode strings fall back to the default, never to an
    /// arbitrary guess. Mirrors `normalizeSideMode` (#584 / #720).
    public static func normalize(_ mode: String?) -> ForceSideMode {
        guard let mode, let parsed = ForceSideMode(rawValue: mode) else {
            return ForceSideMode.defaultMode
        }
        return parsed
    }
}

/// The shared side-applicability policy for the watch. Views and save paths
/// must consult this rather than hardcoding mode→side mappings — it is the
/// single source of truth for what side choices an exercise offers.
public enum ForceSidePolicy {
    public static let unspecified = ""
    public static let left = "left"
    public static let right = "right"
    public static let both = "both"

    /// The valid side strings for a mode, in display order. `""` (unspecified)
    /// is always included — it means "not chosen yet", not "not applicable".
    /// Mirrors `allowedSides`.
    public static func allowedSides(_ mode: ForceSideMode) -> [String] {
        switch mode {
        case .unilateralOrBilateral: return [unspecified, left, right, both]
        case .unilateralOnly: return [unspecified, left, right]
        case .bilateralOnly: return [unspecified, both]
        case .notApplicable: return [unspecified]
        }
    }

    /// The concrete (non-unspecified) side choices a mode offers. `""` is a
    /// selector "no chosen side yet" placeholder, not a choice a user taps.
    public static func allowedConcreteSides(_ mode: ForceSideMode) -> [String] {
        allowedSides(mode).filter { $0 != unspecified }
    }

    public static func isSideAllowed(_ mode: ForceSideMode, _ side: String) -> Bool {
        allowedSides(mode).contains(side)
    }

    /// Whether an interactive L/R/B side selector should be shown for the
    /// mode. Every sided exercise shows its relevant concrete choices —
    /// including a single "Both" for `bilateral_only`, so "Both" stays
    /// explicit rather than implicit. Only `not_applicable` (no side decision
    /// exists) hides the selector entirely. The save path stamps the canonical
    /// side for a hidden/inherently-both exercise.
    public static func showsSideSelector(_ mode: ForceSideMode) -> Bool {
        mode.isSided
    }

    /// Deterministic fallback for a side that's no longer valid under `mode`
    /// (e.g. the exercise's side mode changed, or a remembered side predates a
    /// mode). `both` and `""` are never substituted for each other. Mirrors
    /// `normalizeSide`.
    public static func normalizeSide(_ mode: ForceSideMode, _ side: String) -> String {
        if isSideAllowed(mode, side) { return side }
        switch mode {
        case .bilateralOnly: return both
        case .notApplicable: return unspecified
        case .unilateralOnly: return unspecified
        // Every side is allowed for this mode, so this is unreachable.
        case .unilateralOrBilateral: return side
        }
    }

    /// The canonical side to stamp on a NEW recording under `mode`. Distinct
    /// from `normalizeSide` (which keeps `""` as "not chosen yet" for the
    /// selector): a bilateral-only exercise is inherently both-sided, so an
    /// unchosen side records as `both`. `not_applicable` always records the
    /// no-side value. Mirrors `recordedSide`.
    public static func recordedSide(_ mode: ForceSideMode, _ side: String) -> String {
        switch mode {
        case .bilateralOnly: return both
        case .notApplicable: return unspecified
        case .unilateralOnly, .unilateralOrBilateral: return normalizeSide(mode, side)
        }
    }

    /// A deterministic, mode-aware side to surface for an exercise that has no
    /// remembered side yet: `both` for an inherently bilateral exercise, `""`
    /// otherwise. Used by `ForceSideMemory.restoreValidSide` and the run/arm
    /// path so a never-configured side is never silently persisted as invalid.
    public static func defaultRecordedSide(_ mode: ForceSideMode) -> String {
        recordedSide(mode, unspecified)
    }
}

/// Per-exercise remembered side for the watch, keyed by exercise name so a side
/// chosen on one exercise can never leak across an incompatible exercise. The
/// raw value is a side string ("" / "left" / "right" / "both").
public enum ForceSideMemory {
    public static func storageKey(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return "sendmeter.watch.side.\(trimmed)"
    }

    public static func storedSide(for name: String, defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: storageKey(for: name))
    }

    public static func store(side: String, for name: String, defaults: UserDefaults = .standard) {
        defaults.set(side, forKey: storageKey(for: name))
    }

    public static func remove(for name: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey(for: name))
    }

    /// Restore the last valid side for an exercise, normalized to `mode`'s
    /// valid set. If the exercise has no remembered side (or the remembered
    /// side is no longer valid under `mode`), fall back deterministically to
    /// `ForceSidePolicy.defaultRecordedSide` (`both` for bilateral-only, `""`
    /// otherwise). Never reinterprets a historical empty side as `both`.
    public static func restoreValidSide(
        mode: ForceSideMode,
        name: String,
        defaults: UserDefaults = .standard
    ) -> String {
        guard let remembered = storedSide(for: name, defaults: defaults),
              !remembered.isEmpty else {
            return ForceSidePolicy.defaultRecordedSide(mode)
        }
        return ForceSidePolicy.normalizeSide(mode, remembered)
    }
}
