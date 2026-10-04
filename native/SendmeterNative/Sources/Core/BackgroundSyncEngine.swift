import Foundation

/// One cache write produced by a background sync fetch.
///
/// The fetch happens in `prepare`; the write stays separate so the engine can
/// re-check the account/epoch scope in the gap between network and disk.
///
/// #922: `apply` is async because the write runs on the storage side rather
/// than on the main actor. It is still one hop per entity — the engine never
/// fans out per row.
public struct BackgroundSyncPreparedOperation: @unchecked Sendable {
    public let apply: @MainActor @Sendable () async throws -> Void

    public init(apply: @escaping @MainActor @Sendable () async throws -> Void) {
        self.apply = apply
    }
}

/// One background sync entity: fetch a cursor-bounded delta, then reconcile it
/// into the account's cache as one unit.
public struct BackgroundSyncOperation: @unchecked Sendable {
    public let entityType: LocalCacheEntityType
    public let prepare: @MainActor @Sendable () async throws -> BackgroundSyncPreparedOperation

    public init(
        entityType: LocalCacheEntityType,
        prepare: @escaping @MainActor @Sendable () async throws -> BackgroundSyncPreparedOperation
    ) {
        self.entityType = entityType
        self.prepare = prepare
    }
}

/// The account-scoped inputs for one background sync pass.
public struct BackgroundSyncRun: @unchecked Sendable {
    public let accountUserID: UUID
    public let accountEpoch: UInt64
    public let isCurrent: @MainActor @Sendable (UUID, UInt64) -> Bool
    public let drain: @MainActor @Sendable () async -> Void
    public let operations: [BackgroundSyncOperation]
    /// #992 F1: the outcome enum carries no error, so the engine names a
    /// failed operation here before returning `.failed` — a background pass
    /// used to fail with nothing in the persisted log. Required (no silent
    /// default): a caller must decide where its pass failures are recorded.
    public let recordFailure: @MainActor @Sendable (LocalCacheEntityType, Error) -> Void

    public init(
        accountUserID: UUID,
        accountEpoch: UInt64,
        isCurrent: @escaping @MainActor @Sendable (UUID, UInt64) -> Bool,
        drain: @escaping @MainActor @Sendable () async -> Void,
        operations: [BackgroundSyncOperation],
        recordFailure: @escaping @MainActor @Sendable (LocalCacheEntityType, Error) -> Void
    ) {
        self.accountUserID = accountUserID
        self.accountEpoch = accountEpoch
        self.isCurrent = isCurrent
        self.drain = drain
        self.operations = operations
        self.recordFailure = recordFailure
    }
}

public enum BackgroundSyncOutcome: Equatable, Sendable {
    case completed(Int)
    case cancelled
    case accountChanged
    case failed
}

/// Drives the BGTask body: drain first, then reconcile each cursor-bounded
/// delta, aborting on cancellation or an account/epoch change after every
/// await.
///
/// Each operation's `prepare` is the async network boundary and its `apply` is
/// the synchronous cache reconcile. A cancel or stale scope before `apply`
/// leaves that entity's cursor untouched; if `apply` itself throws, the
/// cursor is also untouched because `CachedWorkspace.reconcileDelta` advances
/// it only after all writes succeed.
@MainActor
public enum BackgroundSyncEngine {
    public static func run(_ run: BackgroundSyncRun) async -> BackgroundSyncOutcome {
        guard run.isCurrent(run.accountUserID, run.accountEpoch) else {
            return .accountChanged
        }
        guard !Task.isCancelled else { return .cancelled }

        await run.drain()
        guard run.isCurrent(run.accountUserID, run.accountEpoch) else {
            return .accountChanged
        }
        guard !Task.isCancelled else { return .cancelled }

        var completed = 0
        for operation in run.operations {
            guard run.isCurrent(run.accountUserID, run.accountEpoch) else {
                return .accountChanged
            }
            guard !Task.isCancelled else { return .cancelled }

            let prepared: BackgroundSyncPreparedOperation
            do {
                prepared = try await operation.prepare()
            } catch {
                guard !Task.isCancelled else { return .cancelled }
                // #992 F1: name the failed entity before the coarse `.failed`
                // outcome loses the error with the pass.
                run.recordFailure(operation.entityType, error)
                return .failed
            }

            guard run.isCurrent(run.accountUserID, run.accountEpoch) else {
                return .accountChanged
            }
            guard !Task.isCancelled else { return .cancelled }

            do {
                try await prepared.apply()
            } catch {
                guard !Task.isCancelled else { return .cancelled }
                run.recordFailure(operation.entityType, error)
                return .failed
            }

            guard run.isCurrent(run.accountUserID, run.accountEpoch) else {
                return .accountChanged
            }
            completed += 1
        }
        return .completed(completed)
    }
}
