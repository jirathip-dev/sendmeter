import Foundation

/// #675: how a single failed upload is classified — the native port of the
/// web's retryable-vs-permanent taxonomy (#484, `classifyHandledFailure` +
/// the `rejection.stuck` quarantine in `src/lib/recordingQueue.ts`).
///
/// The actor ONLY records the verdict; deciding it is the transport's job
/// (`ServerRejectionClassifying`), so the classification rules stay pure and
/// testable and the queue never has to understand PostgREST or SQLSTATEs.
public enum RejectionClass: String, Codable, Sendable, Equatable {
    /// A temporary environment problem — the network dropped, the server
    /// timed out or is erroring, the rate limiter pushed back. The payload is
    /// almost certainly fine and must keep being retried with backoff.
    case retryable
    /// The request was not authenticated/authorized in a way that could be
    /// about the payload at all (expired/revoked access token). Per the #273
    /// rule this is NEVER "permanent data" — it must park, not quarantine:
    /// destroying user data over an auth failure is strictly worse than the
    /// problem being fixed. The entry stays on the hot retry path (next drain
    /// after backoff, or the next sign-in) and the app is expected to recover
    /// the session.
    case auth
    /// #675 F2: a permission/identity denial — SQLSTATE `42501` or an HTTP
    /// 403, i.e. an RLS `with check` refusing the write. This is the
    /// auth-shaped sibling of `auth`: the request's identity is not the one
    /// the payload assumes, so the payload is byte-for-byte fine and would
    /// upload the moment the session is right. It parks exactly like `auth` —
    /// never quarantines, never shelves user data over an identity problem —
    /// mirroring the web's `permission` class, which `isConstraintFailure`
    /// (`src/lib/recordingQueue.ts:650`) never quarantines.
    case parked
    /// The server rejected THIS PAYLOAD's content — a CHECK/NOT NULL/foreign-
    /// key violation, a malformed body, a forbidden write with a valid token.
    /// The payload, not the environment, is the problem. Retried with backoff
    /// a bounded number of times (in case a schema migration is still landing,
    /// mirroring the web's #484 tolerance), then moved to `quarantined`.
    case permanent
}

/// #675: the immutable record of a rejection that moved an entry to
/// `quarantined`. Kept as its own Codable struct so the item can be recovered
/// by clearing `quarantined` (which drops this stamp) and re-attempted like a
/// fresh entry.
public struct QueueRejection: Codable, Equatable, Sendable {
    public let kind: RejectionClass
    public let at: Date
    /// The SQLSTATE / PostgREST code when the transport had one (e.g. `23505`,
    /// `PGRST300`), else `nil`.
    public let code: String?
    /// Short human-readable detail, trimmed (rides in the queue file
    /// indefinitely, so never a raw dump).
    public let detail: String

    public init(kind: RejectionClass, at: Date = Date(), code: String?, detail: String) {
        self.kind = kind
        self.at = at
        self.code = code
        self.detail = String(detail.prefix(500))
    }
}

/// #675: the seam a transport error crosses to tell the queue whether the
/// failure was about the environment (`retryable` / `auth`) or about this
/// payload (`permanent`). The native `PostgRESTError` in SupabaseService.swift
/// conforms; the queue never touches the concrete error type.
public protocol ServerRejectionClassifying {
    var rejectionClass: RejectionClass { get }
}

/// #675: the pure classification rules, ported from the web's
/// `classifyHandledFailure` line (monitoring.ts) as far as the offline queue
/// cares. Kept in Core so `swift test` pins them without the Supabase client:
///
///   * A CONSTRAINT rejection — a SQLSTATE `23xxx` (CHECK/NOT NULL/FK
///     violation) — is `permanent`: the payload's content, not the
///     environment, is the problem. The queue gives it a bounded number of
///     attempts, then quarantines it (never silently drops it).
///   * A 401 is `auth`, even when it carries a constraint code — the #273
///     rule wins: a revoked/expired token is an environment problem, and
///     destroying user data over one is the exact regression the web's
///     forced-sign-out rule exists to prevent. Auth parks, never quarantines.
///   * A 403 / SQLSTATE `42501` (RLS "permission denied") is `parked`, the
///     identity sibling of `auth` (#675 F2): the request's identity, not the
///     payload's content, is what the server refused, and the web's own
///     taxonomy checks this branch BEFORE `auth` (`monitoring.ts:477-492`)
///     and never quarantines it. It parks, never quarantines — a session
///     problem, not a payload problem.
///   * A 404 (`PGRST205` schema-cache reload, classified `schema` on the
///     web) is `retryable`: a genuinely transient window, never proof the
///     payload is bad.
///   * A 400 (`PGRST102` malformed body, `PGRST204` unknown column, `22P02`
///     bad text representation — the statuses PostgREST actually emits for
///     a bad payload) is `permanent` (#675 F4).
///   * A 23505 riding on a 409 is permanent content; a bare 409 (no
///     constraint code) is the unique-violation race the repository already
///     turns into a fetch-and-return, so it is retryable.
///   * Everything else — network errors, timeouts, 5xx, 429, and any code
///     with no status — is `retryable`.
public enum ServerRejectionClassifier {
    public static func classify(code: String?, statusCode: Int) -> RejectionClass {
        let upperCode = code?.uppercased()
        // #675 F2: an RLS "permission denied" (SQLSTATE 42501 rides on the
        // 403) is an IDENTITY condition — the commonest cause is that the
        // request's session is not the account the payload assumes. The
        // payload is byte-for-byte fine and would upload the moment the
        // session is right. This branch is checked BEFORE the constraint
        // branch, exactly like the web's `classifyHandledFailure`
        // (monitoring.ts:477-492 checks 42501/403 before the 23xxx match):
        // a constraint code riding a 403 is still a permission denial, never
        // proof the payload is bad. Park, never quarantine.
        if statusCode == 403 {
            return .parked
        }
        // A constraint SQLSTATE (CHECK/NOT NULL/FK) is permanent content —
        // unless the 401 token problem is also present, in which case #273
        // wins (auth parks, never quarantines).
        if let upperCode, upperCode.hasPrefix("23") {
            return statusCode == 401 ? .auth : .permanent
        }
        switch statusCode {
        case 401:
            return .auth
        case 400:
            // #675 F4: the status PostgREST actually emits for a malformed
            // body (PGRST102), an unknown column (PGRST204 — a native build
            // ahead of its migration, the exact tolerance #675 exists for),
            // or a bad text representation (22P02). Retrying these forever
            // is the exact condition the issue was opened to stop.
            return .permanent
        case 404:
            // #675 F2: PGRST205 "table not found" during a schema-cache
            // reload is a transient window, classified "schema" on the web
            // and never quarantined there. Not proof the payload is bad.
            return .retryable
        case 406, 413, 415, 422:
            // 406/422 = malformed payload the server refuses; 406/413/415 =
            // this payload's shape is wrong for the endpoint. None of these
            // will heal on their own for THIS entry.
            return .permanent
        case 409:
            // Unique-violation race: the repository already converts 23505/409
            // into a fetch-and-return, so a surviving 409 is a genuine race
            // worth another attempt, not proof of a bad payload.
            return .retryable
        default:
            // Network errors, timeouts, 5xx, 429, transport failures (status
            // 0), and anything else without a server verdict.
            return .retryable
        }
    }
}

