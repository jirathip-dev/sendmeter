import Foundation

/// Stable queue identities for the two scopes involved in a recording edit.
///
/// Recording metadata is per recording, while RPE is per linked session. The
/// latter identity is intentionally independent of the recording that caused
/// the edit, so two recordings in one session cannot carry separate replay
/// orderings for the same session RPE.
public enum RecordingEditQueueIdentity {
    public static func recording(_ recordingID: UUID) -> UUID {
        // Preserve db6aae7's XOR derivation so a queued edit survives the
        // follow-up build and delete can cancel it by the same durable id.
        var bytes = recordingID.uuid
        bytes.0 ^= 0x80
        return UUID(uuid: bytes)
    }

    public static func sessionRPE(_ sessionID: UUID) -> UUID {
        namespaced(sessionID, namespace: 0xE2)
    }

    private static func namespaced(_ id: UUID, namespace: UInt8) -> UUID {
        var bytes = id.uuid
        bytes.0 = namespace
        return UUID(uuid: bytes)
    }
}

public struct RecordingEditWriteToken: Equatable, Sendable {
    public let id: UUID
    public let recordingID: UUID
    public let sessionID: UUID

    public init(id: UUID = UUID(), recordingID: UUID, sessionID: UUID) {
        self.id = id
        self.recordingID = recordingID
        self.sessionID = sessionID
    }
}

public struct RecordingEditBarrierToken: Equatable, Sendable {
    public let id: UUID
    public let sessionID: UUID

    public init(id: UUID = UUID(), sessionID: UUID) {
        self.id = id
        self.sessionID = sessionID
    }
}

/// The durable ordering used when more than one queue item describes the same
/// session RPE. `nextAttemptAt` is deliberately absent: backoff controls when
/// a candidate is retried, never which candidate is authoritative.
public struct RecordingEditOrdering: Comparable, Equatable, Sendable {
    public let primary: UInt64
    public let createdAt: UInt64
    public let tieBreaker: String

    public init(
        sessionRPERevision: UInt64?,
        createdAt: Date,
        tieBreaker: UUID
    ) {
        self.primary = sessionRPERevision
            ?? RecordingEditCoordinator.orderingKey(for: createdAt)
        self.createdAt = RecordingEditCoordinator.orderingKey(for: createdAt)
        self.tieBreaker = tieBreaker.uuidString
    }

    public static func < (
        lhs: RecordingEditOrdering,
        rhs: RecordingEditOrdering
    ) -> Bool {
        if lhs.primary != rhs.primary { return lhs.primary < rhs.primary }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.tieBreaker < rhs.tieBreaker
    }
}

/// A queue-independent candidate keeps the legacy migration decision in the
/// SwiftPM-tested layer. AppModel supplies the queue item's durable id and
/// creation time, but never lets queue backoff enumeration decide recency.
public struct RecordingEditQueueCandidate: Equatable, Sendable {
    public let edit: RecordingEdit
    public let queueItemID: UUID
    public let createdAt: Date
    /// Diagnostic only. The migration intentionally ignores retry timing;
    /// carrying it here lets tests model a backoff-sorted queue snapshot
    /// without making backoff part of authoritative ordering.
    public let nextAttemptAt: Date

    public init(
        edit: RecordingEdit,
        queueItemID: UUID,
        createdAt: Date,
        nextAttemptAt: Date? = nil
    ) {
        self.edit = edit
        self.queueItemID = queueItemID
        self.createdAt = createdAt
        self.nextAttemptAt = nextAttemptAt ?? createdAt
    }

    public var ordering: RecordingEditOrdering {
        RecordingEditOrdering(
            sessionRPERevision: edit.sessionRPERevision,
            createdAt: createdAt,
            tieBreaker: queueItemID
        )
    }
}

public enum RecordingEditMigration {
    public static func metadataOnly(_ edit: RecordingEdit) -> RecordingEdit {
        RecordingEdit(
            recordingID: edit.recordingID,
            tag: edit.tag,
            side: edit.side,
            note: edit.note
        )
    }

    public static func authoritativeSessionRPE(
        sessionID: UUID,
        candidates: [RecordingEditQueueCandidate]
    ) -> RecordingEditQueueCandidate? {
        candidates
            .filter { $0.edit.sessionID == sessionID && $0.edit.sessionRPE != nil }
            .max { $0.ordering < $1.ordering }
    }
}

/// Main-actor state for recording-edit ordering and delete dominance.
///
/// Revisions are wall-clock-shaped, but strictly monotonic within this
/// coordinator. That makes a newly-created revision larger than a queued
/// pre-relaunch edit after `observe` has seeded the coordinator from durable
/// queue entries. The revision is stored in the edit payload, while the
/// queue identity above remains the one session-scoped coalescing key.
public struct RecordingEditCoordinator: Sendable {
    private var latestRevision: UInt64
    private var deletedRecordingIDs: Set<UUID> = []
    private var activeSessionRPEWrites: [UUID: Set<UUID>] = [:]
    private var sessionRPEBarriers: [UUID: Set<UUID>] = [:]

    public init(now: Date = Date()) {
        self.latestRevision = Self.orderingKey(for: now)
    }

