import Foundation
import XCTest
@_spi(Experimental) import Auth
@testable import Sendmeter
import SendmeterCore
import Supabase

/// #915: every remaining live `fetch*Delta` entrypoint (and the workout
/// attempt collection) driven through the REAL transport —
/// `SendmeterRepository` → `PostgRESTClient` → `URLSession` → the stub below.
/// The stub behaves like PostgREST for each table (its own `order`, `limit`,
/// cursor filter and `Content-Range` total) with a response cap smaller than
/// the requested page size, so these tests prove the request shape, the page
/// loop and the truncation signal for each entity's actual database identity.
final class PagedDeltaRemainingEntityTests: XCTestCase {
    private let userID = UUID(uuidString: "91500000-0000-0000-0000-0000000000CC")!
    private let (workoutID, otherWorkoutID) = (
        UUID(uuidString: "91500000-0000-0000-0000-0000000000E1")!,
        UUID(uuidString: "91500000-0000-0000-0000-0000000000E2")!
    )
    private let epoch = Date(timeIntervalSince1970: 1_769_000_000)

    private func date(_ seconds: Double) -> Date {
        epoch.addingTimeInterval(seconds)
    }

    private func uuid(_ n: Int) -> UUID {
        var bytes = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        bytes.15 = UInt8(n)
        return UUID(uuid: bytes)
    }

    private func uuidKey(_ n: Int) -> String {
        uuid(n).uuidString
    }

    private var legacyCursor: String {
        LocalCacheStore.syncCursorString(from: date(-60))
    }

    // MARK: - Fixtures (each entity's real page shape)

    /// Rows 1–3 share T1 (a tie group larger than the cap), rows 4–5 sit at T2,
    /// rows 6–7 are tombstones at T3 where the entity supports deletes.
    private func tieGroupRows(deletes: Bool) -> [CappedEntityPager.Row] {
        [
            .init(key: uuidKey(1), orderedAt: date(0), deleted: false, note: "1"),
            .init(key: uuidKey(2), orderedAt: date(0), deleted: false, note: "2"),
            .init(key: uuidKey(3), orderedAt: date(0), deleted: false, note: "3"),
            .init(key: uuidKey(4), orderedAt: date(60), deleted: false, note: "4"),
            .init(key: uuidKey(5), orderedAt: date(60), deleted: false, note: "5"),
            .init(key: uuidKey(6), orderedAt: date(120), deleted: deletes, note: "6"),
            .init(key: uuidKey(7), orderedAt: date(120), deleted: deletes, note: "7")
        ]
    }

    private func tagRows() -> [CappedEntityPager.Row] {
        [
            .init(key: "Crimp", orderedAt: date(0), deleted: false, note: "Crimp"),
            .init(key: "Slopers", orderedAt: date(0), deleted: false, note: "Slopers"),
            .init(key: "Pockets", orderedAt: date(60), deleted: false, note: "Pockets")
        ]
    }

    private func healthRows() -> [CappedEntityPager.Row] {
        [
            .init(key: "2026-09-02", orderedAt: date(60), deleted: false, note: "2026-09-02"),
            .init(key: "2026-09-01", orderedAt: date(60), deleted: false, note: "2026-09-01"),
            .init(key: "2026-09-03", orderedAt: date(120), deleted: false, note: "2026-09-03")
        ]
    }

    private func attemptRows(workout: UUID) -> [CappedEntityPager.Row] {
        (1...4).map { n in
            CappedEntityPager.Row(
                key: uuidKey(n),
                orderedAt: date(n == 4 ? 60 : 0),
                deleted: false,
                note: uuidKey(n),
                parentID: workout
            )
        }
    }

    // MARK: - AC1/AC2: every remaining entity pages through the real transport

    @MainActor
    func testPhasePeriodDeltaConsumesEveryCappedPageWithTombstonesAndBoundaryTies() async throws {
        let server = CappedEntityPager(table: .phasePeriods, rows: tieGroupRows(deletes: true), cap: 2)
        let repository = makeRepository(server: server)

        let delta = try await repository.fetchPhasePeriodDelta(since: nil)

        assertCompletePagedRead(
            server: server,
            deltaIDs: delta.changes.map(\.entityID),
            tombstonedIDs: delta.changes.filter(\.deleted).map(\.entityID),
            expectedTombstones: [uuidKey(6), uuidKey(7)],
            cursor: delta.cursor,
            expectedCursor: DeltaCursor(updatedAt: date(120), entityID: uuidKey(7)).persisted,
            tieBreakColumn: "id"
        )
        XCTAssertEqual(server.recorded.map(\.path), Array(repeating: "/rest/v1/phase_periods", count: 4))
        XCTAssertEqual(delta.changes.first?.value?.id, uuid(1))
    }

