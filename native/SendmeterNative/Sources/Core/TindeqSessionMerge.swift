import Foundation

/// #942: why a set of sessions cannot be merged. The RPC enforces the same
/// rules server-side (and fails closed on anything it cannot see); this enum
/// exists so the History UI can refuse an ineligible selection before a
/// request is ever built, and so the refusal is unit-testable.
public enum TindeqSessionMergeEligibility: Equatable, Sendable {
    /// At least two distinct, uploaded, grouped, same-day Tindeq sessions.
    case eligible
    /// Fewer than two distinct sessions — there is nothing to merge.
    case tooFew
    /// At least one selected session is not a `tindeq` entry.
    case notTindeq
    /// The selection spans more than one local day (sessions' stored `date`).
    case differentDays
    /// A selected session has not been uploaded yet (no server row to merge).
    case pendingWrite
    /// A selected Tindeq session carries no group id, so no recording can be
    /// attributed to it.
    case ungrouped

    public var isEligible: Bool { self == .eligible }

    /// User-facing reason for a refused merge (nil when eligible).
    public var refusalMessage: String? {
        switch self {
        case .eligible:
            return nil
        case .tooFew:
            return "Pick at least two Tindeq sessions from the same day."
        case .notTindeq:
            return "Only Tindeq sessions can be merged."
        case .differentDays:
            return "Only sessions from the same day can be merged."
        case .pendingWrite:
            return "Sessions still uploading can't be merged yet."
        case .ungrouped:
            return "A selected session has no force recordings to merge."
        }
    }
}

/// The pure merge plan: the exact session/recording identity plus the fields
/// the surviving session ends up with. `merge_tindeq_sessions` recomputes
/// duration/note from the recordings it actually moved (the server is the
/// authority); the plan's values are what the optimistic row shows until the
/// upload reconciles.
public struct TindeqSessionMergePlan: Equatable, Sendable {
    /// The earliest-started session, which keeps its identity and date.
    public let survivorID: UUID
    /// Every selected session (survivor included), in the deterministic order
    /// the RPC receives them.
    public let mergedSessionIDs: [UUID]
    /// Every recording of every selected group, chronological — the exact set
    /// that gets re-pointed to the survivor's group.
    public let recordingIDs: [UUID]
    /// The survivor's group id: the recordings' new home.
    public let groupID: UUID
    /// The survivor's merged fields.
    public let date: String
    public let type: String
    public let typeLabel: String
    public let durationMinutes: Int
    public let note: String
    public let rpe: Double
    public let rpeConfirmed: Bool
    public let phase: PhaseID
    /// Live recordings counted into `durationMinutes`/`note`.
    public let recordingCount: Int

    public init(
        survivorID: UUID,
        mergedSessionIDs: [UUID],
        recordingIDs: [UUID],
        groupID: UUID,
        date: String,
        type: String,
        typeLabel: String,
        durationMinutes: Int,
        note: String,
        rpe: Double,
        rpeConfirmed: Bool,
        phase: PhaseID,
        recordingCount: Int
    ) {
        self.survivorID = survivorID
        self.mergedSessionIDs = mergedSessionIDs
        self.recordingIDs = recordingIDs
        self.groupID = groupID
        self.date = date
        self.type = type
        self.typeLabel = typeLabel
        self.durationMinutes = durationMinutes
        self.note = note
        self.rpe = rpe
        self.rpeConfirmed = rpeConfirmed
        self.phase = phase
        self.recordingCount = recordingCount
    }

    public var draft: SessionDraft {
        SessionDraft(
            date: date,
            type: type,
            typeLabel: typeLabel,
            durationMinutes: durationMinutes,
            rpe: rpe,
            note: note,
            phase: phase
        )
    }

    /// The survivor's merged value, ready to replace the local row.
    public func merged(survivor: Session) -> Session {
        Session(
            id: survivor.id,
            date: survivor.date,
            type: survivor.type,
            typeLabel: survivor.typeLabel,
            durationMinutes: durationMinutes,
            rpe: rpe,
            rpeConfirmed: rpeConfirmed,
            note: note,
            phase: survivor.phase,
            groupID: groupID,
            workoutSource: survivor.workoutSource,
            pending: survivor.pending,
            rejected: survivor.rejected,
            accountUserID: survivor.accountUserID
        )
    }
}

/// #942: the pure planning half of the History Merge action.
///
/// The survivor is the session whose recordings START earliest (the app has
/// no session start column; `date` is a whole local day). Duration, note and
/// the RPE/confirmed choice follow the issue's rules exactly:
///
///   * duration = `GaugeSessionDuration.spanMinutes` over every merged
///     recording (the survivor's own duration when there is nothing to
///     measure);
///   * note = `GaugeSessionNote.build` over the same chronological set;
///   * RPE = `GaugeSessionRPE.predict` over the merged recordings UNLESS any
///     selected session already carries a user-confirmed RPE, in which case
///     the latest-confirmed one is kept (and stays confirmed).
public enum TindeqSessionMergePlanner {
    public static let tindeqType = "tindeq"

