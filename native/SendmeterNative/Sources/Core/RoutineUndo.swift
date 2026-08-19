import Foundation

/// Account-scoped state for a routine Undo. The queue item that carries the
/// actual delete intent is durable; this in-memory state makes the optimistic
/// UI and any in-flight insert obey that intent immediately.
public struct RoutineUndoState: Equatable, Sendable {
    private var claimedReceipts: Set<SessionLogReceipt> = []
    public private(set) var pendingDeleteReceipts: Set<SessionLogReceipt> = []

    public init() {}

    /// Claims one Undo before its first await. A receipt from another account
    /// can never become a delete operation for the current account, and a
    /// repeated tap cannot launch a second delete.
    @discardableResult
    public mutating func claim(
        _ receipt: SessionLogReceipt,
        currentUserID: UUID?
    ) -> Bool {
        guard receipt.accountUserID == currentUserID else { return false }
        guard claimedReceipts.insert(receipt).inserted else { return false }
        pendingDeleteReceipts.insert(receipt)
        return true
    }

    public func isClaimed(_ receipt: SessionLogReceipt) -> Bool {
        claimedReceipts.contains(receipt)
    }

    public func hasPendingDelete(
        sessionID: UUID,
        accountUserID: UUID?
    ) -> Bool {
        guard let accountUserID else { return false }
        return pendingDeleteReceipts.contains(
            SessionLogReceipt(sessionID: sessionID, accountUserID: accountUserID)
        )
    }

    /// Rehydrates a delete intent read from the durable queue after a relaunch.
    /// Rehydrated intents also claim the matching insert path so a queued
    /// session cannot be uploaded again while its delete is pending.
    public mutating func restorePendingDelete(
        _ receipt: SessionLogReceipt,
        currentUserID: UUID?
    ) {
        guard receipt.accountUserID == currentUserID else { return }
        claimedReceipts.insert(receipt)
        pendingDeleteReceipts.insert(receipt)
    }

    /// Clears the local hide marker only after the durable delete queue item
    /// has completed. A different account cannot acknowledge this receipt.
    @discardableResult
    public mutating func markDeleteCompleted(
        _ receipt: SessionLogReceipt,
        currentUserID: UUID?
    ) -> Bool {
        guard receipt.accountUserID == currentUserID else { return false }
        pendingDeleteReceipts.remove(receipt)
        return true
    }

    /// A user discard removes the delete intent itself. Releasing the claim
    /// lets a still-queued insert reconcile normally; otherwise the row would
    /// stay hidden in this process after its durable delete was deliberately
    /// discarded.
    @discardableResult
    public mutating func discardPendingDelete(
        _ receipt: SessionLogReceipt,
        currentUserID: UUID?
    ) -> Bool {
        guard receipt.accountUserID == currentUserID else { return false }
        let wasPending = pendingDeleteReceipts.remove(receipt) != nil
        claimedReceipts.remove(receipt)
        return wasPending
    }

    public mutating func reset() {
        claimedReceipts.removeAll()
        pendingDeleteReceipts.removeAll()
    }
}

/// The pure timeout/identity rules for native toasts. The view owns the
/// closure-bearing state; this type owns the part that must survive identical
/// message replacement and stale expiry callbacks.
public enum ToastLifecycle {
    public static let passiveDurationSeconds: Double = 2
    public static let actionableDurationSeconds: Double = 5

    public static func durationSeconds(hasAction: Bool) -> Double {
        hasAction ? actionableDurationSeconds : passiveDurationSeconds
    }

    public static func timeoutNanoseconds(hasAction: Bool) -> UInt64 {
        UInt64(durationSeconds(hasAction: hasAction) * 1_000_000_000)
    }

    /// An expiry callback may dismiss only the toast instance that scheduled
    /// it. Comparing IDs instead of message text handles identical messages
    /// and prevents an old callback from clearing a replacement toast.
    public static func shouldDismiss(
        currentID: UUID?,
        callbackID: UUID
    ) -> Bool {
        currentID == callbackID
    }
}
