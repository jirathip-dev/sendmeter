import Foundation
@testable import SendmeterCore

/// One row of the #915 entity shapes whose page tie-break is text rather than
/// a uuid: `user_settings.user_id` (uuid text), `health_metrics.date`
/// (`YYYY-MM-DD`) and `tindeq_tags.name`.
struct KeyedStubRow: Sendable, Equatable, CappedDeltaFixtureRow {
    let key: String
    let updatedAt: Date
    let deleted: Bool
    let note: String

    var fixtureKey: String { key }
    var fixtureStamp: String { LocalCacheStore.syncCursorString(from: updatedAt) }
    var fixtureOrderingInstant: Date { updatedAt }
    var fixtureDeleted: Bool { deleted }
}

func keyedRow(_ key: String, at seconds: Double, deleted: Bool = false, note: String = "") -> KeyedStubRow {
    KeyedStubRow(
        key: key,
        updatedAt: stubDate(seconds),
        deleted: deleted,
        note: note.isEmpty ? key : note
    )
}

/// Drives the production reader with one remaining entity's real page shape —
/// its tie-break column, its ordering timestamp and its cache/merge identity —
/// over the deterministic capped pager.
enum PagedKeyedReader {
    static func read<Value: Sendable>(
        server: CappedDeltaServer<KeyedStubRow>,
        tieBreakColumn: String,
        entityID: @escaping @Sendable (KeyedStubRow) -> String,
        since cursor: String?,
        value: @escaping @Sendable (KeyedStubRow) -> Value,
        pageSize: Int = 2,
        timestampColumn: String = "updated_at",
        tieBreakID: (@Sendable (KeyedStubRow) -> String)? = nil,
        pageLimit: Int = DeltaPageReader<KeyedStubRow, Value>.defaultPageLimit
    ) async throws -> RemoteEntityDelta<Value> {
        let reader = DeltaPageReader<KeyedStubRow, Value>(
            select: "key,updated_at,deleted_at",
            tieBreakColumn: tieBreakColumn,
            timestampColumn: timestampColumn,
            pageSize: pageSize,
            pageLimit: pageLimit,
            entityID: entityID,
            tieBreakID: tieBreakID,
            value: value,
            isDeleted: { $0.deleted },
            updatedAt: { $0.updatedAt }
        )
        return try await reader.read(since: cursor) { request in
            try server.page(for: request)
        }
    }
}

/// Drives the production reader with the `workoutsAndAttempts` shape: a uuid
/// page tie-break (`climb_workouts.id`), and a value that carries the workout's
/// attempt group (`attemptsConfirmed`/`attemptsDetected`) the cache publishes
/// with it.
enum PagedWorkoutReader {
    static func read(
        server: CappedDeltaServer<StubDeltaRow>,
        since cursor: String?,
        pageSize: Int = 2,
        pageLimit: Int = DeltaPageReader<StubDeltaRow, WorkoutListItem>.defaultPageLimit,
        attemptCount: @escaping (StubDeltaRow) -> Int = { Int($0.note) ?? 0 }
    ) async throws -> RemoteEntityDelta<WorkoutListItem> {
        let reader = DeltaPageReader<StubDeltaRow, WorkoutListItem>(
            select: "id,session_id,started_at,ended_at,attempts_confirmed,attempts_detected,source,updated_at",
            tieBreakColumn: "id",
            pageSize: pageSize,
            pageLimit: pageLimit,
            entityID: { $0.id },
            value: { row in
                WorkoutListItem(
                    id: row.uuid,
                    sessionID: nil,
                    startedAt: row.updatedAt,
                    endedAt: row.updatedAt.addingTimeInterval(1_800),
                    averageHeartRate: 120,
                    maxHeartRate: 165,
                    activeKilocalories: 220,
                    elevationGainMeters: 12,
                    attemptsConfirmed: attemptCount(row),
                    attemptsDetected: attemptCount(row),
                    rpeConfirmed: 7,
                    rpePredicted: 7.5,
                    source: .watch
                )
            },
            isDeleted: { _ in false },
            updatedAt: { $0.updatedAt }
        )
        return try await reader.read(since: cursor) { request in
            try server.page(for: request)
        }
    }
}
