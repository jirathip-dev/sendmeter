import SwiftUI

/// Sendmeter's dark-theme interaction palette for native watch surfaces.
/// Mirrors the named tokens in `src/index.css`; keep these values in sync so
/// primary actions and state cues carry the same meaning on phone and watch.
enum SendmeterColor {
    /// Semantic aliases retained for service-adjacent code and old previews.
    /// New surfaces use `WatchPalette` directly; keeping these names avoids a
    /// colour decision leaking back into production behavior files.
    static let primary = WatchPalette.foreground(WatchDesignTokens.primary)
    static let success = WatchPalette.foreground(WatchDesignTokens.success)
    static let warning = WatchPalette.foreground(WatchDesignTokens.warning)
    static let danger = WatchPalette.foreground(WatchDesignTokens.danger)
}
