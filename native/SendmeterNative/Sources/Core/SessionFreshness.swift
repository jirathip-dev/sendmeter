import Foundation

// MARK: - Issue #679 — session-freshness guard (pure decision)

/// The pure decision behind the native session-freshness guard. Token-bearing
/// repository calls route through `AuthService.ensureFreshSession()`, which
/// reads the CURRENT stored session's `expiresAt` and consults this type to
/// decide whether it may be used as-is or must be revalidated/refreshed.
///
/// Lives in Core (not the App target) so the expiry/refresh logic is a pure,
/// `swift test`-covered function rather than untested App-layer code. It never
/// touches supabase-swift — it answers a yes/no from a `TimeInterval` — so the
/// actual refresh stays exactly one place: the existing `SupabaseClient` auth
/// on the main client (the only refresh-token holder, #265).
public enum SessionFreshness {
    /// Slack left before the access token actually expires so a token is never
    /// used that could expire mid-request. The web equivalent relies on
    /// supabase-js's `auth.getSession()` auto-refreshing a merely-expired
    /// session before an authenticated call (src/lib/passkeys.ts); the native
    /// port makes that decision explicit with a safety window, refreshing when
    /// the token is INSIDE this window rather than only once it has passed.
    public static let defaultSafetyWindow: TimeInterval = 30

    /// Whether the stored session needs refreshing/revalidation before use.
    ///
    /// - `nil` `expiresAt` (no session, or one we cannot read) is NOT fresh — it
    ///   must come back from the client.
    /// - A `expiresAt` at or inside `now + safetyWindow` is NOT fresh.
    /// - Only a token comfortably beyond the window is returned without a refresh.
    public static func needsRefresh(
        expiresAt: TimeInterval?,
        now: Date = Date(),
        safetyWindow: TimeInterval = defaultSafetyWindow
    ) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt <= now.timeIntervalSince1970 + safetyWindow
    }

    /// The inverse of ``needsRefresh(expiresAt:now:safetyWindow:)`` — whether the
    /// stored session may be used as-is without going back to the client.
    public static func isFresh(
        expiresAt: TimeInterval?,
        now: Date = Date(),
        safetyWindow: TimeInterval = defaultSafetyWindow
    ) -> Bool {
        !needsRefresh(expiresAt: expiresAt, now: now, safetyWindow: safetyWindow)
    }
}