    @MainActor
    func testPresetDeltaConsumesEveryCappedPageWithTombstonesAndBoundaryTies() async throws {
        let server = CappedEntityPager(table: .presets, rows: tieGroupRows(deletes: true), cap: 2)
        let repository = makeRepository(server: server)

        let delta = try await repository.fetchPresetDelta(since: nil)

        assertCompletePagedRead(
            server: server,
            deltaIDs: delta.changes.map(\.entityID),
            tombstonedIDs: delta.changes.filter(\.deleted).map(\.entityID),
            expectedTombstones: [uuidKey(6), uuidKey(7)],
            cursor: delta.cursor,
            expectedCursor: DeltaCursor(updatedAt: date(120), entityID: uuidKey(7)).persisted,
            tieBreakColumn: "id"
        )
        XCTAssertEqual(delta.changes.first?.value?.id, uuid(1))
    }

    @MainActor
    func testRoutineDeltaConsumesEveryCappedPageWithTombstonesAndBoundaryTies() async throws {
        let server = CappedEntityPager(table: .routines, rows: tieGroupRows(deletes: true), cap: 2)
        let repository = makeRepository(server: server)

        let delta = try await repository.fetchRoutineDelta(since: nil)

        assertCompletePagedRead(
            server: server,
            deltaIDs: delta.changes.map(\.entityID),
            tombstonedIDs: delta.changes.filter(\.deleted).map(\.entityID),
            expectedTombstones: [uuidKey(6), uuidKey(7)],
            cursor: delta.cursor,
            expectedCursor: DeltaCursor(updatedAt: date(120), entityID: uuidKey(7)).persisted,
            tieBreakColumn: "id"
        )
        XCTAssertEqual(delta.changes.first?.value?.name, "1")
    }

    @MainActor
    func testWorkoutDeltaCursorReadConsumesEveryCappedPageWithBoundaryTies() async throws {
        let server = CappedEntityPager(table: .workouts, rows: tieGroupRows(deletes: false), cap: 2)
        let repository = makeRepository(server: server)

        let delta = try await repository.fetchWorkoutDelta(since: legacyCursor)

        assertCompletePagedRead(
            server: server,
            deltaIDs: delta.changes.map(\.entityID),
            tombstonedIDs: [],
            expectedTombstones: [],
            cursor: delta.cursor,
            expectedCursor: DeltaCursor(updatedAt: date(120), entityID: uuidKey(7)).persisted,
            tieBreakColumn: "id",
            firstFilter: .legacy(stamp: legacyCursor)
        )
        XCTAssertEqual(
            delta.changes.map { $0.value?.attemptsConfirmed ?? -1 },
            [1, 2, 3, 4, 5, 6, 7],
            "each workout keeps its own attempt group through every page"
        )
    }

    @MainActor
    func testHealthMetricDeltaCursorReadConsumesEveryCappedPageTiedOnDate() async throws {
        let server = CappedEntityPager(table: .health, rows: healthRows(), cap: 1)
        let repository = makeRepository(server: server)

        let delta = try await repository.fetchHealthMetricDelta(since: legacyCursor)

        assertCompletePagedRead(
            server: server,
            deltaIDs: delta.changes.map(\.entityID),
            tombstonedIDs: [],
            expectedTombstones: [],
            cursor: delta.cursor,
            expectedCursor: DeltaCursor(updatedAt: date(120), entityID: "2026-09-03").persisted,
            tieBreakColumn: "date",
            expectedIDs: ["2026-09-01", "2026-09-02", "2026-09-03"],
            firstFilter: .legacy(stamp: legacyCursor)
        )
        XCTAssertEqual(delta.changes.first?.value?.readiness, 70)
    }

    @MainActor
    func testTagMetadataDeltaConsumesEveryCappedPageTiedOnName() async throws {
        let server = CappedEntityPager(table: .tags, rows: tagRows(), cap: 1)
        let repository = makeRepository(server: server)

        let delta = try await repository.fetchTagMetadataDelta(since: nil)

        assertCompletePagedRead(
            server: server,
            deltaIDs: delta.changes.map(\.entityID),
            tombstonedIDs: [],
            expectedTombstones: [],
            cursor: delta.cursor,
            expectedCursor: DeltaCursor(updatedAt: date(60), entityID: "Pockets").persisted,
            tieBreakColumn: "name",
            expectedIDs: ["Crimp", "Slopers", "Pockets"]
        )
        XCTAssertEqual(delta.changes.first?.value, TagMetadata(name: "Crimp", hidden: false))
    }