    public mutating func nextSessionRPERevision(now: Date = Date()) -> UInt64 {
        let clock = Self.orderingKey(for: now)
        if latestRevision == UInt64.max {
            return latestRevision
        }
        latestRevision = max(clock, latestRevision &+ 1)
        return latestRevision
    }

    /// Seed ordering after loading durable edits. A legacy edit without a
    /// revision still contributes its durable creation time to the floor.
    public mutating func observe(sessionRPERevision: UInt64?, createdAt: Date) {
        let observed = sessionRPERevision ?? Self.orderingKey(for: createdAt)
        latestRevision = max(latestRevision, observed)
    }

    @discardableResult
    public mutating func tombstone(recordingID: UUID) -> Bool {
        deletedRecordingIDs.insert(recordingID).inserted
    }

    public mutating func clearTombstone(recordingID: UUID) {
        deletedRecordingIDs.remove(recordingID)
    }

    public mutating func clearTombstones() {
        deletedRecordingIDs.removeAll()
    }

    public func isDeleted(_ recordingID: UUID) -> Bool {
        deletedRecordingIDs.contains(recordingID)
    }

    /// Claim the session-RPE network lane before the first await. A delete
    /// barrier or recording tombstone makes the claim fail, so stale queued
    /// work cannot start a PATCH after deletion has won the race.
    public mutating func beginSessionRPEWrite(
        recordingID: UUID,
        sessionID: UUID
    ) -> RecordingEditWriteToken? {
        guard !isDeleted(recordingID), !isSessionRPEBarrierActive(sessionID: sessionID) else {
            return nil
        }
        let token = RecordingEditWriteToken(
            recordingID: recordingID,
            sessionID: sessionID
        )
        activeSessionRPEWrites[sessionID, default: []].insert(token.id)
        return token
    }

    @discardableResult
    public mutating func endSessionRPEWrite(
        _ token: RecordingEditWriteToken
    ) -> Bool {
        guard var active = activeSessionRPEWrites[token.sessionID],
              active.remove(token.id) != nil else { return false }
        if active.isEmpty {
            activeSessionRPEWrites.removeValue(forKey: token.sessionID)
        } else {
            activeSessionRPEWrites[token.sessionID] = active
        }
        return true
    }

    public func hasActiveSessionRPEWrites(sessionID: UUID) -> Bool {
        !(activeSessionRPEWrites[sessionID]?.isEmpty ?? true)
    }

    public func acceptsSessionRPEWrite(_ token: RecordingEditWriteToken) -> Bool {
        !isDeleted(token.recordingID)
            && !isSessionRPEBarrierActive(sessionID: token.sessionID)
            && activeSessionRPEWrites[token.sessionID]?.contains(token.id) == true
    }

    /// A delete holds this barrier while it drains already-started RPE work
    /// and restores the authoritative pre-edit value. New linked-recording
    /// edits stay durable in the queue and are drained after release.
    public mutating func beginSessionRPEBarrier(
        sessionID: UUID
    ) -> RecordingEditBarrierToken {
        let token = RecordingEditBarrierToken(sessionID: sessionID)
        sessionRPEBarriers[sessionID, default: []].insert(token.id)
        return token
    }

    @discardableResult
    public mutating func endSessionRPEBarrier(
        _ token: RecordingEditBarrierToken
    ) -> Bool {
        guard var barriers = sessionRPEBarriers[token.sessionID],
              barriers.remove(token.id) != nil else { return false }
        if barriers.isEmpty {
            sessionRPEBarriers.removeValue(forKey: token.sessionID)
        } else {
            sessionRPEBarriers[token.sessionID] = barriers
        }
        return true
    }

    public func isSessionRPEBarrierActive(sessionID: UUID) -> Bool {
        !(sessionRPEBarriers[sessionID]?.isEmpty ?? true)
    }

    /// The durable queue uses microsecond precision for the legacy fallback;
    /// this is enough to order edits from one UI interaction without relying
    /// on UUID lexical order.
    public static func orderingKey(for date: Date) -> UInt64 {
        let micros = max(0, date.timeIntervalSince1970 * 1_000_000)
        return UInt64(micros.rounded(.toNearestOrAwayFromZero))
    }

    /// PostgreSQL `round(numeric)` rounds positive .5 values away from zero.
    /// Session `load` is a generated integer column with this exact rule.
    public static func optimisticLoad(durationMinutes: Int, rpe: Double) -> Double {
        (Double(durationMinutes) * rpe).rounded(.toNearestOrAwayFromZero)
    }
}

/// Pure guards shared by the optimistic reducer and the async upload path.
/// A response is valid only while its queue claim is still current and the
/// recording has not been tombstoned by a delete.
public enum RecordingEditRacePolicy {
    public static func acceptsRecordingResponse(
        recordingID: UUID,
        responseRevision: UUID,
        currentRevision: UUID?,
        deleted: Bool
    ) -> Bool {
        !deleted && currentRevision == responseRevision
    }

    public static func acceptsSessionRPEResponse(
        responseRevision: UUID,
        currentRevision: UUID?,
        deleted: Bool
    ) -> Bool {
        return !deleted && currentRevision == responseRevision
    }

    public static func isNewer(
        revision: UInt64,
        than other: UInt64
    ) -> Bool {
        revision > other
    }
}