public struct DurableQueueItem<Payload: Codable & Sendable>: Codable, Sendable, Identifiable {
    public let id: UUID
    public let accountUserID: UUID
    public let createdAt: Date
    /// Changes whenever an existing queue identity is replaced. An upload
    /// that claimed the previous revision must not apply its failure/backoff
    /// to the replacement.
    public let revision: UUID
    /// Semantic ordering for coalesced editor writes. Generic queue users may
    /// leave this at zero; the recording editor supplies its monotonic RPE or
    /// creation ordering so an older re-entrant task cannot replace newer
    /// durable state merely because it resumed later.
    public let orderingKey: UInt64
    /// A recording's terminal-delete key. Editor writes carry the recording
    /// id here so the queue can atomically reject/remove every stale write
    /// for that recording, while a shared session-RPE item from another
    /// recording keeps its own key.
    public let terminalKey: UUID?
    public var updatedAt: Date
    public var attempts: Int
    /// #675 F3: how many times THIS entry has been rejected with a
    /// `permanent` classification — the only counter the quarantine bound
    /// reads. Network/5xx/429 retries (`attempts`) are exactly the offline
    /// case an offline queue exists for and must never spend the budget;
    /// the first `permanent` rejection after a long offline spell must get
    /// the full bounded window, not be quarantined on sight. Optional so
    /// pre-#675 queue files decode to `nil` (treated as 0).
    public var permanentAttempts: Int?
    public var nextAttemptAt: Date
    public var lastError: String?
    /// #675: non-nil once the entry has exhausted its bounded attempts on a
    /// `permanent` rejection. A quarantined entry is NEVER returned by
    /// `items(for:dueAt:)`, so the hot drain path cannot retry it; the only
    /// ways out are `retryQuarantined` (explicit user action, web #484's
    /// `retryStuckRecordings`) or `remove`/`discard` (user discard or the
    /// account-deletion path).
    public var quarantined: QueueRejection?
    public var payload: Payload

    /// How many times a `permanent` rejection may be retried before the entry
    /// is quarantined (#675). Small on purpose: the whole point of the
    /// quarantine is to stop burning battery/radio on a payload the server has
    /// already told us is bad. The web's tolerance for an app-version change
    /// (#484) has no native equivalent — a native app ships whole, so there is
    /// no "deploy ahead of its own migration" window to ride out here. Stored
    /// as a computed property because generic types cannot hold static stored
    /// properties in Swift.
    public static var maxPermanentAttempts: Int { 3 }

    public init(
        id: UUID = UUID(),
        accountUserID: UUID,
        createdAt: Date = Date(),
        revision: UUID = UUID(),
        orderingKey: UInt64 = 0,
        terminalKey: UUID? = nil,
        updatedAt: Date? = nil,
        attempts: Int = 0,
        permanentAttempts: Int = 0,
        nextAttemptAt: Date? = nil,
        lastError: String? = nil,
        quarantined: QueueRejection? = nil,
        payload: Payload
    ) {
        self.id = id
        self.accountUserID = accountUserID
        self.createdAt = createdAt
        self.revision = revision
        self.orderingKey = orderingKey
        self.terminalKey = terminalKey
        self.updatedAt = updatedAt ?? createdAt
        self.attempts = attempts
        self.permanentAttempts = permanentAttempts == 0 ? nil : permanentAttempts
        self.nextAttemptAt = nextAttemptAt ?? createdAt
        self.lastError = lastError
        self.quarantined = quarantined
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case id, accountUserID, createdAt, revision, orderingKey, terminalKey
        case updatedAt, attempts
        case permanentAttempts, nextAttemptAt, lastError, quarantined, payload
    }

