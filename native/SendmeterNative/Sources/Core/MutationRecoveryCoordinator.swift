import Foundation

// MARK: - Durable mutation recovery ownership (#935)

/// #935: the durable-queue seam the mutation-recovery coordinator sequences
/// through.
///
/// Production has exactly ONE conformance — `DurableQueue`, the app's single
/// `pending-writes.json` — so the coordinator cannot grow a second queue, a
/// second persistence format or a competing drain timer. A test conforms its
/// own fake (or drives the real queue) to observe one rule without an app
/// model, a simulator, UIKit/SwiftUI or Bluetooth.
///
/// The payload type stays the caller's: this seam exposes the queue's own
/// `DurableQueueItem` envelope (stable id, account, revision, ordering claim,
/// backoff and rejection stamps), never a second item shape.
public protocol MutationRecoveryQueuing: Sendable {
    associatedtype RecoveryPayload: Codable & Sendable

    /// The entries a drain pass may attempt: never quarantined, and only
    /// backoff-due when `dueAt` is given (`nil` = active, regardless of
    /// backoff — the sign-out / explicit-retry shape).
    func recoveryDueItems(
        accountUserID: UUID,
        dueAt: Date?
    ) async -> [DurableQueueItem<RecoveryPayload>]

    /// Every non-quarantined entry for the account: the set an explicit
    /// "Retry Now" pass walks, and the count it publishes before/after.
    func recoveryActiveItems(accountUserID: UUID) async -> [DurableQueueItem<RecoveryPayload>]

    /// The quarantined entries for the account, newest rejection first.
    func recoveryQuarantinedItems(accountUserID: UUID) async -> [DurableQueueItem<RecoveryPayload>]

    func recoveryItem(id: UUID, accountUserID: UUID) async -> DurableQueueItem<RecoveryPayload>?

    /// Record one failed attempt: attempts, backoff, diagnostic and the
    /// permanent-attempt budget, conditioned by the mode and the captured
    /// revision. Returns `false` when a newer replacement owns the identity.
    @discardableResult
    func recoveryMarkFailure(
        id: UUID,
        accountUserID: UUID,
        error: String,
        classification: RejectionClass,
        code: String?,
        now: Date,
        countsTowardQuarantine: Bool,
        expectedRevision: UUID?
    ) async throws -> Bool

    /// #675: clear one rejection stamp and reset its budget — the explicit
    /// user action that makes a quarantined entry attemptable again.
    @discardableResult
    func recoveryClearQuarantine(
        id: UUID,
        accountUserID: UUID,
        now: Date
    ) async throws -> QueueRejection?

    /// #675 F7 + N1: re-apply the stamp after a failed manual retry, keeping
    /// the prior diagnostic unless the retry itself was a fresh permanent
    /// rejection.
    @discardableResult
    func recoveryRequarantine(
        id: UUID,
        accountUserID: UUID,
        previous: QueueRejection?,
        classification: RejectionClass,
        code: String?,
        detail: String,
        now: Date
    ) async throws -> Bool

    /// #675: discard ONE quarantined entry, conditioned on its captured
    /// revision so a concurrent retry/replacement wins the race.
    @discardableResult
    func recoveryDiscardQuarantined(
        id: UUID,
        accountUserID: UUID,
        expectedRevision: UUID?,
        now: Date
    ) async throws -> Bool
}

extension DurableQueue: MutationRecoveryQueuing {
    public typealias RecoveryPayload = Payload

    public func recoveryDueItems(
        accountUserID: UUID,
        dueAt: Date?
    ) async -> [DurableQueueItem<Payload>] {
        items(for: accountUserID, dueAt: dueAt, includeQuarantined: false)
    }

    public func recoveryActiveItems(accountUserID: UUID) async -> [DurableQueueItem<Payload>] {
        items(for: accountUserID, dueAt: nil, includeQuarantined: false)
    }

    public func recoveryQuarantinedItems(accountUserID: UUID) async -> [DurableQueueItem<Payload>] {
        quarantinedItems(for: accountUserID)
    }

    public func recoveryItem(id: UUID, accountUserID: UUID) async -> DurableQueueItem<Payload>? {
        item(id: id, accountUserID: accountUserID)
    }

    @discardableResult
    public func recoveryMarkFailure(
        id: UUID,
        accountUserID: UUID,
        error: String,
        classification: RejectionClass,
        code: String?,
        now: Date,
        countsTowardQuarantine: Bool,
        expectedRevision: UUID?
    ) async throws -> Bool {
        try markFailure(
            id: id,
            accountUserID: accountUserID,
            error: error,
            classification: classification,
            code: code,
            now: now,
            countsTowardQuarantine: countsTowardQuarantine,
            expectedRevision: expectedRevision
        )
    }

