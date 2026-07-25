import Foundation

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
