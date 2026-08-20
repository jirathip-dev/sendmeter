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