    /// `user_settings` holds one row per user, cached under the constant
    /// `CacheEntityID.settings`: the row's real `user_id` is the page tie-break
    /// and the checkpoint, while the delta merges under `settings`.
    @MainActor
    func testSettingsDeltaResumesInsideATimestampTieOnUserID() async throws {
        let server = CappedEntityPager(
            table: .settings,
            rows: [.init(key: userID.uuidString, orderedAt: date(0), deleted: false, note: "strength")],
            cap: 1
        )
        let repository = makeRepository(server: server)

        let delta = try await repository.fetchSettingsDelta(since: nil)

        XCTAssertEqual(delta.changes.map(\.entityID), [CacheEntityID.settings])
        XCTAssertEqual(delta.changes.first?.value?.currentPhase, .strength)
        XCTAssertEqual(
            delta.cursor,
            DeltaCursor(updatedAt: date(0), entityID: userID.uuidString).persisted,
            "the checkpoint carries the table's real user_id tie-break"
        )
        XCTAssertEqual(server.recorded.first?.order, "updated_at.asc,user_id.asc")
        XCTAssertEqual(server.recorded.first?.filter, CappedEntityPager.Filter.none)

        // The next read resumes on the composite cursor, still addressing the
        // row by its real user_id.
        let resumed = CappedEntityPager(table: .settings, rows: [], cap: 1)
        let resumedRepository = makeRepository(server: resumed)
        let resumedDelta = try await resumedRepository.fetchSettingsDelta(since: delta.cursor)

        XCTAssertEqual(
            resumed.recorded.first?.filter,
            .composite(stamp: LocalCacheStore.syncCursorString(from: date(0)), entityID: userID.uuidString)
        )
        XCTAssertTrue(resumedDelta.changes.isEmpty)
        XCTAssertEqual(resumedDelta.cursor, delta.cursor, "an empty page keeps the checkpoint")

        // AC2 retry: the row is updated server-side, so the next cursor read
        // re-serves it once with its latest revision.
        let updated = CappedEntityPager(
            table: .settings,
            rows: [.init(key: userID.uuidString, orderedAt: date(60), deleted: false, note: "capacity")],
            cap: 1
        )
        let updatedRepository = makeRepository(server: updated)
        let updatedDelta = try await updatedRepository.fetchSettingsDelta(since: delta.cursor)

        XCTAssertEqual(updatedDelta.changes.map(\.entityID), [CacheEntityID.settings])
        XCTAssertEqual(updatedDelta.changes.first?.value?.currentPhase, .capacity, "the retry sees the latest revision")
        XCTAssertEqual(
            updatedDelta.cursor,
            DeltaCursor(updatedAt: date(60), entityID: userID.uuidString).persisted
        )
    }

    // MARK: - AC1: the deliberate first-sync windows are unchanged

    /// Health metrics and workouts keep their historical first-sync display
    /// window (newest first, one bounded request) — the paged reader owns the
    /// cursor-bounded delta path. Asserting the first-sync request shape here is
    /// the "no production row-limit change" half of AC5.
    @MainActor
    func testFirstSyncWindowsKeepTheHistoricalRowLimitsAndOrdering() async throws {
        let healthServer = CappedEntityPager(table: .health, rows: healthRows(), cap: 5)
        let healthRepository = makeRepository(server: healthServer)
        let healthDelta = try await healthRepository.fetchHealthMetricDelta(since: nil)

        XCTAssertEqual(healthServer.recorded.map(\.order), ["date.desc"])
        XCTAssertEqual(healthServer.recorded.map(\.limit), ["60"])
        XCTAssertEqual(healthServer.servedPages, 1, "the first-sync window is one bounded request")
        XCTAssertEqual(
            healthDelta.changes.map(\.entityID),
            ["2026-09-03", "2026-09-02", "2026-09-01"],
            "the window is the newest rows first, exactly as before the paged reader"
        )

        let workoutServer = CappedEntityPager(table: .workouts, rows: tieGroupRows(deletes: false), cap: 10)
        let workoutRepository = makeRepository(server: workoutServer)
        let workoutDelta = try await workoutRepository.fetchWorkoutDelta(since: nil)

        XCTAssertEqual(workoutServer.recorded.map(\.order), ["started_at.desc"])
        XCTAssertEqual(workoutServer.recorded.map(\.limit), ["30"])
        XCTAssertEqual(workoutServer.servedPages, 1)
        XCTAssertEqual(workoutDelta.changes.count, 7)
        XCTAssertEqual(
            workoutDelta.changes.map(\.entityID),
            (1...7).reversed().map { uuidKey($0) },
            "the workout window is newest-started first"
        )
    }

    // MARK: - AC3: the workout attempt collection boundary