    /// Queue files written before replacement revisions existed decode with a
    /// fresh revision. Their payload and backoff remain intact; only the claim
    /// token is new, which is exactly what a relaunch needs.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.accountUserID = try container.decode(UUID.self, forKey: .accountUserID)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.revision = try container.decodeIfPresent(UUID.self, forKey: .revision) ?? UUID()
        self.orderingKey = try container.decodeIfPresent(UInt64.self, forKey: .orderingKey) ?? 0
        self.terminalKey = try container.decodeIfPresent(UUID.self, forKey: .terminalKey)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.attempts = try container.decode(Int.self, forKey: .attempts)
        self.permanentAttempts = try container.decodeIfPresent(Int.self, forKey: .permanentAttempts)
        self.nextAttemptAt = try container.decode(Date.self, forKey: .nextAttemptAt)
        self.lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        self.quarantined = try container.decodeIfPresent(QueueRejection.self, forKey: .quarantined)
        self.payload = try container.decode(Payload.self, forKey: .payload)
    }

    /// Replace only the payload while preserving the durable backoff,
    /// quarantine diagnostics, and queue identity. A fresh revision prevents
    /// a request that claimed the pre-migration payload from mutating the
    /// normalized item.
    public func replacingPayload(_ payload: Payload) -> DurableQueueItem<Payload> {
        replacingPayload(payload, terminalKey: terminalKey)
    }

    /// Payload replacement used by migration when an old combined item is
    /// normalized into the recording-scoped terminal-delete lane.
    public func replacingPayload(
        _ payload: Payload,
        terminalKey: UUID?
    ) -> DurableQueueItem<Payload> {
        DurableQueueItem(
            id: id,
            accountUserID: accountUserID,
            createdAt: createdAt,
            revision: UUID(),
            orderingKey: orderingKey,
            terminalKey: terminalKey,
            updatedAt: updatedAt,
            attempts: attempts,
            permanentAttempts: permanentAttempts ?? 0,
            nextAttemptAt: nextAttemptAt,
            lastError: lastError,
            quarantined: quarantined,
            payload: payload
        )
    }
}

/// A conditional queue removal. It is used by migration/delete transactions
/// for legacy items that do not yet carry a terminal key.
public struct DurableQueueRemoval: Equatable, Sendable {
    public let id: UUID
    public let accountUserID: UUID
    public let expectedRevision: UUID

    public init(id: UUID, accountUserID: UUID, expectedRevision: UUID) {
        self.id = id
        self.accountUserID = accountUserID
        self.expectedRevision = expectedRevision
    }
}

/// A persisted terminal marker outlives the queue item itself. This closes
/// the crash window after a backend delete succeeds but before the process can
/// remove the durable delete intent: an old editor task cannot enqueue again,
/// and a relaunch can restore the recording tombstone from this marker.
public struct DurableQueueTerminal: Codable, Equatable, Hashable, Sendable {
    public let key: UUID
    public let accountUserID: UUID
    public let operationID: UUID

    public init(key: UUID, accountUserID: UUID, operationID: UUID) {
        self.key = key
        self.accountUserID = accountUserID
        self.operationID = operationID
    }
}

/// The last semantic claim for a queue identity, retained after the item is
/// uploaded and removed. Recording-editor migration uses this to ensure an
/// older legacy item cannot recreate an already-uploaded shared RPE item.
public struct DurableQueueOrderingWatermark: Codable, Equatable, Sendable {
    public let queueItemID: UUID
    public let accountUserID: UUID
    public let orderingKey: UInt64
    public let createdAt: Date
    public let revision: UUID

    public init(
        queueItemID: UUID,
        accountUserID: UUID,
        orderingKey: UInt64,
        createdAt: Date,
        revision: UUID
    ) {
        self.queueItemID = queueItemID
        self.accountUserID = accountUserID
        self.orderingKey = orderingKey
        self.createdAt = createdAt
        self.revision = revision
    }
}

public struct QueueBreadcrumb: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let queueItemID: UUID
    public let accountUserID: UUID
    public let leftQueueAt: Date
    public let attempts: Int
    public let reason: String

    public init(
        id: UUID = UUID(),
        queueItemID: UUID,
        accountUserID: UUID,
        leftQueueAt: Date = Date(),
        attempts: Int,
        reason: String
    ) {
        self.id = id
        self.queueItemID = queueItemID
        self.accountUserID = accountUserID
        self.leftQueueAt = leftQueueAt
        self.attempts = attempts
        self.reason = reason
    }
}

public enum DurableQueueError: Error, Equatable, Sendable {
    case accountMismatch
    case itemNotFound
    case invalidDirectory
    /// #675: a `markFailure` landed on an entry that is already quarantined.
    /// Kept for API compatibility; since #675 F6 the drain treats this as a
    /// no-op (a concurrent drain + manual retry can both snapshot the same
    /// due entry), so this case is no longer thrown in practice.
    case alreadyQuarantined
}