    @discardableResult
    public func recoveryClearQuarantine(
        id: UUID,
        accountUserID: UUID,
        now: Date
    ) async throws -> QueueRejection? {
        try retryQuarantined(id: id, accountUserID: accountUserID, now: now)
    }

    @discardableResult
    public func recoveryRequarantine(
        id: UUID,
        accountUserID: UUID,
        previous: QueueRejection?,
        classification: RejectionClass,
        code: String?,
        detail: String,
        now: Date
    ) async throws -> Bool {
        try requarantine(
            id: id,
            accountUserID: accountUserID,
            previous: previous,
            classification: classification,
            code: code,
            detail: detail,
            now: now
        )
    }

    @discardableResult
    public func recoveryDiscardQuarantined(
        id: UUID,
        accountUserID: UUID,
        expectedRevision: UUID?,
        now: Date
    ) async throws -> Bool {
        try discardQuarantined(
            id: id,
            accountUserID: accountUserID,
            now: now,
            expectedRevision: expectedRevision
        )
    }
}

// MARK: - Upload outcomes

/// #935: the classification + diagnostic one failed attempt recorded, so the
/// recovery owner can decide whether a manual retry replaces the prior
/// rejection stamp or restores it verbatim (#675 N1).
public struct MutationUploadFailure: Equatable, Sendable {
    public let classification: RejectionClass
    public let code: String?
    public let detail: String

    public init(classification: RejectionClass, code: String?, detail: String) {
        self.classification = classification
        self.code = code
        self.detail = detail
    }
}

/// #935: what one upload attempt did.
///
/// `uploaded == false` with `failure == nil` is the deliberate NO-OP result
/// (another producer owns the identity, the account moved, the item was
/// replaced, the payload was terminalized) — it is never a failure verdict,
/// and it must not spend a backoff or quarantine budget.
public struct MutationUploadOutcome: Equatable, Sendable {
    public let uploaded: Bool
    public let failure: MutationUploadFailure?

    public init(uploaded: Bool, failure: MutationUploadFailure?) {
        self.uploaded = uploaded
        self.failure = failure
    }

    public static let noOp = MutationUploadOutcome(uploaded: false, failure: nil)
}

// MARK: - Pass reports

/// #935: one drain (or explicit retry) pass, as its owner saw it.
public struct MutationRecoveryPassReport: Equatable, Sendable {
    public let mode: QueueUploadMode
    /// The account's active (non-quarantined) backlog when the pass started.
    public let queuedBefore: Int
    /// The items this pass captured as due and attempted.
    public let dueItems: Int
    public let uploaded: Int
    /// Attempts whose failure was durably recorded (a no-op result is not a
    /// failure).
    public let failed: Int
    /// `false` when the pass stopped before its snapshot: the residue adopters
    /// refused, or the account moved under them.
    public let didAdoptResidues: Bool
    /// The captured account/epoch stopped being live during the pass.
    public let accountChanged: Bool
    /// The pass stopped starting new uploads on an explicit cancellation
    /// signal. The remainder stays durable.
    public let isCancelled: Bool

    public init(
        mode: QueueUploadMode,
        queuedBefore: Int,
        dueItems: Int,
        uploaded: Int,
        failed: Int,
        didAdoptResidues: Bool,
        accountChanged: Bool,
        isCancelled: Bool
    ) {
        self.mode = mode
        self.queuedBefore = queuedBefore
        self.dueItems = dueItems
        self.uploaded = uploaded
        self.failed = failed
        self.didAdoptResidues = didAdoptResidues
        self.accountChanged = accountChanged
        self.isCancelled = isCancelled
    }
}

/// #935: one quarantined-entry recovery pass.
public struct MutationQuarantineRecoveryReport: Equatable, Sendable {
    /// The entries the pass attempted (stamp cleared, one manual upload each).
    public let attempted: Int
    /// The entries whose manual retry uploaded.
    public let recovered: Int
    /// `false` when the pass stopped before reading quarantine: the residue
    /// preparation refused, or the account moved under it.
    public let didPrepare: Bool

    public init(attempted: Int, recovered: Int, didPrepare: Bool) {
        self.attempted = attempted
        self.recovered = recovered
        self.didPrepare = didPrepare
    }
}