    /// The workout detail's attempt collection is read to completion through
    /// the same bounded reader: `(started_at, id)` order, one bounded page per
    /// request, scoped to the parent workout, and an empty collection is a
    /// legitimate `[]`. A capped response therefore cannot truncate the attempt
    /// set the detail publishes as loaded, and attempts from another workout
    /// can never appear in it.
    @MainActor
    func testWorkoutAttemptsCollectionIsReadCompletelyWithinItsWorkoutScope() async throws {
        var rows = attemptRows(workout: workoutID)
        rows.append(.init(
            key: uuidKey(9),
            orderedAt: date(0),
            deleted: false,
            note: uuidKey(9),
            parentID: otherWorkoutID
        ))
        let server = CappedEntityPager(table: .attempts, rows: rows, cap: 1)
        let repository = makeRepository(server: server)

        let attempts = try await repository.fetchWorkoutAttempts(id: workoutID)

        XCTAssertEqual(server.servedPages, 4, "three capped pages plus the last, shorter page")
        XCTAssertEqual(
            attempts.map(\.id),
            (1...4).map { uuid($0) },
            "every attempt of this workout is returned once, in (started_at, id) order"
        )
        XCTAssertEqual(
            server.recorded.dropFirst().first?.filter,
            .composite(stamp: LocalCacheStore.syncCursorString(from: date(0)), entityID: uuidKey(1)),
            "the split started_at tie group resumes on the attempt id"
        )
        XCTAssertEqual(
            Set(server.recorded.map(\.order)),
            ["started_at.asc,id.asc"],
            "the attempt collection pages on its own ordering timestamp"
        )
        XCTAssertEqual(Set(server.recorded.map(\.limit)), ["500"])
        XCTAssertEqual(Set(server.recorded.map(\.prefer)), ["count=exact"])
        XCTAssertEqual(
            Set(server.recorded.compactMap(\.workoutFilter)),
            ["eq.\(workoutID.uuidString.lowercased())"],
            "every page stays scoped to the parent workout"
        )

        let emptyServer = CappedEntityPager(table: .attempts, rows: [], cap: 1)
        let emptyRepository = makeRepository(server: emptyServer)
        let empty = try await emptyRepository.fetchWorkoutAttempts(id: workoutID)
        XCTAssertTrue(empty.isEmpty, "a workout with no attempts is an empty collection, not a paging error")
        XCTAssertEqual(emptyServer.servedPages, 1)
    }

    @MainActor
    func testWorkoutAttemptsMiddlePageFailureThrowsInsteadOfReturningAPartialCollection() async throws {
        let server = CappedEntityPager(table: .attempts, rows: attemptRows(workout: workoutID), cap: 1)
        server.failOnPage = 2
        let repository = makeRepository(server: server)

        do {
            let attempts = try await repository.fetchWorkoutAttempts(id: workoutID)
            XCTFail("a failed middle page published \(attempts.count) attempts")
        } catch {
            XCTAssertNotNil(error)
        }
        XCTAssertEqual(server.servedPages, 2, "the read stopped at the failed page")
    }

    // MARK: - AC2: empty responses for every remaining entity

    @MainActor
    func testEmptyCursorReadsAreEmptyAndKeepTheCheckpointForEveryRemainingEntity() async throws {
        for path in Self.remainingEntityPaths {
            let server = CappedEntityPager(table: .table(forPath: path), rows: [], cap: 2)
            let repository = makeRepository(server: server)

            let (ids, cursor) = try await readDelta(path, repository: repository, since: legacyCursor)

            XCTAssertTrue(ids.isEmpty, "\(path): an empty response is an empty delta")
            XCTAssertEqual(cursor, legacyCursor, "\(path): an empty page keeps the checkpoint untouched")
            XCTAssertEqual(server.servedPages, 1, "\(path): one empty page ends the read")
            XCTAssertEqual(server.recorded.first?.prefer, "count=exact", "\(path): the read asks for the row total")
        }
    }

