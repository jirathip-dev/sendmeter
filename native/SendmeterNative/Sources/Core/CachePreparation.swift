import Foundation

// MARK: - Local cache preparation (#921)

/// #921: why the local cache could not be prepared.
///
/// The reason is account-agnostic diagnostics data: it names the launch-time
/// failure so Settings' diagnostics ring can show it, and it is deliberately
/// free of any raw persistence vocabulary. It is never rendered as a
/// user-facing message by itself.
public enum CacheUnavailableReason: Error, Equatable, Sendable {
    /// There is no application-support directory to put the cache in.
    case noSupportDirectory
    /// Creating the directory, opening the database, or running the schema
    /// migrations threw. Carries the localized description for diagnostics.
    case openFailed(String)

    /// The diagnostics-ring detail. Keeps the pre-#921 message shape
    /// (`Local cache unavailable: …`) so an existing ring entry reads the same.
    public var detail: String {
        switch self {
        case .noSupportDirectory:
            return "no application-support directory"
        case .openFailed(let message):
            return message
        }
    }
}

/// #921: what the app knows about the local cache at a point in time.
///
/// A cache that has not answered yet is `preparing`, not "empty": zero counts
/// read from an unready store are unknowns, so every surface that derives a
/// claim from them must treat this as "no answer yet" (`CacheReadiness`
/// `honestSyncInputs(_:)`) instead of reporting success.
public enum CacheReadiness: Equatable, Sendable {
    /// The preparation flight is running (or has not been started yet).
    case preparing
    /// The store is open and migrated; cache reads and writes may run.
    case ready
    /// Preparation failed. The app runs network-only and may retry on a later
    /// lifecycle entrypoint (the failure is recoverable, not permanent).
    case unavailable(CacheUnavailableReason)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// #921: the mutation-sync inputs a cache that has not produced an answer
    /// can honestly support.
    ///
    /// `MutationSyncStatus.resolve` treats an unread pending-write answer as
    /// `notLoaded` ("Checking…"), never as `synced`. A cache that is still
    /// opening — or never opened — cannot have read its unsynced rows, so its
    /// zero unsynced count must not be allowed to claim local persistence
    /// success. This gate is the one place that rule lives.
    public func honestSyncInputs(
        _ inputs: MutationSyncStatusInputs
    ) -> MutationSyncStatusInputs {
        guard isReady else {
            var gated = inputs
            gated.hasLoadedPendingWrites = false
            return gated
        }
        return inputs
    }
}

/// #921: one successfully opened, migrated cache.
public struct PreparedLocalCache: Sendable {
    public let workspace: CachedWorkspace
    public let openedAt: Date

    public init(workspace: CachedWorkspace, openedAt: Date = Date()) {
        self.workspace = workspace
        self.openedAt = openedAt
    }
}

/// #921/#922: the injectable storage seams of the local cache layer.
///
/// Production is `.live`. The seams exist because the two properties this
/// layer must have cannot be observed from the outside: that a *slow* store
/// cannot block the main actor, and that a *failing* store surfaces an honest
/// state instead of a silent empty cache. A test drives both by substituting
/// the opener (and, for #922, the storage-side hop before a snapshot read).
public struct CacheStorageSeams: Sendable {
    /// Opens the SQLite store at `databaseURL`. Must do the file creation,
    /// database open and schema migration itself — the pre-#921 call site did
    /// all three inline on the main actor.
    public typealias StoreOpener = @Sendable (_ databaseURL: URL) async throws -> LocalCacheStore

    public var openStore: StoreOpener

    /// #922: awaited on the STORAGE side before a point-in-time snapshot read.
    /// Production does nothing; a probe holds it to keep storage busy while
    /// proving the main actor stayed responsive.
    public var beforeSnapshotRead: @Sendable () async -> Void

    public init(
        openStore: @escaping StoreOpener,
        beforeSnapshotRead: @escaping @Sendable () async -> Void = {}
    ) {
        self.openStore = openStore
        self.beforeSnapshotRead = beforeSnapshotRead
    }