// MARK: - Explicit retry ownership

/// #935: the single-flight owner of the explicit "Retry Now" pass. Identity +
/// epoch are captured before the first await, and the token prevents an older
/// same-account pass from finishing a newer one.
public struct MutationRetryOwnership: Equatable, Sendable {
    public let fetch: AccountScopedFetch
    public let token: UUID

    public init(fetch: AccountScopedFetch, token: UUID = UUID()) {
        self.fetch = fetch
        self.token = token
    }
}

/// #935: the single-flight gate for the explicit retry pass, and the only
/// place that decides which pass may clear the app's retry state. A second tap
/// while a pass is in flight coalesces onto it (the pass's progress is already
/// published) instead of racing a second pass against the same queue.
public struct MutationRetryGate: Equatable, Sendable {
    private var activeOwner: MutationRetryOwnership?

    public init() {}

    /// Establish ownership before the caller's first await. `nil` means another
    /// pass already owns it.
    public mutating func claim(_ fetch: AccountScopedFetch) -> MutationRetryOwnership? {
        guard activeOwner == nil else { return nil }
        let owner = MutationRetryOwnership(fetch: fetch)
        activeOwner = owner
        return owner
    }

    /// Whether `owner` is still the active pass AND still describes the live
    /// account/epoch.
    public func owns(_ owner: MutationRetryOwnership, isCurrent: Bool) -> Bool {
        activeOwner == owner && isCurrent
    }

    /// Release the pass. Returns `false` when a newer pass (or a newer account)
    /// owns the state now, so the caller must not clear it.
    @discardableResult
    public mutating func finish(_ owner: MutationRetryOwnership, isCurrent: Bool) -> Bool {
        guard owns(owner, isCurrent: isCurrent) else { return false }
        activeOwner = nil
        return true
    }

    public mutating func reset() {
        activeOwner = nil
    }
}

// MARK: - The coordinator

/// #935: the single owner of the app's durable mutation recovery rules.
///
/// Every recovery entry point routes through this one type — the automatic
/// drain (`AppModel.drainQueue`, including the sign-out drain), the explicit
/// retry pass (`retryAllQueuedWrites`), the per-item manual retry
/// (`retryQueuedWrite`), failure/backoff recording, and the quarantine
/// lifecycle (retry, requarantine, discard):
///
/// - the pass sequence: adopt the legacy residues the queue alone cannot
///   address, snapshot the mode's due set from the ONE durable queue, attempt
///   each item, then acknowledge (publish) the pass's result;
/// - the cancel/account fences between those steps (explicit inputs, never
///   inferred from a swallowed error);
/// - the failure path: one recorded attempt through the queue's own backoff
///   and permanent-attempt budget, with the mode's quarantine rule;
/// - the manual-retry loop (`QueueRetryPolicy`): wait for an in-flight owner,
///   re-read the durable item, bypass ordinary backoff, never bypass
///   quarantine;
/// - quarantine recovery: clear the stamp, attempt ONCE manually, and re-stamp
///   immediately on failure so a rejected entry never re-arms automatic
///   attempts behind the user's back (#675 F5/F7/N1).
///
/// Everything below stays at the BOUNDARY and is never inferred inside:
///
/// - account identity/epoch — passed in and re-checked via
///   `WorkspaceAccountBoundary` (the same boundary #934's workspace coordinator
///   takes; there is one account fence in the app, not two);
/// - the queue handle — the caller's ONE `DurableQueue`, injected per call
///   through `MutationRecoveryQueuing`;
/// - the upload itself — injected per call, so the payload switch, the
///   optimistic UI and the cache confirmation stay with the app;
/// - completion/spinner ownership — `MutationRetryGate`, held by the caller;
/// - the legacy residue adopters — injected, because each entity's residue has
///   its own server-anchored adoption rule (#916–#919);
/// - cancellation — an explicit `isCancelled` input.
@MainActor
public struct MutationRecoveryCoordinator {
    public init() {}

    // MARK: Drain

