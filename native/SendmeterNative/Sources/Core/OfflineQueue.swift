import Foundation

public struct DurableQueueItem<Payload: Codable & Sendable>: Codable, Sendable, Identifiable {
    public let id: UUID
    public let accountUserID: UUID
    public let createdAt: Date
    public var updatedAt: Date
    public var attempts: Int
    public var nextAttemptAt: Date
    public var lastError: String?
    public var payload: Payload

    public init(
        id: UUID = UUID(),
        accountUserID: UUID,
        createdAt: Date = Date(),
        attempts: Int = 0,
        nextAttemptAt: Date? = nil,
        lastError: String? = nil,
        payload: Payload
    ) {
        self.id = id
        self.accountUserID = accountUserID
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt ?? createdAt
        self.lastError = lastError
        self.payload = payload
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
}

/// A small, atomically persisted, account-scoped queue for native optimistic
/// writes. Every removal and clear operation requires the owning user id; no
/// API accepts `nil`, so an unresolved session can never widen a deletion to
/// another account's data.
public actor DurableQueue<Payload: Codable & Sendable> {
    private struct Store: Codable, Sendable {
        var items: [DurableQueueItem<Payload>]
        var breadcrumbs: [QueueBreadcrumb]
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
        if let index = store.items.firstIndex(where: { $0.id == item.id }) {
            guard store.items[index].accountUserID == item.accountUserID else {
                throw DurableQueueError.accountMismatch
            }
            store.items[index] = item
        } else {
            store.items.append(item)
        }
        try persist()
    }

    public func items(
        for accountUserID: UUID,
        dueAt date: Date? = nil
    ) -> [DurableQueueItem<Payload>] {
        store.items
            .filter { $0.accountUserID == accountUserID }
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

    public func count(for accountUserID: UUID) -> Int {
        store.items.lazy.filter { $0.accountUserID == accountUserID }.count
    }

    public func item(id: UUID, accountUserID: UUID) -> DurableQueueItem<Payload>? {
        store.items.first { $0.id == id && $0.accountUserID == accountUserID }
    }

    public func markFailure(
        id: UUID,
        accountUserID: UUID,
        error: String,
        now: Date = Date()
    ) throws {
        guard let index = store.items.firstIndex(where: { $0.id == id }) else {
            throw DurableQueueError.itemNotFound
        }
        guard store.items[index].accountUserID == accountUserID else {
            throw DurableQueueError.accountMismatch
        }
        store.items[index].attempts += 1
        store.items[index].updatedAt = now
        store.items[index].lastError = String(error.prefix(500))
        store.items[index].nextAttemptAt = now.addingTimeInterval(
            Self.retryDelay(attempts: store.items[index].attempts)
        )
        try persist()
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
        store.items.remove(at: index)
        appendBreadcrumb(
            QueueBreadcrumb(
                queueItemID: item.id,
                accountUserID: item.accountUserID,
                leftQueueAt: now,
                attempts: item.attempts,
                reason: reason
            )
        )
        try persist()
    }

    public func discardAll(
        accountUserID: UUID,
        reason: String = "account-cleared",
        now: Date = Date()
    ) throws {
        let removed = store.items.filter { $0.accountUserID == accountUserID }
        store.items.removeAll { $0.accountUserID == accountUserID }
        for item in removed {
            appendBreadcrumb(
                QueueBreadcrumb(
                    queueItemID: item.id,
                    accountUserID: item.accountUserID,
                    leftQueueAt: now,
                    attempts: item.attempts,
                    reason: reason
                )
            )
        }
        try persist()
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

    private func appendBreadcrumb(_ breadcrumb: QueueBreadcrumb) {
        store.breadcrumbs.append(breadcrumb)
        if store.breadcrumbs.count > breadcrumbLimit {
            store.breadcrumbs.removeFirst(store.breadcrumbs.count - breadcrumbLimit)
        }
    }

    private func persist() throws {
        let data = try encoder.encode(store)
        try data.write(to: fileURL, options: [.atomic])
    }
}
