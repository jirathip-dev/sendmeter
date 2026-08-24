import Foundation
import XCTest
@testable import SendmeterCore

final class BackgroundSyncEngineTests: XCTestCase {
    private let account = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private final class ApplyCounter: @unchecked Sendable {
        var count = 0
    }

    private final class OrderLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []

        func append(_ value: String) {
            lock.lock()
            defer { lock.unlock() }
            entries.append(value)
        }

        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }

    private func session() -> Session {
        Session(
            id: sessionID,
            date: "2026-08-24",
            type: "hangboard",
            typeLabel: "Hangboard",
            durationMinutes: 40,
            rpe: 7,
            phase: .strength,
            accountUserID: account
        )
    }

    private func run(
        isCurrent: @escaping @MainActor @Sendable (UUID, UInt64) -> Bool,
        drain: @escaping @MainActor @Sendable () async -> Void,
        operations: [BackgroundSyncOperation]
    ) -> BackgroundSyncRun {
        BackgroundSyncRun(
            accountUserID: account,
            accountEpoch: 1,
            isCurrent: isCurrent,
            drain: drain,
            operations: operations
        )
    }

    func testDrainsBeforeApplyingOperations() async {
        let applied = ApplyCounter()
        let order = OrderLog()
        let run = run(
            isCurrent: { _, _ in true },
            drain: {
                order.append("drain")
            },
            operations: (0..<2).map { index in
                BackgroundSyncOperation(entityType: .sessions) {
                    BackgroundSyncPreparedOperation {
                        applied.count += 1
                        order.append("apply-\(index)")
                    }
                }
            }
        )

        let outcome = await BackgroundSyncEngine.run(run)

        XCTAssertEqual(outcome, .completed(2))
        XCTAssertEqual(order.snapshot(), ["drain", "apply-0", "apply-1"])
        XCTAssertEqual(applied.count, 2)
    }

    func testCancellationBeforeDrainSkipsDrain() async {
        let drained = ApplyCounter()
        let run = run(
            isCurrent: { _, _ in true },
            drain: {
                drained.count += 1
            },
            operations: []
        )

        let work = Task { await BackgroundSyncEngine.run(run) }
        work.cancel()
        let outcome = await work.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(drained.count, 0)
    }

    func testAccountChangeAfterDrainAbortsBeforeFetch() async {
        let prepared = ApplyCounter()
        let run = run(
            isCurrent: { _, _ in true },
            drain: {
                // Engine checks again after the await and sees the switch.
            },
            operations: [
                BackgroundSyncOperation(entityType: .sessions) {
                    prepared.count += 1
                    return BackgroundSyncPreparedOperation {}
                }
            ]
        )

        // Runs with a live scope that flips only after the drain completes.
        let liveScope = LiveScope(current: true)
        let switchedRun = BackgroundSyncRun(
            accountUserID: account,
            accountEpoch: 1,
            isCurrent: { _, _ in liveScope.current },
            drain: {
                liveScope.current = false
            },
            operations: run.operations
        )

        let outcome = await BackgroundSyncEngine.run(switchedRun)

        XCTAssertEqual(outcome, .accountChanged)
        XCTAssertEqual(prepared.count, 0)
    }

    func testAccountChangeDuringFetchAbortsBeforeApply() async {
        let applied = ApplyCounter()
        let liveScope = LiveScope(current: true)
        let run = BackgroundSyncRun(
            accountUserID: account,
            accountEpoch: 1,
            isCurrent: { _, _ in liveScope.current },
            drain: {},
            operations: [
                BackgroundSyncOperation(entityType: .sessions) {
                    liveScope.current = false
                    return BackgroundSyncPreparedOperation {
                        applied.count += 1
                    }
                }
            ]
        )

        let outcome = await BackgroundSyncEngine.run(run)

        XCTAssertEqual(outcome, .accountChanged)
        XCTAssertEqual(applied.count, 0)
    }

    func testCancellationBeforeApplyLeavesCursorUntouched() async throws {
        let workspace = CachedWorkspace(store: try LocalCacheStore())
        let prepared = ApplyCounter()
        let run = BackgroundSyncRun(
            accountUserID: account,
            accountEpoch: 1,
            isCurrent: { _, _ in true },
            drain: {},
            operations: [
                BackgroundSyncOperation(entityType: .sessions) {
                    try await Task.sleep(nanoseconds: 50_000_000)
                    guard !Task.isCancelled else { throw CancellationError() }
                    prepared.count += 1
                    return BackgroundSyncPreparedOperation {
                        try workspace.reconcileDelta(
                            RemoteEntityDelta(
                                changes: [RemoteEntityChange(
                                    entityID: self.sessionID.uuidString,
                                    value: self.session(),
                                    updatedAt: Date()
                                )],
                                activeValues: [self.session()],
                                cursor: SomeCursor.value
                            ),
                            accountUserID: self.account,
                            entityType: .sessions
                        )
                    }
                }
            ]
        )

        let work = Task { await BackgroundSyncEngine.run(run) }
        try await Task.sleep(nanoseconds: 10_000_000)
        work.cancel()
        let outcome = await work.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(prepared.count, 0)
        XCTAssertNil(try workspace.cursor(
            accountUserID: account,
            entityType: .sessions
        ))
    }

    func testApplyReconcilesDeltaAndAdvancesCursor() async throws {
        let workspace = CachedWorkspace(store: try LocalCacheStore())
        let run = BackgroundSyncRun(
            accountUserID: account,
            accountEpoch: 1,
            isCurrent: { _, _ in true },
            drain: {},
            operations: [
                BackgroundSyncOperation(entityType: .sessions) {
                    let cursor = try workspace.cursor(
                        accountUserID: self.account,
                        entityType: .sessions
                    )
                    XCTAssertNil(cursor)
                    return BackgroundSyncPreparedOperation {
                        try workspace.reconcileDelta(
                            RemoteEntityDelta(
                                changes: [RemoteEntityChange(
                                    entityID: self.sessionID.uuidString,
                                    value: self.session(),
                                    updatedAt: Date()
                                )],
                                activeValues: [self.session()],
                                cursor: SomeCursor.value
                            ),
                            accountUserID: self.account,
                            entityType: .sessions
                        )
                    }
                }
            ]
        )

        let outcome = await BackgroundSyncEngine.run(run)

        XCTAssertEqual(outcome, .completed(1))
        XCTAssertEqual(
            try workspace.cursor(
                accountUserID: account,
                entityType: .sessions
            ),
            SomeCursor.value
        )
        XCTAssertEqual(
            try workspace.load(accountUserID: account).sessions,
            [session()]
        )
    }
}

private final class LiveScope: @unchecked Sendable {
    var current: Bool

    init(current: Bool) {
        self.current = current
    }
}

private enum SomeCursor {
    static let value = "2026-08-24T00:00:00Z"
}