    /// One pass over the account's due entries: adopt the legacy residues
    /// first (a cache-only pending row has no replay intent, so iterating the
    /// durable queue alone could never address it), snapshot the mode's due
    /// set, then attempt each item through the injected uploader. The snapshot
    /// is a STARTING set, never a claim: the uploader re-reads the durable item
    /// and decides for itself whether the identity is still attemptable.
    ///
    /// An attempt that fails to upload is recorded by the uploader (through
    /// `recordFailure`) and does not stop the pass; the account fence does, and
    /// so does an explicit cancellation — in both cases the remainder stays
    /// durable for the next pass.
    ///
    /// `now` is the pass's clock. `nil` (the production shape) reads it at the
    /// SNAPSHOT, after the residue adopters ran: an intent adopted during this
    /// pass carries that adoption's own `nextAttemptAt`, so a clock captured
    /// before the adopters would silently exclude everything they just
    /// presented.
    @discardableResult
    public func drain<Queue: MutationRecoveryQueuing>(
        boundary: WorkspaceAccountBoundary,
        mode: QueueUploadMode,
        in queue: Queue,
        now: Date? = nil,
        isCancelled: @MainActor () -> Bool = { false },
        adoptResidues: (@MainActor () async -> Bool)? = nil,
        upload: @MainActor (DurableQueueItem<Queue.RecoveryPayload>, QueueUploadMode) async -> MutationUploadOutcome,
        acknowledge: @MainActor () async -> Void
    ) async -> MutationRecoveryPassReport {
        let accountUserID = boundary.accountUserID
        let queuedBefore = await queue.recoveryActiveItems(accountUserID: accountUserID).count
        if let adoptResidues {
            guard await adoptResidues(), boundary.canApply() else {
                return MutationRecoveryPassReport(
                    mode: mode,
                    queuedBefore: queuedBefore,
                    dueItems: 0,
                    uploaded: 0,
                    failed: 0,
                    didAdoptResidues: false,
                    accountChanged: !boundary.canApply(),
                    isCancelled: false
                )
            }
        }
        let due = await queue.recoveryDueItems(
            accountUserID: accountUserID,
            dueAt: mode.revalidationDueAt(now: now ?? Date())
        )
        var uploaded = 0
        var failed = 0
        var accountChanged = false
        var cancelled = false
        for item in due {
            guard boundary.canApply() else {
                accountChanged = true
                break
            }
            if isCancelled() {
                cancelled = true
                break
            }
            let outcome = await upload(item, mode)
            if outcome.uploaded {
                uploaded += 1
            } else if outcome.failure != nil {
                failed += 1
            }
        }
        await acknowledge()
        return MutationRecoveryPassReport(
            mode: mode,
            queuedBefore: queuedBefore,
            dueItems: due.count,
            uploaded: uploaded,
            failed: failed,
            didAdoptResidues: true,
            accountChanged: accountChanged,
            isCancelled: cancelled
        )
    }

    // MARK: Explicit retry pass

    /// The explicit "Retry Now" pass: ONE pass per account (the caller's
    /// `MutationRetryGate` claim), measuring the published backlog before and
    /// after, walking the SAME residue adoption + due set the drain uses, and
    /// forcing a manual attempt for each remaining identity.
    ///
    /// Returns `nil` when the pass stopped before its snapshot (residue
    /// adoption refused, or the account moved): nothing was measured, so there
    /// is no outcome to publish.
    public func retryAll<Queue: MutationRecoveryQueuing>(
        boundary: WorkspaceAccountBoundary,
        in queue: Queue,
        adoptResidues: @MainActor () async -> Bool,
        isClaimed: @MainActor (QueueUploadKey) -> Bool,
        waitForOwner: @MainActor (QueueUploadKey) async -> Void,
        upload: @MainActor (DurableQueueItem<Queue.RecoveryPayload>, QueueUploadMode) async -> MutationUploadOutcome,
        acknowledge: @MainActor () async -> Void
    ) async -> MutationRecoveryPassReport? {
        let accountUserID = boundary.accountUserID
        let queuedBefore = await queue.recoveryActiveItems(accountUserID: accountUserID).count
        guard boundary.canApply() else { return nil }
        // #920 AC2: Retry Now addresses the SAME residue set the drain does. A
        // cache-only row has no durable intent, so a button that only iterated
        // the queue could report "done" while the displayed unsynced changes
        // were untouched.
        guard await adoptResidues(), boundary.canApply() else { return nil }
        let pending = await queue.recoveryActiveItems(accountUserID: accountUserID)
        var uploaded = 0
        var failed = 0
        for item in pending {
            guard boundary.canApply() else { break }
            let outcome = await retryOne(
                id: item.id,
                boundary: boundary,
                in: queue,
                isClaimed: isClaimed,
                waitForOwner: waitForOwner,
                upload: upload
            )
            switch outcome {
            case .uploaded:
                uploaded += 1
            case .failed:
                failed += 1
            case .notAttempted:
                break
            }
        }
        guard boundary.canApply() else { return nil }
        await acknowledge()
        return MutationRecoveryPassReport(
            mode: .manual,
            queuedBefore: queuedBefore,
            dueItems: pending.count,
            uploaded: uploaded,
            failed: failed,
            didAdoptResidues: true,
            accountChanged: false,
            isCancelled: false
        )
    }

