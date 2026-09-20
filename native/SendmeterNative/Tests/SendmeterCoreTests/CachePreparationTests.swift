import XCTest

@testable import SendmeterCore

/// #921: the local cache is prepared by ONE off-main-actor flight, and a
/// store that is slow, missing or broken is reported honestly instead of
/// being reported as a successfully persisted local state.
///
/// These are the host-level (SentmeterCore package) proofs. The app-level
/// proof that `AppModel.init` no longer opens the store — and that the first
/// frame still renders while storage is gated — is
/// `SendmeterNativeTests/CachePreparationAppTests`.
final class CachePreparationTests: XCTestCase {
    // MARK: - Doubles

    /// Records what each opener invocation actually observed, from inside the
    /// opener's own executor rather than from a helper actor's.
    private actor OpenLog {
        private(set) var invocationCount = 0
        private(set) var mainThreadFlags: [Bool] = []

        func record(onMainThread: Bool) {
            invocationCount += 1
            mainThreadFlags.append(onMainThread)
        }
    }

    /// A storage-side gate: the opener blocks here until the test opens it, so
    /// "the store is still opening" is a state a test can hold and inspect.
    private actor Gate {
        private var isOpen = false
        private var hasEntry = false
        private var openWaiters: [CheckedContinuation<Void, Never>] = []
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            hasEntry = true
            let entries = entryWaiters
            entryWaiters = []
            entries.forEach { $0.resume() }
            if isOpen { return }
            await withCheckedContinuation { openWaiters.append($0) }
        }