    /// AC2 retry, for every remaining entity: a row re-served by a later page
    /// after it was updated reconciles once with its latest revision, and no
    /// other row is lost or duplicated.
    @MainActor
    func testRetriedRowReconcilesOnceWithItsLatestRevisionForEveryRemainingEntity() async throws {
        let cases: [(path: String, keys: [String], notes: [String])] = [
            ("phase_periods", (1...3).map { uuidKey($0) }, ["1", "2", "3"]),
            ("health_metrics", ["2026-09-01", "2026-09-02", "2026-09-03"], ["2026-09-01", "2026-09-02", "2026-09-03"]),
            ("tindeq_presets", (1...3).map { uuidKey($0) }, ["1", "2", "3"]),
            ("routine_presets", (1...3).map { uuidKey($0) }, ["1", "2", "3"]),
            ("climb_workouts", (1...3).map { uuidKey($0) }, ["1", "2", "3"]),
            ("tindeq_tags", ["Crimp", "Slopers", "Pockets"], ["Crimp", "Slopers", "Pockets"])
        ]

        for entity in cases {
            let rows = [
                CappedEntityPager.Row(key: entity.keys[0], orderedAt: date(0), deleted: false, note: entity.notes[0]),
                CappedEntityPager.Row(key: entity.keys[1], orderedAt: date(0), deleted: false, note: entity.notes[1]),
                CappedEntityPager.Row(key: entity.keys[2], orderedAt: date(60), deleted: false, note: entity.notes[2])
            ]
            let server = CappedEntityPager(table: .table(forPath: entity.path), rows: rows, cap: 1)
            server.mutateAfterPage = 2
            server.mutate = { rows in
                guard let index = rows.firstIndex(where: { $0.key == entity.keys[1] }) else { return }
                rows[index].orderedAt = self.date(30)
            }
            let repository = makeRepository(server: server)

            // `health_metrics` and `climb_workouts` answer `since: nil` with
            // their historical first-sync display window — one bounded
            // newest-first request, no pages, no composite checkpoint — so a
            // retry for them resumes from a checkpoint; the other four page
            // from `nil`.
            let since: String? = Self.firstSyncWindowPaths.contains(entity.path) ? legacyCursor : nil
            let (ids, cursor) = try await readDelta(entity.path, repository: repository, since: since)

            XCTAssertEqual(
                server.servedIDs.filter { $0 == entity.keys[1] }.count,
                2,
                "\(entity.path): the fixture re-served the updated row"
            )
            XCTAssertEqual(ids, entity.keys, "\(entity.path): every row is reconciled once, in ordering order")
            XCTAssertEqual(Set(ids).count, entity.keys.count, "\(entity.path): no row is reconciled twice")
            XCTAssertEqual(
                cursor,
                DeltaCursor(updatedAt: date(60), entityID: entity.keys[2]).persisted,
                "\(entity.path): the checkpoint is the composite cursor of the last row read"
            )
        }
    }

    // MARK: - Assertions

    @MainActor
    private func assertCompletePagedRead(
        server: CappedEntityPager,
        deltaIDs: [String],
        tombstonedIDs: [String],
        expectedTombstones: [String],
        cursor: String?,
        expectedCursor: String,
        tieBreakColumn: String,
        expectedIDs: [String]? = nil,
        firstFilter: CappedEntityPager.Filter = .none,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected = expectedIDs ?? (1...7).map { uuidKey($0) }
        XCTAssertGreaterThan(server.servedPages, 2, "AC2: the fixture is more than two capped pages", file: file, line: line)
        XCTAssertEqual(
            deltaIDs,
            expected,
            "every page's row is reconciled, in ordering-timestamp + tie-break order",
            file: file,
            line: line
        )
        XCTAssertEqual(Set(deltaIDs).count, expected.count, "no row is reconciled twice", file: file, line: line)
        XCTAssertEqual(
            tombstonedIDs,
            expectedTombstones,
            "tombstones cross the wire where the entity has them",
            file: file,
            line: line
        )
        XCTAssertEqual(
            cursor,
            expectedCursor,
            "the checkpoint is the composite cursor of the last row read",
            file: file,
            line: line
        )
        XCTAssertEqual(
            Set(server.recorded.map(\.order)),
            ["updated_at.asc,\(tieBreakColumn).asc"],
            "the page order uses this entity's real tie-break column",
            file: file,
            line: line
        )
        XCTAssertEqual(Set(server.recorded.map(\.limit)), ["500"], "AC5: every request stays bounded", file: file, line: line)
        XCTAssertEqual(
            Set(server.recorded.map(\.prefer)),
            ["count=exact"],
            "the client asks for the row total that proves the response was capped",
            file: file,
            line: line
        )
        XCTAssertEqual(
            server.recorded.first?.filter,
            firstFilter,
            "the first page carries only the caller's checkpoint filter",
            file: file,
            line: line
        )
        XCTAssertEqual(
            server.recorded.dropFirst().first?.filter,
            .composite(
                stamp: server.firstPageLastStamp ?? "",
                entityID: server.firstPageLastKey ?? ""
            ),
            "the page boundary falls inside the first timestamp tie group and resumes on the tie-break",
            file: file,
            line: line
        )
    }

    // MARK: - Harness

    /// Every live `fetch*Delta` path this lane adopted (#915 AC1).
    private static let remainingEntityPaths = [
        "user_settings",
        "phase_periods",
        "health_metrics",
        "tindeq_presets",
        "routine_presets",
        "climb_workouts",
        "tindeq_tags"
    ]