    /// One identity's manual attempt. A foreground drain may already own the
    /// item when the user taps Retry; returning immediately from the uploader
    /// in that case made Retry look successful while the item stayed pending.
    /// Wait for the owner, re-read the durable item, and then bypass its
    /// automatic backoff for the explicit retry.
    @discardableResult
    public func retryOne<Queue: MutationRecoveryQueuing>(
        id: UUID,
        boundary: WorkspaceAccountBoundary,
        in queue: Queue,
        isClaimed: @MainActor (QueueUploadKey) -> Bool,
        waitForOwner: @MainActor (QueueUploadKey) async -> Void,
        upload: @MainActor (DurableQueueItem<Queue.RecoveryPayload>, QueueUploadMode) async -> MutationUploadOutcome
    ) async -> MutationRecoveryAttempt {
        let key = QueueUploadKey(itemID: id, accountUserID: boundary.accountUserID)
        for _ in 0..<3 {
            guard boundary.canApply() else { return .notAttempted }
            let current = await queue.recoveryItem(
                id: id,
                accountUserID: boundary.accountUserID
            )
            switch QueueRetryPolicy.beforeUpload(
                isClaimed: isClaimed(key),
                hasItem: current != nil,
                isQuarantined: current?.quarantined != nil
            ) {
            case .waitForOwner:
                await waitForOwner(key)
                continue
            case .stop:
                return .notAttempted
            case .upload:
                break
            }
            guard let current else { return .notAttempted }
            guard boundary.canApply() else { return .notAttempted }
            let result = await upload(current, .manual)
            guard boundary.canApply() else { return .notAttempted }
            // A producer can claim the identity in the small gap between the
            // check above and the uploader's own claim. Only that no-op result
            // is retried here; a real failure has already been durably recorded
            // with its class/error/backoff and should be shown to the user.
            switch QueueRetryPolicy.afterUpload(
                uploaded: result.uploaded,
                recordedFailure: result.failure != nil,
                ownerIsClaimed: isClaimed(key)
            ) {
            case .waitForOwner:
                await waitForOwner(key)
                continue
            case .upload, .stop:
                return result.uploaded ? .uploaded : (result.failure != nil ? .failed : .notAttempted)
            }
        }
        return .notAttempted
    }

    // MARK: Failure recording (backoff + quarantine budget)

    /// Record one failed attempt through the ONE queue: the backoff delay, the
    /// attempt counters and the permanent-attempt budget all belong to the
    /// queue's own `markFailure`, and the MODE decides whether this attempt
    /// spends the quarantine budget (#675 F5: an explicit manual retry must
    /// never be what quarantines an entry). `expectedRevision` keeps an old
    /// request from spending a replacement's budget.
    ///
    /// Returns `false` when the record did not apply (a newer replacement owns
    /// the identity, or the entry is already quarantined) — the caller must
    /// then report the no-op rather than the failure.
    @discardableResult
    public func recordFailure<Queue: MutationRecoveryQueuing>(
        item: DurableQueueItem<Queue.RecoveryPayload>,
        failure: MutationUploadFailure,
        mode: QueueUploadMode,
        in queue: Queue,
        now: Date = Date(),
        onFailure: @MainActor (Error) -> Void = { _ in }
    ) async -> Bool {
        do {
            return try await queue.recoveryMarkFailure(
                id: item.id,
                accountUserID: item.accountUserID,
                error: failure.detail,
                classification: failure.classification,
                code: failure.code,
                now: now,
                countsTowardQuarantine: mode.countsTowardQuarantine,
                expectedRevision: item.revision
            )
        } catch {
            onFailure(error)
            return false
        }
    }

    // MARK: Quarantine recovery