    /// The shipped behaviour: open a file-backed cache at the given URL.
    public static let live = CacheStorageSeams(
        openStore: { databaseURL in try LocalCacheStore(databaseURL: databaseURL) }
    )
}

/// #921: serializes the store-open step process-wide.
///
/// The open is not just a file handle: it runs the schema migrations, which
/// need exclusive access to the cache file's migration ledger. The pre-#921
/// implementation got that serialization for free by opening inside
/// `AppModel.init` on the main actor; a flight that runs on the storage side
/// must keep the guarantee explicitly, or two `AppModel` instances (a test
/// harness, or an app plus an extension host) opening the same cache at the
/// same time collide with `SQLite error 5: database is locked`.
///
/// The gate is entered once per open and the shipped opener never suspends
/// inside it, so the store construction is exclusive. An injected opener that
/// deliberately suspends (a delay probe) releases the gate for the duration of
/// its own wait, which is exactly the concurrency such a probe intends.
public actor CacheStoreOpenGate {
    public static let shared = CacheStoreOpenGate()

    public init() {}

    func open(_ body: () async throws -> LocalCacheStore) async throws -> LocalCacheStore {
        try await body()
    }
}

/// #921: the one lifetime owner of local-cache preparation.
///
/// An `AppModel` used to create its directory and open GRDB — running the
/// schema migrations with it — synchronously inside `init`, which is on the
/// main actor before the app can present its first frame. This actor moves
/// that whole step to the storage side, and makes it single-flight: the
/// bootstrap, the foreground pass and a background app-refresh all join the
/// SAME flight instead of each opening (and migrating) their own handle.
///
/// Failure is recoverable rather than terminal: a failed flight is not
/// retained, so the next lifecycle entrypoint may retry. A successful flight
/// IS retained, so the store is opened exactly once per process.
public actor CachePreparation {
    /// The cache file name inside the account-agnostic support directory.
    public static let databaseFilename = "local-cache.sqlite"

    private var flight: Task<Result<PreparedLocalCache, CacheUnavailableReason>, Never>?
    private var attempts = 0

    public init() {}

    /// How many times the injected opener has actually run. Two callers that
    /// arrive together must leave this at `1`.
    public var openAttempts: Int { attempts }

    /// Joins the single preparation flight, starting it when there is none.
    ///
    /// The work runs in a detached task, so neither the caller's actor nor the
    /// main thread is blocked while the store opens — a caller only suspends
    /// on the flight's value. Concurrent callers share one flight, and a
    /// caller that arrives after a successful flight gets its cached result
    /// without touching the file system again.
    public func preparedCache(
        directory: URL?,
        databaseFilename: String = CachePreparation.databaseFilename,
        seams: CacheStorageSeams = .live
    ) async -> Result<PreparedLocalCache, CacheUnavailableReason> {
        guard let directory else {
            // Nothing to open, so no flight and no attempt: the missing
            // directory is answered synchronously.
            return .failure(.noSupportDirectory)
        }
        if let flight {
            return await flight.value
        }
        attempts += 1
        let task = Task.detached(priority: .userInitiated) {
            await CachePreparation.open(
                directory: directory,
                databaseFilename: databaseFilename,
                seams: seams
            )
        }
        flight = task
        let result = await task.value
        switch result {
        case .success:
            break
        case .failure:
            // A failed open must not poison the process: the next entrypoint
            // (foreground pass, background task) retries with a fresh flight.
            flight = nil
        }
        return result
    }

    /// The storage-side half: create the directory, open the store, run the
    /// migrations. Never runs on the caller's actor.
    private static func open(
        directory: URL,
        databaseFilename: String,
        seams: CacheStorageSeams
    ) async -> Result<PreparedLocalCache, CacheUnavailableReason> {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let store = try await CacheStoreOpenGate.shared.open {
                try await seams.openStore(
                    directory.appendingPathComponent(databaseFilename, isDirectory: false)
                )
            }
            return .success(PreparedLocalCache(workspace: CachedWorkspace(store: store)))
        } catch {
            return .failure(.openFailed(error.localizedDescription))
        }
    }
}