    /// The two entities whose `since: nil` read is the historical first-sync
    /// display window — one bounded newest-first request, no pages and no
    /// composite checkpoint
    /// (`testFirstSyncWindowsKeepTheHistoricalRowLimitsAndOrdering` pins that
    /// product decision, #915 AC5). A re-served row only exists on the
    /// cursor-bounded read, so a retry for these two starts from a checkpoint.
    private static let firstSyncWindowPaths: Set<String> = ["health_metrics", "climb_workouts"]

    /// Calls the entity's real repository entrypoint and reports the delta's
    /// reconciled entity ids and persisted checkpoint.
    @MainActor
    private func readDelta(
        _ path: String,
        repository: SendmeterRepository,
        since cursor: String?
    ) async throws -> (ids: [String], cursor: String?) {
        switch path {
        case "user_settings":
            let delta = try await repository.fetchSettingsDelta(since: cursor)
            return (delta.changes.map(\.entityID), delta.cursor)
        case "phase_periods":
            let delta = try await repository.fetchPhasePeriodDelta(since: cursor)
            return (delta.changes.map(\.entityID), delta.cursor)
        case "health_metrics":
            let delta = try await repository.fetchHealthMetricDelta(since: cursor)
            return (delta.changes.map(\.entityID), delta.cursor)
        case "tindeq_presets":
            let delta = try await repository.fetchPresetDelta(since: cursor)
            return (delta.changes.map(\.entityID), delta.cursor)
        case "routine_presets":
            let delta = try await repository.fetchRoutineDelta(since: cursor)
            return (delta.changes.map(\.entityID), delta.cursor)
        case "climb_workouts":
            let delta = try await repository.fetchWorkoutDelta(since: cursor)
            return (delta.changes.map(\.entityID), delta.cursor)
        default:
            let delta = try await repository.fetchTagMetadataDelta(since: cursor)
            return (delta.changes.map(\.entityID), delta.cursor)
        }
    }

    @MainActor
    private func makeRepository(server: CappedEntityPager) -> SendmeterRepository {
        let suite = "PagedDeltaRemainingEntityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let provider: (@Sendable () async throws -> Auth.Session) = { Self.makeSession(userID: self.userID) }
        return SendmeterRepository(
            transport: PostgRESTClient(
                projectURL: URL(string: "https://example.test")!,
                sessionProvider: provider,
                serverClock: ServerClockStore(defaults: defaults, keyPrefix: suite + ".clock"),
                session: server.makeURLSession()
            )
        )
    }

    private static func makeSession(userID: UUID) -> Auth.Session {
        let payload = Data(#"{"session_id": "session-1", "iat": 1_000}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let token = "header.\(payload).signature"
        let user = Auth.User(
            id: userID,
            appMetadata: [:],
            userMetadata: [:],
            aud: "authenticated",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        return Auth.Session(
            accessToken: token,
            tokenType: "bearer",
            expiresIn: 3_600,
            expiresAt: Date().timeIntervalSince1970 + 3_600,
            refreshToken: "refresh-token",
            user: user
        )
    }
}

/// A PostgREST-shaped pager for every #915 entity: it honours the query the
/// repository sends (`order`, `limit`, the composite/legacy cursor filter, the
/// parent `workout_id` scope), caps every response at `cap` rows while
/// reporting the matching total in `Content-Range`, and marshals rows as each
/// table's real column set so the production decoders do the parsing.
private final class CappedEntityPager: @unchecked Sendable {
    enum Table {
        case settings
        case phasePeriods
        case health
        case presets
        case routines
        case workouts
        case tags
        case attempts

        var path: String {
            switch self {
            case .settings: return "/rest/v1/user_settings"
            case .phasePeriods: return "/rest/v1/phase_periods"
            case .health: return "/rest/v1/health_metrics"
            case .presets: return "/rest/v1/tindeq_presets"
            case .routines: return "/rest/v1/routine_presets"
            case .workouts: return "/rest/v1/climb_workouts"
            case .tags: return "/rest/v1/tindeq_tags"
            case .attempts: return "/rest/v1/climb_attempts"
            }
        }

        var timestampColumn: String { self == .attempts ? "started_at" : "updated_at" }

        var tieBreakColumn: String {
            switch self {
            case .settings: return "user_id"
            case .health: return "date"
            case .tags: return "name"
            default: return "id"
            }
        }

        static func table(forPath path: String) -> Table {
            switch path {
            case "user_settings": return .settings
            case "phase_periods": return .phasePeriods
            case "health_metrics": return .health
            case "tindeq_presets": return .presets
            case "routine_presets": return .routines
            case "climb_workouts": return .workouts
            case "tindeq_tags": return .tags
            default: return .attempts
            }
        }
    }

    struct Row {
        let key: String
        var orderedAt: Date
        var deleted: Bool
        var note: String
        var parentID: UUID?

        init(key: String, orderedAt: Date, deleted: Bool, note: String, parentID: UUID? = nil) {
            self.key = key
            self.orderedAt = orderedAt
            self.deleted = deleted
            self.note = note
            self.parentID = parentID
        }
    }

    enum Filter: Equatable {
        case none
        case legacy(stamp: String)
        case composite(stamp: String, entityID: String)

        func includes(stamp: String, key: String) -> Bool {
            switch self {
            case .none:
                return true
            case .legacy(let cursor):
                return stamp >= cursor
            case .composite(let cursor, let entityID):
                return stamp > cursor || (stamp == cursor && key > entityID)
            }
        }
    }

    struct Recorded: Equatable {
        let path: String
        let order: String
        let limit: String
        let filter: Filter
        let prefer: String?
        let workoutFilter: String?
    }

    struct Reply {
        let status: Int
        let body: Data
        let headers: [String: String]
    }

    enum StubError: Error {
        case malformedQuery(String)
    }

    let table: Table
    private(set) var rows: [Row]
    private(set) var recorded: [Recorded] = []
    private(set) var servedIDs: [String] = []
    private(set) var servedPages = 0
    private(set) var firstPageLastKey: String?
    private(set) var firstPageLastStamp: String?
    let cap: Int
    var failOnPage: Int?
    var mutateAfterPage: Int?
    var mutate: ((inout [Row]) -> Void)?

    init(table: Table, rows: [Row], cap: Int) {
        self.table = table
        self.rows = rows
        self.cap = cap
    }

    func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CappedEntityPagerProtocol.self]
        CappedEntityPagerProtocol.server = self
        return URLSession(configuration: configuration)
    }