    /// #675: the explicit-user-action re-attempt for quarantined entries —
    /// native mirror of the web's `retryStuckRecordings` (#484). With `id` it
    /// retries ONE quarantined entry (the per-item Settings action); without,
    /// all of them. Clears the rejection stamp (fresh bounded-attempt budget)
    /// and attempts one MANUAL upload each.
    ///
    /// #675 F7: a failed manual retry is NOT re-armed onto the hot drain path.
    /// The upload runs manual (so its rejection never spends the quarantine
    /// budget), and on ANY failure the quarantine stamp is immediately
    /// re-applied, so the entry goes straight back to its quarantined,
    /// never-auto-retried state.
    ///
    /// #675 N1: the prior stamp is passed to `requarantine` as `previous`, so a
    /// transient/auth/parked failure on the retry restores the diagnostic
    /// verbatim (code, detail and `at` all survive); only a FRESH `.permanent`
    /// rejection replaces it.
    ///
    /// `prepare` is the caller's residue migration for the paths this entry
    /// point has to attempt before it reads quarantine.
    @discardableResult
    public func retryQuarantined<Queue: MutationRecoveryQueuing>(
        id: UUID? = nil,
        boundary: WorkspaceAccountBoundary,
        in queue: Queue,
        now: Date = Date(),
        prepare: @MainActor () async -> Bool,
        upload: @MainActor (DurableQueueItem<Queue.RecoveryPayload>, QueueUploadMode) async -> MutationUploadOutcome,
        acknowledge: @MainActor () async -> Void,
        onFailure: @MainActor (Error) -> Void = { _ in }
    ) async -> MutationQuarantineRecoveryReport {
        guard await prepare(), boundary.canApply() else {
            return MutationQuarantineRecoveryReport(attempted: 0, recovered: 0, didPrepare: false)
        }
        let quarantined = await queue.recoveryQuarantinedItems(
            accountUserID: boundary.accountUserID
        )
        var attempted = 0
        var recovered = 0
        for item in quarantined where id == nil || item.id == id {
            do {
                guard let previous = try await queue.recoveryClearQuarantine(
                    id: item.id,
                    accountUserID: item.accountUserID,
                    now: now
                ) else { continue }
                attempted += 1
                let outcome = await upload(item, .manual)
                if outcome.uploaded {
                    recovered += 1
                    continue
                }
                let failure = outcome.failure
                try await queue.recoveryRequarantine(
                    id: item.id,
                    accountUserID: item.accountUserID,
                    previous: previous,
                    classification: failure?.classification ?? .retryable,
                    code: failure?.code,
                    detail: failure?.detail ?? item.lastError ?? "Manual retry failed",
                    now: Date()
                )
            } catch {
                onFailure(error)
            }
        }
        await acknowledge()
        return MutationQuarantineRecoveryReport(
            attempted: attempted,
            recovered: recovered,
            didPrepare: true
        )
    }

    /// #675: the queue side of discarding ONE quarantined entry. Quarantined
    /// only, and conditioned on the revision the caller captured, so a
    /// concurrent retry or a newer replacement is never discarded by a stale
    /// snapshot. The caller keeps the UI aftermath (optimistic placeholders,
    /// trash/list refreshes) — this returns what actually happened.
    public func discardQuarantined<Queue: MutationRecoveryQueuing>(
        id: UUID,
        boundary: WorkspaceAccountBoundary,
        in queue: Queue,
        now: Date = Date(),
        onFailure: @MainActor (Error) -> Void = { _ in }
    ) async -> MutationQuarantineDiscard<Queue.RecoveryPayload>? {
        let accountUserID = boundary.accountUserID
        let item = await queue.recoveryItem(id: id, accountUserID: accountUserID)
        guard boundary.canApply() else { return nil }
        do {
            let discarded = try await queue.recoveryDiscardQuarantined(
                id: id,
                accountUserID: accountUserID,
                expectedRevision: item?.revision,
                now: now
            )
            guard discarded else {
                return MutationQuarantineDiscard(item: item, discarded: false)
            }
            guard boundary.canApply() else { return nil }
            return MutationQuarantineDiscard(item: item, discarded: true)
        } catch {
            onFailure(error)
            return nil
        }
    }
}

/// #935: the result of one manual attempt on a durable identity.
public enum MutationRecoveryAttempt: Equatable, Sendable {
    /// The uploader reported success.
    case uploaded
    /// The uploader recorded a failure this pass (the caller surfaces it).
    case failed
    /// Nothing was attempted: quarantined, gone, owned elsewhere, or the
    /// account moved. Never a failure verdict.
    case notAttempted
}

/// #935: the outcome of one quarantine discard, with the item the caller
/// captured (its payload decides the UI aftermath).
public struct MutationQuarantineDiscard<Payload: Codable & Sendable>: Sendable {
    public let item: DurableQueueItem<Payload>?
    public let discarded: Bool

    public init(item: DurableQueueItem<Payload>?, discarded: Bool) {
        self.item = item
        self.discarded = discarded
    }
}