    /// The sessions History may offer as merge partners for `anchor`: same
    /// local day, same (Tindeq) type, uploaded, and grouped.
    public static func candidates(
        for anchor: Session,
        in sessions: [Session]
    ) -> [Session] {
        sessions
            .filter { session in
                session.id != anchor.id
                    && session.type == anchor.type
                    && session.date == anchor.date
                    && !session.pending
                    && !session.rejected
                    && session.groupID != nil
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public static func eligibility(_ sessions: [Session]) -> TindeqSessionMergeEligibility {
        var seen = Set<UUID>()
        let distinct = sessions.filter { seen.insert($0.id).inserted }
        guard distinct.count >= 2 else { return .tooFew }
        guard distinct.allSatisfy({ $0.type == tindeqType }) else { return .notTindeq }
        guard Set(distinct.map(\.date)).count == 1 else { return .differentDays }
        guard distinct.allSatisfy({ !$0.pending && !$0.rejected }) else { return .pendingWrite }
        guard distinct.allSatisfy({ $0.groupID != nil }) else { return .ungrouped }
        return .eligible
    }

    /// Nil when the selection is not eligible (see `eligibility`).
    public static func plan(
        sessions: [Session],
        recordings: [TindeqRecording],
        curves: [TagForceCurve]
    ) -> TindeqSessionMergePlan? {
        var seen = Set<UUID>()
        let selected = sessions.filter { seen.insert($0.id).inserted }
        guard eligibility(selected) == .eligible else { return nil }

        let groupIDs = Set(selected.compactMap(\.groupID))
        let merged = recordings
            .filter { recording in
                guard let groupID = recording.groupID else { return false }
                return groupIDs.contains(groupID)
            }
            .sorted { lhs, rhs in
                if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt < rhs.recordedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }

        // Earliest-started session wins; a session with no recordings at all
        // sorts last (there is nothing to date it by), then by id so the
        // choice is deterministic.
        let ordered = selected.sorted { lhs, rhs in
            let lhsStart = start(of: lhs, recordings: merged)
            let rhsStart = start(of: rhs, recordings: merged)
            if lhsStart != rhsStart {
                return (lhsStart ?? .distantFuture) < (rhsStart ?? .distantFuture)
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        guard let survivor = ordered.first, let survivorGroup = survivor.groupID else {
            return nil
        }

        let durationMinutes = GaugeSessionDuration.spanMinutes(recordings: merged)
            ?? survivor.durationMinutes
        let note = GaugeSessionNote.build(recordings: merged)

        let confirmed = selected.filter(\.rpeConfirmed)
        let rpe: Double
        let rpeConfirmed: Bool
        if let kept = latestConfirmed(confirmed, recordings: merged) {
            rpe = kept.rpe
            rpeConfirmed = true
        } else {
            rpe = GaugeSessionRPE.predict(recordings: merged, curves: curves).rpe
            rpeConfirmed = false
        }

        return TindeqSessionMergePlan(
            survivorID: survivor.id,
            mergedSessionIDs: ordered.map(\.id),
            recordingIDs: merged.map(\.id),
            groupID: survivorGroup,
            date: survivor.date,
            type: survivor.type,
            typeLabel: survivor.typeLabel,
            durationMinutes: durationMinutes,
            note: note,
            rpe: rpe,
            rpeConfirmed: rpeConfirmed,
            phase: survivor.phase,
            recordingCount: merged.count
        )
    }

    /// The first recording's start for the session's own group.
    private static func start(
        of session: Session,
        recordings: [TindeqRecording]
    ) -> Date? {
        guard let groupID = session.groupID else { return nil }
        return recordings
            .filter { $0.groupID == groupID }
            .map(\.recordedAt)
            .min()
    }

    /// "Prefer the latest confirmed": newest by its group's last recording,
    /// then by id. Confirmed RPEs are the ones a human banked, so the most
    /// recent one is the best available statement about the merged effort.
    private static func latestConfirmed(
        _ confirmed: [Session],
        recordings: [TindeqRecording]
    ) -> Session? {
        confirmed.max { lhs, rhs in
            let lhsEnd = end(of: lhs, recordings: recordings) ?? .distantPast
            let rhsEnd = end(of: rhs, recordings: recordings) ?? .distantPast
            if lhsEnd != rhsEnd { return lhsEnd < rhsEnd }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func end(
        of session: Session,
        recordings: [TindeqRecording]
    ) -> Date? {
        guard let groupID = session.groupID else { return nil }
        return recordings
            .filter { $0.groupID == groupID }
            .map { $0.recordedAt.addingTimeInterval(Double($0.durationMilliseconds) / 1_000) }
            .max()
    }
}
