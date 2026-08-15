import Foundation

// MARK: - Issue #606 — quarantine-exit breadcrumbs

/// One header-only breadcrumb kept when a quarantined upload leaves
/// quarantine (the manual retry #600 or the automatic F12 resurrection).
/// It is the `QueueQuarantineRecord` header the restore would otherwise
/// destroy — `stage`, `httpStatus`, `postgrestCode`, `errorMessage`,
/// `attemptCount`, `quarantinedAt` — plus when it exited, so a RESOLVED
/// incident stays diagnosable afterwards (#605's root cause was lost
/// exactly this way: the user retried, the upload landed, and the one
/// artifact that said why it failed was gone with it).
///
/// Deliberately never carries the item payload — the breadcrumb must stay
/// tiny. `errorMessage` is the one header field that can be long, so
/// `QuarantineBreadcrumbStore.record` trims it at write time.
public struct QuarantineBreadcrumbEntry: Codable, Equatable, Sendable {
    /// The item's `queueFileId` — names the item without any payload.
    public let id: UUID
    public let reason: QuarantineReason
    public let stage: UploadStage?
    public let httpStatus: Int?
    public let postgrestCode: String?
    /// Truncated at write time (see the store's `record`).
    public let errorMessage: String?
    public let attemptCount: Int?
    public let quarantinedAt: Date
    public let exitedAt: Date

    public init(
        id: UUID,
        reason: QuarantineReason,
        stage: UploadStage?,
        httpStatus: Int?,
        postgrestCode: String?,
        errorMessage: String?,
        attemptCount: Int?,
        quarantinedAt: Date,
        exitedAt: Date
    ) {
        self.id = id
        self.reason = reason
        self.stage = stage
        self.httpStatus = httpStatus
        self.postgrestCode = postgrestCode
        self.errorMessage = errorMessage
        self.attemptCount = attemptCount
        self.quarantinedAt = quarantinedAt
        self.exitedAt = exitedAt
    }
}

/// The bounded, durable ring of quarantine exits (#606) — a small JSON
/// file holding the last `capacity` entries, oldest first. One per queue,
/// written by `UploadQueueEngine` on BOTH exit paths; the diagnostics
/// surface reads it back as "recent history" (#599).
///
/// Retention policy, decided deliberately:
/// - **Survives a successful upload.** The breadcrumb exists to explain a
///   failure that has since cleared — clearing it on success defeats the
///   entire purpose (#606 ask 5). There is no clear-on-success, and no
///   clear at all: nothing here is a queued item, so the CLAUDE.md #273
///   "only sign-out deletes queued data" rule does not apply, and sign-out
///   must NOT clear it either (the ask's note; it is diagnostics, same
///   on-device-only posture as the `auth-events` ring — never uploaded).
/// - **Bounded.** The ring holds `capacity` entries and evicts the oldest
///   beyond that — #481 already dealt with unbounded quarantine growth,
///   this must not become a second instance of it. One per queue, so a
///   device holds at most `capacity` per queue, not per incident.
/// - **Best-effort persistence.** A refused write keeps the entry in
///   memory for the session and is otherwise silent, matching the engine's
///   other sidecars (the retry ledger, the stall403 counter, the last-sync
///   marker all `try?`). Losing a breadcrumb loses no user data — it is
///   diagnostics, not a queued item (#606's note).
/// - **Unreadable file = empty ring.** The file is ours alone (no legacy
///   shape to honor); a corrupt copy is treated as no history and
///   overwritten by the next write, never retained as a permanent
///   unreadable — the #287 "never rewrite what we cannot read" rule
///   protects queued ITEMS, not this diagnostics sidecar.
///
/// Thread-safe (lock-guarded): the queue actor writes while the SwiftUI
/// diagnostics view reads, and in production the four engines are separate
/// actors over the same app container — a bare class would race.
public final class QuarantineBreadcrumbStore: @unchecked Sendable {
    /// How many exits the ring holds before the oldest is evicted.
    public static let capacity = 10

    private let lock = NSLock()
    private let fileURL: URL
    private var entries: [QuarantineBreadcrumbEntry] = [] // oldest first

    public init(fileURL: URL) {
        self.fileURL = fileURL
        entries = Self.load(from: fileURL)
    }

    /// Appends one exit, evicts the oldest beyond `capacity`, and persists
    /// best-effort (see the type doc for the retention rules).
    public func record(_ entry: QuarantineBreadcrumbEntry) {
        lock.lock()
        defer { lock.unlock() }
        // The one field that can be long (a server error message): trim at
        // write time so an entry stays tiny, reusing the diagnostics
        // surface's existing bound so there is one limit to reason about.
        let trimmed = QuarantineBreadcrumbEntry(
            id: entry.id,
            reason: entry.reason,
            stage: entry.stage,
            httpStatus: entry.httpStatus,
            postgrestCode: entry.postgrestCode,
            errorMessage: entry.errorMessage.map { QuarantineDiagnostics.truncatedErrorMessage($0) },
            attemptCount: entry.attemptCount,
            quarantinedAt: entry.quarantinedAt,
            exitedAt: entry.exitedAt
        )
        entries.append(trimmed)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        Self.save(entries, to: fileURL)
    }

    /// The ring, oldest first. A copy, safe to read from any actor.
    public func history() -> [QuarantineBreadcrumbEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    private static func load(from url: URL) -> [QuarantineBreadcrumbEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([QuarantineBreadcrumbEntry].self, from: data)) ?? []
    }

    private static func save(_ entries: [QuarantineBreadcrumbEntry], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Pure display helpers for the recent-history surface (#606).
public enum QuarantineBreadcrumbs {
    /// The compact, comma-joined factual summary of one exit — "stage
    /// session, HTTP 403, code PGRST301" — only the fields that exist,
    /// nothing invented for a nil one. The exit date is left to the view
    /// (locale formatting). Empty when the failure reached no server at
    /// all (a transport failure has no stage, no status, no code).
    public static func failureSummary(for entry: QuarantineBreadcrumbEntry) -> String {
        var parts: [String] = []
        if let stage = entry.stage {
            parts.append("stage \(stage.rawValue)")
        }
        if let httpStatus = entry.httpStatus {
            parts.append("HTTP \(httpStatus)")
        }
        if let postgrestCode = entry.postgrestCode {
            parts.append("code \(postgrestCode)")
        }
        return parts.joined(separator: ", ")
    }
}
