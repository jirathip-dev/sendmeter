import Foundation

// MARK: - Durability policy (issue #287)

/// The watch queues are the sole owner of an offline workout bundle or gauge
/// session, so a caller may only dismiss on one of two durable outcomes:
///
/// 1. The value was encoded and atomically written to disk. The queue may then
///    drain it in the background and delete it only after a successful upload.
/// 2. If persistence failed, the caller still has the in-memory value and must
///    try the idempotent upload directly before returning.
///
/// If both persistence and the direct upload fail, the value is genuinely
/// lost: UI-capable callers show a retry state while retaining their in-memory
/// value, and fire-and-forget callers record a durable one-shot notice. A
/// persist failure must never be described as queued.
///
/// Drain has the matching deletion rule: a file that cannot be read or decoded
/// is left exactly where it is and skipped. It continues to count in the
/// queue's existing `pendingCount()`, which publishes through
/// `PendingSyncCache`; a later compatible build can therefore recover it. A
/// genuinely corrupt file may pin the reported count indefinitely. That is a
/// visible finding, not permission to silently delete user data. `nil` in the
/// cache still means no queue has reported, never an empty queue.
public enum QueuePersistOutcome: Sendable, Equatable {
    /// The value is durably on disk; background draining may begin.
    case queued
    /// Disk persistence failed, but the in-memory fallback upload succeeded.
    case uploadedDirect
    /// Both disk persistence and the in-memory fallback upload failed.
    case lost
}

/// The pure first decision in the durability policy. Keeping it in Core pins
/// the important ordering in host/Linux tests: persistence success starts the
/// drain, while persistence failure uses the still-live value for a direct
/// upload instead.
public enum QueuePersistAction: Sendable, Equatable {
    case drainQueued
    case uploadDirect
}

public enum PendingQueuePolicy {
    public static func actionAfterPersist(_ persisted: Bool) -> QueuePersistAction {
        persisted ? .drainQueued : .uploadDirect
    }

    public static func outcomeAfterDirectUpload(succeeded: Bool) -> QueuePersistOutcome {
        succeeded ? .uploadedDirect : .lost
    }
}

/// Pure decision for whether a queued item should drain now (issue #158):
/// Supabase RLS attributes inserts to `auth.uid()` at INSERT time, not
/// enqueue time, so an item queued under one account must not upload once a
/// *different* account is signed in — it would silently land under the new
/// account. `itemUserId == nil` means the item was written before this field
/// existed (legacy on-disk file); those are trusted to drain under whatever
/// account is currently signed in rather than getting stuck forever.
/// Free function (not a method) so it's directly unit-testable without an
/// actor/async context.
public func shouldDrain(itemUserId: UUID?, currentUserId: UUID?) -> Bool {
    guard let currentUserId else { return false } // signed out: never drain
    guard let itemUserId else { return true } // legacy stamp: trust current session
    return itemUserId == currentUserId
}
