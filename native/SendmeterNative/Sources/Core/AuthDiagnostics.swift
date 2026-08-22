import Foundation

// MARK: - Issue #679 — on-device auth event ring buffer

/// One captured auth event. The four categories are the boundaries the issue
/// names: sign-in, session refresh, sign-out, and auth failure (with a reason).
/// `detail` is a short human-readable reason; it is trimmed at write time (see
/// ``AuthDiagnosticsStore/record(_:)``) so an entry stays tiny.
public struct AuthEventEntry: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Unique per entry, so SwiftUI `ForEach` identity never collides when two
    /// events land in the same second with the same category/detail.
    public let id: UUID
    public let category: AuthEventCategory
    public let detail: String?
    public let occurredAt: Date

    public init(category: AuthEventCategory, detail: String?, occurredAt: Date) {
        self.id = UUID()
        self.category = category
        self.detail = detail
        self.occurredAt = occurredAt
    }
}

/// The four auth-event categories the ring covers.
public enum AuthEventCategory: String, Codable, CaseIterable, Sendable {
    case signIn
    case refresh
    case signOut
    case failure
}

/// Pure display helpers for the auth-diagnostics surface — mirrors the
/// quarantine diagnostics' ``QuarantineDiagnostics/truncatedErrorMessage`` so
/// a long failure reason stays readable on a small Settings row.
public enum AuthDiagnostics {
    public static let detailDisplayLimit = 160

    public static func truncatedDetail(
        _ detail: String,
        limit: Int = detailDisplayLimit
    ) -> String {
        guard detail.count > limit else { return detail }
        return String(detail.prefix(max(limit - 1, 0))) + "…"
    }
}

/// The bounded, best-effort-persisted ring of auth events (#679). Mirrors the
/// quarantine-exit breadcrumb store (`QuarantineBreadcrumbStore`) — a small
/// JSON file holding the last `capacity` entries, oldest first, surfaced in
/// Settings → troubleshooting.
///
/// Retention policy, deliberately:
/// - **Never uploaded.** Same on-device-only posture as the `auth-events` ring
///   already referenced by the quarantine breadcrumb doc. Nothing here is a
///   queued item, so the "only sign-out deletes queued data" rule does not
///   apply, and sign-out must NOT clear it (it is diagnostics).
/// - **Bounded.** Holds `capacity` entries and evicts the oldest beyond that —
///   the same "must not become a second unbounded store" instinct as #481.
/// - **Best-effort persistence.** A refused write keeps the entry in memory for
///   the session and is otherwise silent, losing no user data.
/// - **Unreadable file = empty ring.** A corrupt copy is treated as no history
///   and overwritten by the next write; it is a diagnostics sidecar, not a
///   queued item.
///
/// Thread-safe (lock-guarded): the MainActor auth path records while the
/// SwiftUI diagnostics view reads, and the store is `@unchecked Sendable` so it
/// can be read off-actor without a data race.
public final class AuthDiagnosticsStore: @unchecked Sendable {
    /// How many auth events the ring holds before the oldest is evicted.
    public static let capacity = 20

    private let lock = NSLock()
    private let fileURL: URL?
    private var events: [AuthEventEntry] = [] // oldest first

    /// - Parameter fileURL: where the ring is persisted. `nil` keeps the ring
    ///   in memory only (used by tests and by callers that have nowhere to
    ///   write).
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL {
            events = Self.load(from: fileURL)
        }
    }

    /// Appends one event, evicts the oldest beyond `capacity`, and persists
    /// best-effort. The `detail` field is trimmed at write time.
    public func record(_ entry: AuthEventEntry) {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = AuthEventEntry(
            category: entry.category,
            detail: entry.detail.map { AuthDiagnostics.truncatedDetail($0) },
            occurredAt: entry.occurredAt
        )
        events.append(trimmed)
        if events.count > Self.capacity {
            events.removeFirst(events.count - Self.capacity)
        }
        if let fileURL {
            Self.save(events, to: fileURL)
        }
    }

    /// The ring, oldest first. A copy, safe to read from any actor.
    public func history() -> [AuthEventEntry] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    private static func load(from url: URL) -> [AuthEventEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([AuthEventEntry].self, from: data)) ?? []
    }

    private static func save(_ events: [AuthEventEntry], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(events) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
