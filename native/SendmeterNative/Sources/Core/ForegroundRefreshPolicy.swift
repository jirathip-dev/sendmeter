import Foundation

// MARK: - Foreground full-refresh policy (#673)

/// The gate that decides whether a scenePhase → `.active` transition should
/// run the full authoritative list refresh.
///
/// `refreshAll` fans out 9 parallel full-table fetches (sessions, settings,
/// phase periods, health metrics, recordings, presets, routine presets,
/// workouts, tag metadata). Historically it ran on EVERY foreground — a
/// radio + battery + latency cost on each app switch, with no incremental
/// cursor. The web app instead leans on realtime version bumps to refetch
/// selectively.
///
/// The native app already converges the realtime-watched tables
/// (`RealtimeListReconciler`): a server write to sessions / recordings /
/// workouts / health metrics fires a coalesced, per-slice refetch. So a
/// foreground where nothing is stale does not need the 9-table sweep; only
/// the explicit pull-to-refresh and the listed fallback cases do.
///
/// Chosen cursor scheme (documented in `docs/native-swift-rewrite.md`): a
/// monotonic "last successful full refresh" timestamp plus a staleness
/// window. This is a TIME cursor, not an updated-at-per-row cursor — the
/// latter is the heavier alternative noted in the issue and is unnecessary
/// while realtime converges the watched tables with targeted refreshes.
public struct ForegroundRefreshPolicy: Equatable, Sendable {
    /// A full refresh older than this many seconds is always considered
    /// stale. Kept modest so data from tables realtime does NOT watch
    /// (settings, phase periods, presets, routine presets, tags) converges
    /// within a bounded window, while still eliminating the per-switch sweep.
    public let staleAfter: TimeInterval

    public init(staleAfter: TimeInterval) {
        self.staleAfter = staleAfter
    }

    /// Whether a foreground should trigger `refreshAll`.
    ///
    /// Returns true (must refresh fully) when ANY of these hold:
    /// - `hasLoadedData` is false — the account has never loaded its lists
    ///   (cold launch / account switch), so there is no baseline to trust.
    /// - `realtimeConnected` is false — a dropped socket degrades to
    ///   foreground refetch (the documented convergence fallback), so a
    ///   no-op foreground while realtime is down would miss remote edits.
    /// - `lastFullRefreshAt` is nil — no successful full refresh yet.
    /// - The last full refresh is at least `staleAfter` seconds old — the
    ///   safety net for tables realtime does not watch, plus a long
    ///   background gap.
    ///
    /// Otherwise (data loaded, realtime connected, recent full refresh) the
    /// foreground is a no-change one and 0 full-table fetches are issued.
    public func shouldRefreshOnForeground(
        lastFullRefreshAt: TimeInterval?,
        now: TimeInterval,
        realtimeConnected: Bool,
        hasLoadedData: Bool
    ) -> Bool {
        if !hasLoadedData { return true }
        if !realtimeConnected { return true }
        guard let lastFullRefreshAt else { return true }
        return now - lastFullRefreshAt >= staleAfter
    }
}
