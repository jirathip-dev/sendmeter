import Foundation

/// #1038 G5: the one-tap movement & side picker. Tapping applies and closes;
/// swipe-down cancels with no change; when both a movement and a side are
/// needed the sheet closes once both are set, and the side defaults to the
/// last one used for that movement.
///
/// The picker edits a DRAFT. Nothing reaches the recording context until
/// `commit` — so a swipe-down (no commit) is a true no-change cancel.
public struct MovementSideDraft: Equatable, Sendable {
    public var movement: String
    public var side: TindeqSide

    public init(movement: String, side: TindeqSide) {
        self.movement = movement
        self.side = side
    }
}

public enum MovementSidePickerPolicy {
    /// What a tap does to the sheet.
    public enum Outcome: Equatable, Sendable {
        /// Apply the draft and close the sheet.
        case commit(MovementSideDraft)
        /// Keep the sheet open: the side still has to be chosen.
        case needsSide(MovementSideDraft)
    }

    /// The side a newly tapped movement starts with: the last side recorded
    /// for that movement when the movement's policy still allows it, else the
    /// policy's own fallback (`both` for bilateral-only, `unspecified` for
    /// not-applicable), else nothing — the user picks.
    public static func defaultSide(
        for movement: String,
        mode: ExerciseSideMode,
        lastSide: TindeqSide?
    ) -> TindeqSide {
        switch mode {
        case .bilateralOnly: return .both
        case .notApplicable: return .unspecified
        case .unilateralOrBilateral, .unilateralOnly:
            guard let lastSide, lastSide != .unspecified,
                  ExerciseSidePolicy.isSideAllowed(mode, lastSide)
            else { return .unspecified }
            return lastSide
        }
    }

    /// Whether the movement needs an explicit side before the pull can be
    /// attributed — only when the policy offers a real choice.
    public static func needsSideChoice(_ mode: ExerciseSideMode) -> Bool {
        switch mode {
        case .unilateralOrBilateral, .unilateralOnly: return true
        case .bilateralOnly, .notApplicable: return false
        }
    }

    /// Tapping a movement row. `pendingSide` is a side the user tapped in
    /// THIS sheet before any movement (side-first flow): when the movement
    /// allows it, it wins over the movement's history — the user just said it.
    public static func tapMovement(
        _ movement: String,
        mode: ExerciseSideMode,
        lastSide: TindeqSide?,
        pendingSide: TindeqSide? = nil
    ) -> Outcome {
        if let pendingSide, pendingSide != .unspecified, needsSideChoice(mode),
           ExerciseSidePolicy.isSideAllowed(mode, pendingSide) {
            return .commit(MovementSideDraft(movement: movement, side: pendingSide))
        }
        let side = defaultSide(for: movement, mode: mode, lastSide: lastSide)
        let draft = MovementSideDraft(movement: movement, side: side)
        if needsSideChoice(mode), side == .unspecified {
            return .needsSide(draft)
        }
        return .commit(draft)
    }

    /// Tapping a side chip. With a movement in the draft the pair is complete
    /// and the sheet closes; with none yet, the side waits for the movement.
    public static func tapSide(
        _ side: TindeqSide,
        draft: MovementSideDraft,
        mode: ExerciseSideMode
    ) -> Outcome {
        guard ExerciseSidePolicy.isSideAllowed(mode, side) else { return .needsSide(draft) }
        let next = MovementSideDraft(movement: draft.movement, side: side)
        let movement = next.movement.trimmingCharacters(in: .whitespacesAndNewlines)
        return movement.isEmpty ? .needsSide(next) : .commit(next)
    }

    /// The last side used per movement, from the saved pulls (newest wins).
    public static func lastSides(from recordings: [TindeqRecording]) -> [String: TindeqSide] {
        var result: [String: TindeqSide] = [:]
        var newest: [String: Date] = [:]
        for recording in recordings {
            let tag = recording.tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, recording.side != .unspecified else { continue }
            if let seen = newest[tag], seen >= recording.recordedAt { continue }
            newest[tag] = recording.recordedAt
            result[tag] = recording.side
        }
        return result
    }

    /// Picker proposal (H): recently used movements first, then the rest in
    /// their catalog order. Ties keep the catalog order.
    public static func recentFirst(
        _ movements: [String],
        recordings: [TindeqRecording],
        limit: Int = 3
    ) -> (recent: [String], other: [String]) {
        var newest: [String: Date] = [:]
        for recording in recordings {
            let tag = recording.tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { continue }
            if let seen = newest[tag], seen >= recording.recordedAt { continue }
            newest[tag] = recording.recordedAt
        }
        let ranked = movements.enumerated()
            .filter { newest[$0.element] != nil }
            .sorted { lhs, rhs in
                let l = newest[lhs.element]!, r = newest[rhs.element]!
                return l == r ? lhs.offset < rhs.offset : l > r
            }
            .map(\.element)
        let recent = Array(ranked.prefix(max(0, limit)))
        let other = movements.filter { !recent.contains($0) }
        return (recent, other)
    }
}

/// #1038 H2 (defect): the old "Side Policy" column read "Either" on every
/// row — no information. A movement is badged only where its side policy
/// DIFFERS from the default (either side or both); the default draws nothing.
public enum MovementSideBadge {
    public static func badge(for mode: ExerciseSideMode) -> String? {
        switch mode {
        case .unilateralOrBilateral: return nil
        case .unilateralOnly: return "One side"
        case .bilateralOnly: return "Both only"
        case .notApplicable: return "No side"
        }
    }
}