    func reply(for request: URLRequest) throws -> Reply {
        let items = URLComponents(url: request.url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)?
            .queryItems ?? []
        func item(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        let filter: Filter
        if let composite = item("or") {
            filter = try Self.parseComposite(
                composite,
                timestampColumn: table.timestampColumn,
                tieBreakColumn: table.tieBreakColumn
            )
        } else if let legacy = item(table.timestampColumn) {
            filter = .legacy(stamp: try Self.value(of: legacy, dropping: "gte."))
        } else {
            filter = .none
        }
        let workoutFilter = item("workout_id")
        recorded.append(Recorded(
            path: request.url?.path ?? "",
            order: item("order") ?? "",
            limit: item("limit") ?? "",
            filter: filter,
            prefer: request.value(forHTTPHeaderField: "Prefer"),
            workoutFilter: workoutFilter
        ))
        servedPages += 1
        if failOnPage == servedPages {
            return Reply(status: 500, body: Data(#"{"message":"boom"}"#.utf8), headers: [:])
        }

        let scope = workoutFilter.flatMap { UUID(uuidString: String($0.dropFirst("eq.".count))) }
        let matching = rows
            .map { (stamp: Self.stamp($0.orderedAt), row: $0) }
            .filter { filter.includes(stamp: $0.stamp, key: $0.row.key) }
            .filter { scope == nil || $0.row.parentID == nil || $0.row.parentID == scope }
            .map(\.row)
        let ordered = sort(matching, by: item("order") ?? "\(table.timestampColumn).asc")
        let requested = max(1, Int(item("limit") ?? "") ?? cap)
        let window = Array(ordered.prefix(min(cap, requested)))
        if servedPages == 1, let last = window.last {
            firstPageLastKey = last.key
            firstPageLastStamp = Self.stamp(last.orderedAt)
        }
        if mutateAfterPage == servedPages {
            mutate?(&rows)
        }
        servedIDs.append(contentsOf: window.map(\.key))
        let end = window.isEmpty ? -1 : window.count - 1
        let body = "[" + window.map(marshal).joined(separator: ",") + "]"
        return Reply(
            status: 200,
            body: Data(body.utf8),
            headers: [
                "Content-Type": "application/json",
                "Content-Range": "\(window.isEmpty ? "*" : "0-\(end)")/\(matching.count)"
            ]
        )
    }

    /// The requested ordering (`<column>.asc|desc`, optionally followed by a
    /// tie-break) applied to the fixture's rows.
    private func sort(_ rows: [Row], by order: String) -> [Row] {
        let parts = order.split(separator: ",").map(String.init)
        let primary = parts.first ?? "\(table.timestampColumn).asc"
        let descending = primary.hasSuffix(".desc")
        let column = primary
            .replacingOccurrences(of: ".desc", with: "")
            .replacingOccurrences(of: ".asc", with: "")
        func value(_ row: Row) -> String {
            column == table.timestampColumn ? Self.stamp(row.orderedAt) : row.key
        }
        return rows.sorted { lhs, rhs in
            let left = value(lhs)
            let right = value(rhs)
            if left != right { return descending ? left > right : left < right }
            return lhs.key < rhs.key
        }
    }

    private func marshal(_ row: Row) -> String {
        let stamp = Self.iso(row.orderedAt)
        let deleted = row.deleted ? "\"\(stamp)\"" : "null"
        let lowerKey = row.key.lowercased()
        switch table {
        case .settings:
            return """
            {"user_id":"\(lowerKey)","current_phase":"\(row.note)","phase_start_date":"2026-09-01",\
            "updated_at":"\(stamp)"}
            """
        case .phasePeriods:
            return """
            {"id":"\(lowerKey)","phase":"strength","started_on":"2026-09-01","ended_on":null,\
            "updated_at":"\(stamp)","deleted_at":\(deleted)}
            """
        case .health:
            return """
            {"date":"\(row.key)","readiness":70,"zone":"green","computed_at":"\(stamp)",\
            "hrv_sdnn_ms":60,"resting_hr":50,"sleep_hours":7.5,"sleep_deep_hours":1.2,\
            "sleep_rem_hours":1.5,"body_mass_kg":70,"resp_rate_bpm":14,"updated_at":"\(stamp)"}
            """
        case .presets:
            return """
            {"id":"\(lowerKey)","name":"\(row.note)","hold_s":10,"reps":5,"sets":3,\
            "rest_reps_s":30,"rest_sets_s":120,"updated_at":"\(stamp)","deleted_at":\(deleted)}
            """
        case .routines:
            return """
            {"id":"\(lowerKey)","name":"\(row.note)","steps":[{"label":"Warmup","s":60}],\
            "updated_at":"\(stamp)","deleted_at":\(deleted)}
            """
        case .workouts:
            let attempts = Int(row.note) ?? 0
            return """
            {"id":"\(lowerKey)","session_id":null,"started_at":"\(stamp)",\
            "ended_at":"\(stamp)","avg_hr":120,"max_hr":165,"active_kcal":220,\
            "elevation_gain_m":12,"attempts_confirmed":\(attempts),"attempts_detected":\(attempts),\
            "rpe_confirmed":7,"rpe_predicted":7.5,"source":"watch","updated_at":"\(stamp)"}
            """
        case .tags:
            return """
            {"name":"\(row.key)","hidden":false,"updated_at":"\(stamp)"}
            """
        case .attempts:
            return """
            {"id":"\(lowerKey)","started_at":"\(stamp)","duration_s":8.5,"elevation_gain_m":1.2,\
            "avg_hr":120,"peak_hr":150,"effort_score":6.5,"source":"auto"}
            """
        }
    }

    private static func stamp(_ date: Date) -> String {
        LocalCacheStore.syncCursorString(from: date)
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parseComposite(
        _ raw: String,
        timestampColumn: String,
        tieBreakColumn: String
    ) throws -> Filter {
        guard raw.hasPrefix("("), raw.hasSuffix(")") else { throw StubError.malformedQuery(raw) }
        let inner = String(raw.dropFirst().dropLast())
        guard let andRange = inner.range(of: ",and(") else { throw StubError.malformedQuery(raw) }
        let greater = String(inner[..<andRange.lowerBound])
        var nested = String(inner[andRange.upperBound...])
        guard nested.hasSuffix(")") else { throw StubError.malformedQuery(raw) }
        nested = String(nested.dropLast())
        let parts = nested.split(separator: ",", maxSplits: 1)
        guard parts.count == 2 else { throw StubError.malformedQuery(raw) }
        let stamp = try value(of: greater, dropping: "\(timestampColumn).gt.")
        guard String(parts[0]) == "\(timestampColumn).eq.\(stamp)" else {
            throw StubError.malformedQuery(raw)
        }
        return .composite(
            stamp: stamp,
            entityID: try value(of: String(parts[1]), dropping: "\(tieBreakColumn).gt.")
        )
    }

    private static func value(of item: String, dropping prefix: String) throws -> String {
        guard item.hasPrefix(prefix) else { throw StubError.malformedQuery(item) }
        return String(item.dropFirst(prefix.count))
    }
}

private final class CappedEntityPagerProtocol: URLProtocol {
    nonisolated(unsafe) static var server: CappedEntityPager?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = Self.server else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let reply: CappedEntityPager.Reply
        do {
            reply = try server.reply(for: request)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: reply.status,
                  httpVersion: "HTTP/1.1",
                  headerFields: reply.headers
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
