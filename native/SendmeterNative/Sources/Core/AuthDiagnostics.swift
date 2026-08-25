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

    /// #757: categories a normal user can act on or needs to know about.
    /// Refresh and sign-out transitions are routine internal activity and stay
    /// in the full diagnostics ring behind the technical-details gate.
    public var isUserFacingSummary: Bool {
        switch self {
        case .signIn, .failure: return true
        case .refresh, .signOut: return false
        }
    }
}

/// #757: the compact user-facing view of the auth ring. Only the most recent
/// meaningful activity is surfaced in Settings; the full bounded ring remains
/// readable behind the technical-details gate.
public struct AuthEventSummary: Equatable, Sendable {
    public let lastSignIn: AuthEventEntry?
    public let lastFailure: AuthEventEntry?

    public init(lastSignIn: AuthEventEntry?, lastFailure: AuthEventEntry?) {
        self.lastSignIn = lastSignIn
        self.lastFailure = lastFailure
    }
}

/// Pure display helpers for the auth-diagnostics surface — mirrors the
/// quarantine diagnostics' ``QuarantineDiagnostics/truncatedErrorMessage`` so
/// a long failure reason stays readable on a small Settings row.
public enum AuthDiagnostics {
    public static let detailDisplayLimit = 160

    /// The most recent user-facing events from an auth ring. The ring is stored
    /// oldest-first, but the selection is timestamp-based so an out-of-order
    /// copy still reports the actual latest event.
    public static func summary(of history: [AuthEventEntry]) -> AuthEventSummary {
        let visible = history.filter { $0.category.isUserFacingSummary }
        return AuthEventSummary(
            lastSignIn: visible
                .filter { $0.category == .signIn }
                .max { $0.occurredAt < $1.occurredAt },
            lastFailure: visible
                .filter { $0.category == .failure }
                .max { $0.occurredAt < $1.occurredAt }
        )
    }

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
/// - **Gated presentation.** The full ring is readable behind Settings' explicit
///   technical-details gate; the normal path shows only a compact summary (#757).
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