        func waitForEntry() async {
            if hasEntry { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func open() {
            isOpen = true
            let waiters = openWaiters
            openWaiters = []
            waiters.forEach { $0.resume() }
        }
    }

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-preparation-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - One flight

    func testConcurrentCallersShareOnePreparationFlight() async throws {
        let log = OpenLog()
        let gate = Gate()
        let seams = CacheStorageSeams(openStore: { _ in
            let onMainThread = isRunningOnMainThread()
            await log.record(onMainThread: onMainThread)
            await gate.wait()
            return try LocalCacheStore()
        })
        let preparation = CachePreparation()
        let directory = makeDirectory()

        async let first = preparation.preparedCache(directory: directory, seams: seams)
        async let second = preparation.preparedCache(directory: directory, seams: seams)
        await gate.waitForEntry()
        await gate.open()
        let results = await [first, second]

        for result in results {
            guard case .success = result else {
                return XCTFail("expected a prepared cache, got \(result)")
            }
        }
        let invocations = await log.invocationCount
        XCTAssertEqual(invocations, 1, "two callers must share one open")
        let attempts = await preparation.openAttempts
        XCTAssertEqual(attempts, 1)
        // Both callers got the same handle, not two handles on one file.
        let firstStore = results[0].preparedStore
        let secondStore = results[1].preparedStore
        XCTAssertTrue(firstStore === secondStore)
    }

    func testASuccessfulFlightIsReusedWithoutTouchingStorageAgain() async throws {
        let log = OpenLog()
        let seams = CacheStorageSeams(openStore: { _ in
            await log.record(onMainThread: isRunningOnMainThread())
            return try LocalCacheStore()
        })
        let preparation = CachePreparation()
        let directory = makeDirectory()

        guard case .success = await preparation.preparedCache(
            directory: directory,
            seams: seams
        ) else { return XCTFail("first preparation failed") }
        guard case .success = await preparation.preparedCache(
            directory: directory,
            seams: seams
        ) else { return XCTFail("second preparation failed") }
        guard case .success = await preparation.preparedCache(
            directory: directory,
            seams: seams
        ) else { return XCTFail("third preparation failed") }

        let invocations = await log.invocationCount
        XCTAssertEqual(invocations, 1, "the store opens exactly once per process")
    }

    @MainActor
    func testTheStoreOpenerNeverRunsOnTheCallersActor() async throws {
        let log = OpenLog()
        let seams = CacheStorageSeams(openStore: { _ in
            await log.record(onMainThread: isRunningOnMainThread())
            return try LocalCacheStore()
        })
        let preparation = CachePreparation()

        guard case .success = await preparation.preparedCache(
            directory: makeDirectory(),
            seams: seams
        ) else { return XCTFail("preparation failed") }

        let flags = await log.mainThreadFlags
        XCTAssertEqual(flags, [false], "directory creation + open + migration are off the main actor")
    }

    // MARK: - Failure and recovery

    func testAFailedOpenSurfacesUnavailableAndTheNextCallerCanRecover() async throws {
        let log = OpenLog()
        let shouldFail = OpenFailureSwitch(fails: true)
        let seams = CacheStorageSeams(openStore: { _ in
            await log.record(onMainThread: isRunningOnMainThread())
            if await shouldFail.consumeFailure() {
                throw CachePreparationTestError.opener
            }
            return try LocalCacheStore()
        })
        let preparation = CachePreparation()
        let directory = makeDirectory()

        let failed = await preparation.preparedCache(directory: directory, seams: seams)
        guard case .failure(.openFailed(let message)) = failed else {
            return XCTFail("expected an honest open failure, got \(failed)")
        }
        XCTAssertFalse(message.isEmpty)
        let attemptCount = await preparation.openAttempts
        XCTAssertEqual(attemptCount, 1)

        let recovered = await preparation.preparedCache(directory: directory, seams: seams)
        guard case .success = recovered else {
            return XCTFail("a failed flight must be retryable, got \(recovered)")
        }
        let attemptsAfterRecovery = await preparation.openAttempts
        XCTAssertEqual(attemptsAfterRecovery, 2, "recovery is a new flight, not a replay")

        guard case .success = await preparation.preparedCache(directory: directory, seams: seams)
        else { return XCTFail("cached success was not reused") }
        let attemptsAfterReuse = await preparation.openAttempts
        XCTAssertEqual(attemptsAfterReuse, 2)
    }

    func testAMissingSupportDirectoryIsReportedWithoutOpeningAnything() async throws {
        let log = OpenLog()
        let seams = CacheStorageSeams(openStore: { _ in
            await log.record(onMainThread: isRunningOnMainThread())
            return try LocalCacheStore()
        })
        let preparation = CachePreparation()

        let result = await preparation.preparedCache(directory: nil, seams: seams)
        guard case .failure(.noSupportDirectory) = result else {
            return XCTFail("expected .noSupportDirectory, got \(result)")
        }
        let invocations = await log.invocationCount
        XCTAssertEqual(invocations, 0)
        let attempts = await preparation.openAttempts
        XCTAssertEqual(attempts, 0)
    }

    // MARK: - An unready cache never claims local persistence success

    func testAnUnreadyCacheNeverResolvesToSynced() {
        let zeroInputs = MutationSyncStatusInputs(
            hasLoadedPendingWrites: true,
            queuedCount: 0,
            unsyncedCacheCount: 0,
            quarantinedCount: 0
        )
        // The premise: these inputs DO read as "Synced" once the cache has
        // answered. Without that, the gate below would be vacuous.
        XCTAssertEqual(MutationSyncStatus.resolve(zeroInputs).state, .synced)
        XCTAssertEqual(MutationSyncStatus.resolve(zeroInputs).statusLabel, "Synced")

        for readiness in [
            CacheReadiness.preparing,
            .unavailable(.noSupportDirectory),
            .unavailable(.openFailed("disk full")),
        ] {
            let status = MutationSyncStatus.resolve(readiness.honestSyncInputs(zeroInputs))
            XCTAssertEqual(
                status.state,
                .notLoaded,
                "\(readiness) must not report a local persistence success"
            )
            XCTAssertEqual(status.statusLabel, "Checking…")
        }

        // …and a ready cache is unchanged by the gate.
        let ready = MutationSyncStatus.resolve(CacheReadiness.ready.honestSyncInputs(zeroInputs))
        XCTAssertEqual(ready.state, .synced)
    }

    func testAnUnreadyCacheStillReportsWorkTheQueueItselfProved() {
        let inputs = MutationSyncStatusInputs(
            hasLoadedPendingWrites: true,
            queuedCount: 2,
            unsyncedCacheCount: 5,
            quarantinedCount: 0
        )
        let gated = CacheReadiness.unavailable(.openFailed("disk full")).honestSyncInputs(inputs)
        // The gate only removes the *claim* the cache's own read would have
        // made; the queue's measured pending work still shows.
        XCTAssertEqual(gated.queuedCount, 2)
        XCTAssertEqual(gated.unsyncedCacheCount, 5)
        XCTAssertEqual(MutationSyncStatus.resolve(gated).state, .notLoaded)
    }
}

/// One-way failure switch: consume exactly the first failure.
private actor OpenFailureSwitch {
    private var fails: Bool

    init(fails: Bool) {
        self.fails = fails
    }

    func consumeFailure() -> Bool {
        guard fails else { return false }
        fails = false
        return true
    }
}

private enum CachePreparationTestError: Error {
    case opener
}

private extension Result where Success == PreparedLocalCache {
    /// The opened store handle, or `nil` for a failure.
    var preparedStore: LocalCacheStore? {
        switch self {
        case .success(let prepared): return prepared.workspace.store
        case .failure: return nil
        }
    }
}

/// Reports whether the calling thread is the main thread. A synchronous helper
/// on purpose: `Thread.isMainThread` is unavailable from asynchronous contexts
/// (an error in the Swift 6 language mode), and the openers below are async.
func isRunningOnMainThread() -> Bool {
    Thread.isMainThread
}