/// A small, atomically persisted, account-scoped queue for native optimistic
/// writes. Every removal and clear operation requires the owning user id; no
/// API accepts `nil`, so an unresolved session can never widen a deletion to
/// another account's data.
public actor DurableQueue<Payload: Codable & Sendable> {
    private struct Store: Codable, Sendable {
        var items: [DurableQueueItem<Payload>]
        var breadcrumbs: [QueueBreadcrumb]
        var terminalized: [DurableQueueTerminal]
        var orderingWatermarks: [DurableQueueOrderingWatermark]

        init(
            items: [DurableQueueItem<Payload>],
            breadcrumbs: [QueueBreadcrumb],
            terminalized: [DurableQueueTerminal] = [],
            orderingWatermarks: [DurableQueueOrderingWatermark] = []
        ) {
            self.items = items
            self.breadcrumbs = breadcrumbs
            self.terminalized = terminalized
            self.orderingWatermarks = orderingWatermarks
        }

        private enum CodingKeys: String, CodingKey {
            case items, breadcrumbs, terminalized, orderingWatermarks
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            items = try container.decode([DurableQueueItem<Payload>].self, forKey: .items)
            breadcrumbs = try container.decode([QueueBreadcrumb].self, forKey: .breadcrumbs)
            terminalized = try container.decodeIfPresent(
                [DurableQueueTerminal].self,
                forKey: .terminalized
            ) ?? []
            orderingWatermarks = try container.decodeIfPresent(
                [DurableQueueOrderingWatermark].self,
                forKey: .orderingWatermarks
            ) ?? []
        }
    }

    private let fileURL: URL
    private let breadcrumbLimit: Int
    private var store: Store
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        directoryURL: URL,
        filename: String,
        breadcrumbLimit: Int = 10
    ) throws {
        guard !filename.isEmpty else { throw DurableQueueError.invalidDirectory }
        self.breadcrumbLimit = max(1, breadcrumbLimit)
        self.fileURL = directoryURL.appendingPathComponent(filename, isDirectory: false)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            self.store = try decoder.decode(Store.self, from: data)
        } else {
            self.store = Store(items: [], breadcrumbs: [])
            let data = try encoder.encode(self.store)
            try data.write(to: fileURL, options: [.atomic])
        }
    }

    public func enqueue(_ item: DurableQueueItem<Payload>) throws {
        try enqueue([item])
    }

    /// Enqueue a group of related writes in one durable transaction. Recording
    /// metadata and its session-RPE ordering claim use this to avoid leaving
    /// only half of an editor save on disk when persistence fails.
    public func enqueue(_ items: [DurableQueueItem<Payload>]) throws {
        try transact { state in
            for item in items {
                if let terminalKey = item.terminalKey,
                   state.terminalized.contains(where: {
                       $0.key == terminalKey && $0.accountUserID == item.accountUserID
                   }) {
                    continue
                }
                if let index = state.items.firstIndex(where: { $0.id == item.id }) {
                    guard state.items[index].accountUserID == item.accountUserID else {
                        throw DurableQueueError.accountMismatch
                    }
                    if item.terminalKey != nil || item.orderingKey != 0 {
                        if Self.isNewer(item, than: state.items[index]) {
                            state.items[index] = item
                        }
                    } else {
                        state.items[index] = item
                    }
                } else {
                    if let watermark = state.orderingWatermarks.first(where: {
                        $0.queueItemID == item.id && $0.accountUserID == item.accountUserID
                    }), !Self.isNewer(item, than: watermark) {
                        continue
                    }
                    state.items.append(item)
                }
            }
        }
    }

    /// Replace one migration snapshot only while the queue still contains the
    /// revision that snapshot observed. `nil` means the item must still be
    /// absent. This makes a stale migration a no-op instead of an unconditional
    /// stable-ID overwrite.
    @discardableResult
    public func enqueueIfCurrent(
        _ item: DurableQueueItem<Payload>,
        expectedRevision: UUID?
    ) throws -> Bool {
        var applied = false
        try transact { state in
            if let terminalKey = item.terminalKey,
               state.terminalized.contains(where: {
                   $0.key == terminalKey && $0.accountUserID == item.accountUserID
               }) {
                return
            }
            guard let index = state.items.firstIndex(where: { $0.id == item.id }) else {
                guard expectedRevision == nil else { return }
                if let watermark = state.orderingWatermarks.first(where: {
                    $0.queueItemID == item.id && $0.accountUserID == item.accountUserID
                }), !Self.isNewer(item, than: watermark) {
                    return
                }
                state.items.append(item)
                applied = true
                return
            }
            guard state.items[index].accountUserID == item.accountUserID,
                  state.items[index].revision == expectedRevision else { return }
            state.items[index] = item
            applied = true
        }
        return applied
    }

    /// Coalesce recording-editor writes only while their recording has not
    /// reached a durable terminal delete. Existing newer semantic ordering is
    /// retained; returning `true` means at least one item from the batch was
    /// durably accepted, while `false` means the terminal marker won or a
    /// newer/watermarked claim already superseded the batch.
    @discardableResult
    public func enqueueUnlessTerminalizedKeepingNewest(
        _ items: [DurableQueueItem<Payload>],
        terminalKey: UUID,
        accountUserID: UUID
    ) throws -> Bool {
        guard !items.isEmpty,
              items.allSatisfy({
                  $0.accountUserID == accountUserID && $0.terminalKey == terminalKey
              }) else {
            throw DurableQueueError.accountMismatch
        }
        var accepted = false
        try transact { state in
            guard !state.terminalized.contains(where: {
                $0.key == terminalKey && $0.accountUserID == accountUserID
            }) else { return }
            var changed = false
            for item in items {
                if let index = state.items.firstIndex(where: { $0.id == item.id }) {
                    guard state.items[index].accountUserID == accountUserID else {
                        throw DurableQueueError.accountMismatch
                    }
                    if Self.isNewer(item, than: state.items[index]) {
                        state.items[index] = item
                        changed = true
                    }
                } else {
                    if let watermark = state.orderingWatermarks.first(where: {
                        $0.queueItemID == item.id && $0.accountUserID == accountUserID
                    }), !Self.isNewer(item, than: watermark) {
                        continue
                    }
                    state.items.append(item)
                    changed = true
                }
            }
            accepted = changed
        }
        return accepted
    }

    /// Atomically removes all editor writes for a recording (including stale
    /// legacy items supplied as conditional removals) and installs its durable
    /// delete intent. If persistence fails, neither side of the transaction is
    /// published and the caller must not touch the backend.
    @discardableResult
    public func enqueueTerminalDelete(
        _ deleteItem: DurableQueueItem<Payload>,
        terminalKey: UUID,
        canceling removals: [DurableQueueRemoval] = []
    ) throws -> Bool {
        guard deleteItem.terminalKey == terminalKey else {
            throw DurableQueueError.accountMismatch
        }
        guard removals.allSatisfy({ $0.accountUserID == deleteItem.accountUserID }) else {
            throw DurableQueueError.accountMismatch
        }
        var installed = false
        try transact { state in
            guard !state.terminalized.contains(where: {
                $0.key == terminalKey && $0.accountUserID == deleteItem.accountUserID
            }) else { return }
            if let existingDelete = state.items.first(where: { $0.id == deleteItem.id }) {
                guard existingDelete.accountUserID == deleteItem.accountUserID else {
                    throw DurableQueueError.accountMismatch
                }
                return
            }
            var conditional: [UUID: UUID] = [:]
            for removal in removals {
                conditional[removal.id] = removal.expectedRevision
            }
            let indexes = state.items.indices.filter { index in
                let item = state.items[index]
                guard item.accountUserID == deleteItem.accountUserID,
                      item.id != deleteItem.id else { return false }
                if item.terminalKey == terminalKey { return true }
                return conditional[item.id] == item.revision
            }
            for index in indexes.reversed() {
                let item = state.items.remove(at: index)
                recordOrderingWatermark(for: item, in: &state)
                appendBreadcrumb(
                    QueueBreadcrumb(
                        queueItemID: item.id,
                        accountUserID: item.accountUserID,
                        leftQueueAt: Date(),
                        attempts: item.attempts,
                        reason: "recording-deleted"
                    ),
                    to: &state
                )
            }
            state.items.append(deleteItem)
            installed = true
        }
        return installed
    }

    /// Complete a backend recording delete and persist its terminal marker in
    /// one transaction. The delete item must still be the claimed revision;
    /// otherwise an intervening replacement remains durable for a later retry.
    @discardableResult
    public func completeTerminalDelete(
        id: UUID,
        accountUserID: UUID,
        expectedRevision: UUID,
        terminalKey: UUID,
        operationID: UUID,
        reason: String = "recording-deleted"
    ) throws -> Bool {
        var completed = false
        try transact { state in
            guard !state.terminalized.contains(where: {
                $0.key == terminalKey && $0.accountUserID == accountUserID
            }),
            state.items.contains(where: {
                $0.id == id
                    && $0.accountUserID == accountUserID
                    && $0.revision == expectedRevision
            }) else { return }
            let indexes = state.items.indices.filter { index in
                let item = state.items[index]
                return item.accountUserID == accountUserID
                    && (item.id == id || item.terminalKey == terminalKey)
            }
            for index in indexes.reversed() {
                let item = state.items.remove(at: index)
                recordOrderingWatermark(for: item, in: &state)
                appendBreadcrumb(
                    QueueBreadcrumb(
                        queueItemID: item.id,
                        accountUserID: item.accountUserID,
                        leftQueueAt: Date(),
                        attempts: item.attempts,
                        reason: reason
                    ),
                    to: &state
                )
            }
            state.terminalized.append(
                DurableQueueTerminal(
                    key: terminalKey,
                    accountUserID: accountUserID,
                    operationID: operationID
                )
            )
            completed = true
        }
        return completed
    }

    public func terminalizedToken(
        for key: UUID,
        accountUserID: UUID
    ) -> UUID? {
        store.terminalized.first {
            $0.key == key && $0.accountUserID == accountUserID
        }?.operationID
    }

    public func terminalizedKeys(for accountUserID: UUID) -> Set<UUID> {
        Set(store.terminalized.filter { $0.accountUserID == accountUserID }.map(\.key))
    }

    /// Cancel an uncompleted delete intent only if the restore operation still
    /// owns the revision it observed before its network await.
    @discardableResult
    public func cancelPendingTerminalDelete(
        id: UUID,
        accountUserID: UUID,
        expectedRevision: UUID,
        terminalKey: UUID
    ) throws -> Bool {
        var canceled = false
        try transact { state in
            guard let index = state.items.firstIndex(where: {
                $0.id == id
                    && $0.accountUserID == accountUserID
                    && $0.revision == expectedRevision
                    && $0.terminalKey == terminalKey
            }) else { return }
            let item = state.items.remove(at: index)
            recordOrderingWatermark(for: item, in: &state)
            appendBreadcrumb(
                QueueBreadcrumb(
                    queueItemID: item.id,
                    accountUserID: item.accountUserID,
                    leftQueueAt: Date(),
                    attempts: item.attempts,
                    reason: "recording-restored"
                ),
                to: &state
            )
            canceled = true
        }
        return canceled
    }

    @discardableResult
    public func clearTerminalized(
        key: UUID,
        accountUserID: UUID,
        expectedOperationID: UUID?
    ) throws -> Bool {
        let current = store.terminalized.first {
            $0.key == key && $0.accountUserID == accountUserID
        }
        guard current?.operationID == expectedOperationID else {
            return current == nil && expectedOperationID == nil
        }
        guard current != nil else { return true }
        try transact { state in
            state.terminalized.removeAll {
                $0.key == key && $0.accountUserID == accountUserID
            }
        }
        return true
    }

    /// The entries the hot drain path may attempt: never quarantined, and
    /// only backoff-due when `dueAt` is given. #675: a quarantined entry is
    /// excluded here unconditionally (even with no `dueAt`) — it has NO next
    /// attempt until an explicit `retryQuarantined`, so "drain everything"
    /// (sign-out, warm retries) must not accidentally retry it either.
    public func items(
        for accountUserID: UUID,
        dueAt date: Date? = nil
    ) -> [DurableQueueItem<Payload>] {
        items(for: accountUserID, dueAt: date, includeQuarantined: false)
    }

    /// #675 F1: the entry the app must VISUALLY restore after a relaunch —
    /// `restorePendingWrites` reads this (it rebuilds the optimistic
    /// placeholders from the durable queue, and a quarantined entry is data
    /// the user still owns). The hot drain path stays on the strict
    /// `items(for:dueAt:)` above; this is for visibility, never for retry.
    public func items(
        for accountUserID: UUID,
        dueAt date: Date? = nil,
        includeQuarantined: Bool
    ) -> [DurableQueueItem<Payload>] {
        store.items
            .filter { $0.accountUserID == accountUserID && (includeQuarantined || $0.quarantined == nil) }
            .filter { item in
                guard let date else { return true }
                return item.nextAttemptAt <= date
            }
            .sorted { lhs, rhs in
                if lhs.nextAttemptAt != rhs.nextAttemptAt {
                    return lhs.nextAttemptAt < rhs.nextAttemptAt
                }
                return lhs.createdAt < rhs.createdAt
            }
    }

    /// The entries the hot drain path may attempt OR the count of a drain's
    /// active backlog — quarantined items are deliberately NOT counted here.
    /// #675: `count` is what the ambient "waiting to upload" surfaces and the
    /// sign-out remainder prompt read; a quarantined item is not "waiting to
    /// upload" (it has stopped being attempted), so counting it as queued
    /// would lie twice — once in the banner, once in the #273 prompt.
    public func count(for accountUserID: UUID) -> Int {
        store.items.lazy.filter {
            $0.accountUserID == accountUserID && $0.quarantined == nil
        }.count
    }

    public func item(id: UUID, accountUserID: UUID) -> DurableQueueItem<Payload>? {
        store.items.first { $0.id == id && $0.accountUserID == accountUserID }
    }

    /// Return the last semantic claim retained for an identity after its
    /// queue item was removed. This is primarily useful to test/reconcile
    /// editor migrations; callers should use the conditional enqueue methods
    /// to enforce it transactionally.
    public func orderingWatermark(
        for queueItemID: UUID,
        accountUserID: UUID
    ) -> DurableQueueOrderingWatermark? {
        store.orderingWatermarks.first {
            $0.queueItemID == queueItemID && $0.accountUserID == accountUserID
        }
    }

    /// Re-reads one item through the hot-drain filter. Callers that captured a
    /// queue item before an await must use this instead of `item` before they
    /// upload: a stale snapshot may have been quarantined or put on backoff in
    /// the meantime.
    public func activeItem(
        id: UUID,
        accountUserID: UUID,
        dueAt date: Date? = nil
    ) -> DurableQueueItem<Payload>? {
        items(for: accountUserID, dueAt: date).first { $0.id == id }
    }

    /// #675: the quarantined entries for an account, newest rejection first.
    /// A quarantine is its own honest state — never folded into the active
    /// count, never hidden (the #475 F1 mistake: a count with zero readers).
    public func quarantinedItems(for accountUserID: UUID) -> [DurableQueueItem<Payload>] {
        store.items
            .filter { $0.accountUserID == accountUserID && $0.quarantined != nil }
            .sorted {
                ($0.quarantined?.at ?? $0.updatedAt) > ($1.quarantined?.at ?? $1.updatedAt)
            }
    }

    public func quarantinedCount(for accountUserID: UUID) -> Int {
        store.items.lazy.filter {
            $0.accountUserID == accountUserID && $0.quarantined != nil
        }.count
    }

    @discardableResult
    public func markFailure(
        id: UUID,
        accountUserID: UUID,
        error: String,
        classification: RejectionClass,
        code: String? = nil,
        now: Date = Date(),
        countsTowardQuarantine: Bool = true,
        expectedRevision: UUID? = nil
    ) throws -> Bool {
        guard let currentIndex = store.items.firstIndex(where: { $0.id == id }) else {
            throw DurableQueueError.itemNotFound
        }
        guard store.items[currentIndex].accountUserID == accountUserID else {
            throw DurableQueueError.accountMismatch
        }
        guard expectedRevision == nil || store.items[currentIndex].revision == expectedRevision else {
            return false
        }
        // A quarantined entry has no failure path left — nothing should be
        // calling markFailure on it (the drain never returns it). #675 F6: a
        // concurrent drain and manual retry can BOTH snapshot the same due
        // entry before the first markFailure quarantines it, so this is
        // reachable in production, not just a caller bug. Preserve the
        // existing no-op contract for that terminal state.
        guard store.items[currentIndex].quarantined == nil else { return false }

        var applied = false
        try transact { state in
            guard let index = state.items.firstIndex(where: { $0.id == id }) else {
                throw DurableQueueError.itemNotFound
            }
            guard state.items[index].accountUserID == accountUserID else {
                throw DurableQueueError.accountMismatch
            }
            guard expectedRevision == nil || state.items[index].revision == expectedRevision else {
                return
            }
            var item = state.items[index]
            item.attempts += 1
            item.updatedAt = now
            item.lastError = String(error.prefix(500))

            // #675 F2: auth-shaped failures (`.auth` — revoked/expired token —
            // and `.parked` — an RLS/permission denial) PARK, they never
            // quarantine (#273: an identity condition is an environment problem,
            // not proof the payload is bad — destroying training data over one is
            // the exact regression the web's forced-sign-out rule exists to
            // prevent). They are retried with normal backoff like any transient
            // failure; the session recovery is the app's job, not the queue's.
            switch classification {
            case .permanent:
                // #675 F3: the quarantine bound reads the PERMANENT-specific
                // counter, so a spell of network/5xx/429 retries (`attempts`)
                // can never spend the budget. The first permanent rejection after
                // a long offline stretch gets the full bounded window.
                //
                // #675 F5: a manual retry (explicit user action) may OPT OUT of
                // counting toward the quarantine bound — the user's own
                // remediation attempt must never be what quarantines the entry.
                if countsTowardQuarantine {
                    item.permanentAttempts = (item.permanentAttempts ?? 0) + 1
                }
                if (item.permanentAttempts ?? 0) >= DurableQueueItem<Payload>.maxPermanentAttempts {
                    item.quarantined = QueueRejection(
                        kind: .permanent,
                        at: now,
                        code: code,
                        detail: error
                    )
                }
            case .auth, .parked, .retryable:
                break
            }
            item.nextAttemptAt = now.addingTimeInterval(
                Self.retryDelay(attempts: item.attempts)
            )
            state.items[index] = item
            applied = true
        }
        return applied
    }

    /// #675 F7 + N1: re-apply the quarantine stamp after a failed MANUAL
    /// retry. `retryQuarantined` cleared the stamp and reset the attempt
    /// budget; if that single explicit upload then failed, the entry must go
    /// straight back to its quarantined, never-auto-retried state — NOT sit
    /// active on the hot drain path re-arming free automatic attempts behind
    /// the user's back (Settings tells the user it is "never retried on their
    /// own"). No attempt counting: the budget stays reset so the next MANUAL
    /// retry starts a clean window. Returns `false` when the id is not
    /// currently active (already quarantined again, or already uploaded).
    ///
    /// #675 N1: the diagnostic survives. A transient/auth/parked failure on
    /// the manual retry says NOTHING new about the payload — the entry was
    /// quarantined for a server rejection that still stands — so `previous`
    /// (the stamp `retryQuarantined` cleared) is restored VERBATIM, keeping
    /// its code, detail and original `at`. Only a FRESH `.permanent`
    /// rejection on the retry replaces the stamp with the new code/detail.
    @discardableResult
    public func requarantine(
        id: UUID,
        accountUserID: UUID,
        previous: QueueRejection?,
        classification: RejectionClass,
        code: String? = nil,
        detail: String,
        now: Date = Date()
    ) throws -> Bool {
        guard let index = store.items.firstIndex(where: { $0.id == id }) else {
            throw DurableQueueError.itemNotFound
        }
        guard store.items[index].accountUserID == accountUserID else {
            throw DurableQueueError.accountMismatch
        }
        guard store.items[index].quarantined == nil else { return false }
        let stamp: QueueRejection
        if classification == .permanent {
            // A FRESH permanent rejection on the retry — the new diagnostic
            // is the accurate one.
            stamp = QueueRejection(
                kind: .permanent,
                at: now,
                code: code,
                detail: detail
            )
        } else if let previous {
            // Transient/auth/parked failure — restore the prior stamp
            // verbatim (kind, code, detail AND `at`), so the Settings
            // diagnostic survives and "rejected N days ago" stays true.
            stamp = previous
        } else {
            // No prior stamp to restore (defensive — requarantine is only for
            // a retried-quarantined entry) — fall back to a permanent stamp.
            stamp = QueueRejection(
                kind: .permanent,
                at: now,
                code: code,
                detail: detail
            )
        }
        try transact { state in
            state.items[index].quarantined = stamp
            state.items[index].updatedAt = now
        }
        return true
    }

    /// #675: the explicit-user-action way back from quarantine — the native
    /// mirror of the web's `retryStuckRecordings` (#484). Clears the rejection
    /// stamp and resets BOTH attempt counters, so the next drain treats it as
    /// a fresh entry with a fresh bounded-attempt budget (if it was rejected
    /// again under the current build, that starts a new window rather than
    /// re-tripping on an old attempt count). Returns the `QueueRejection` it
    /// cleared — the caller keeps it to restore verbatim through a failed
    /// manual retry (#675 N1) — or `nil` when the id is not quarantined.
    @discardableResult
    public func retryQuarantined(
        id: UUID,
        accountUserID: UUID,
        now: Date = Date()
    ) throws -> QueueRejection? {
        guard let index = store.items.firstIndex(where: { $0.id == id }) else {
            throw DurableQueueError.itemNotFound
        }
        guard store.items[index].accountUserID == accountUserID else {
            throw DurableQueueError.accountMismatch
        }
        guard let cleared = store.items[index].quarantined else { return nil }
        try transact { state in
            state.items[index].quarantined = nil
            state.items[index].attempts = 0
            state.items[index].permanentAttempts = nil
            state.items[index].updatedAt = now
            state.items[index].nextAttemptAt = now
        }
        return cleared
    }

    /// #675: discard ONE quarantined entry — the per-item sibling of
    /// `remove` for the Settings surface (retry/discard). Quarantined only,
    /// so a stray call cannot delete an active entry; account-scoped like
    /// every other removal. Returns `false` when the id is not quarantined.
    @discardableResult
    public func discardQuarantined(
        id: UUID,
        accountUserID: UUID,
        reason: String = "quarantine-discarded",
        now: Date = Date()
    ) throws -> Bool {
        guard let index = store.items.firstIndex(where: { $0.id == id }) else {
            throw DurableQueueError.itemNotFound
        }
        guard store.items[index].accountUserID == accountUserID else {
            throw DurableQueueError.accountMismatch
        }
        guard store.items[index].quarantined != nil else { return false }
        let item = store.items[index]
        try transact { state in
            state.items.remove(at: index)
            recordOrderingWatermark(for: item, in: &state)
            appendBreadcrumb(
                QueueBreadcrumb(
                    queueItemID: item.id,
                    accountUserID: item.accountUserID,
                    leftQueueAt: now,
                    attempts: item.attempts,
                    reason: reason
                ),
                to: &state
            )
        }
        return true
    }

    public func remove(
        id: UUID,
        accountUserID: UUID,
        reason: String = "uploaded",
        now: Date = Date()
    ) throws {
        guard let index = store.items.firstIndex(where: { $0.id == id }) else {
            throw DurableQueueError.itemNotFound
        }
        let item = store.items[index]
        guard item.accountUserID == accountUserID else {
            throw DurableQueueError.accountMismatch
        }
        try transact { state in
            state.items.remove(at: index)
            recordOrderingWatermark(for: item, in: &state)
            appendBreadcrumb(
                QueueBreadcrumb(
                    queueItemID: item.id,
                    accountUserID: item.accountUserID,
                    leftQueueAt: now,
                    attempts: item.attempts,
                    reason: reason
                ),
                to: &state
            )
        }
    }

    public func discardAll(
        accountUserID: UUID,
        reason: String = "account-cleared",
        now: Date = Date()
    ) throws {
        let removed = store.items.filter { $0.accountUserID == accountUserID }
        try transact { state in
            state.items.removeAll { $0.accountUserID == accountUserID }
            for item in removed {
                recordOrderingWatermark(for: item, in: &state)
                appendBreadcrumb(
                    QueueBreadcrumb(
                        queueItemID: item.id,
                        accountUserID: item.accountUserID,
                        leftQueueAt: now,
                        attempts: item.attempts,
                        reason: reason
                    ),
                    to: &state
                )
            }
        }
    }

    public func breadcrumbs(for accountUserID: UUID) -> [QueueBreadcrumb] {
        store.breadcrumbs
            .filter { $0.accountUserID == accountUserID }
            .sorted { $0.leftQueueAt > $1.leftQueueAt }
    }

    public static func retryDelay(attempts: Int) -> TimeInterval {
        let boundedAttempt = min(max(1, attempts), 10)
        return min(15 * 60, pow(2, Double(boundedAttempt - 1)) * 5)
    }

    /// Compare durable editor claims independently of queue enumeration or
    /// retry backoff. A migration/relaunch may observe an older claim after a
    /// newer replacement has already been persisted; the newer semantic
    /// ordering must win in that case.
    private static func isNewer(
        _ lhs: DurableQueueItem<Payload>,
        than rhs: DurableQueueItem<Payload>
    ) -> Bool {
        if lhs.orderingKey != rhs.orderingKey {
            return lhs.orderingKey > rhs.orderingKey
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.revision.uuidString > rhs.revision.uuidString
    }

    private static func isNewer(
        _ lhs: DurableQueueItem<Payload>,
        than rhs: DurableQueueOrderingWatermark
    ) -> Bool {
        if lhs.orderingKey != rhs.orderingKey {
            return lhs.orderingKey > rhs.orderingKey
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.revision.uuidString > rhs.revision.uuidString
    }

    private func recordOrderingWatermark(
        for item: DurableQueueItem<Payload>,
        in state: inout Store
    ) {
        let watermark = DurableQueueOrderingWatermark(
            queueItemID: item.id,
            accountUserID: item.accountUserID,
            orderingKey: item.orderingKey,
            createdAt: item.createdAt,
            revision: item.revision
        )
        if let index = state.orderingWatermarks.firstIndex(where: {
            $0.queueItemID == item.id && $0.accountUserID == item.accountUserID
        }) {
            if Self.isNewer(item, than: state.orderingWatermarks[index]) {
                state.orderingWatermarks[index] = watermark
            }
        } else {
            state.orderingWatermarks.append(watermark)
        }
    }

    private func appendBreadcrumb(_ breadcrumb: QueueBreadcrumb, to state: inout Store) {
        state.breadcrumbs.append(breadcrumb)
        if state.breadcrumbs.count > breadcrumbLimit {
            state.breadcrumbs.removeFirst(state.breadcrumbs.count - breadcrumbLimit)
        }
    }

    /// Builds a candidate store and publishes it only after its atomic write
    /// succeeds. Queue callers can therefore never observe a memory-only
    /// mutation when persistence fails; the in-memory state remains exactly
    /// the last durable state and can be retried safely.
    private func transact(_ mutation: (inout Store) throws -> Void) throws {
        var candidate = store
        try mutation(&candidate)
        try persist(candidate)
        store = candidate
    }

    private func persist(_ state: Store) throws {
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: [.atomic])
    }
}
