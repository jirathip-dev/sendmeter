import SwiftUI

/// Sendmeter's dark-theme interaction palette for native watch surfaces.
/// Mirrors the named tokens in `src/index.css`; keep these values in sync so
/// primary actions and state cues carry the same meaning on phone and watch.
enum SendmeterColor {
    /// `--primary`: primary actions and the live force trace.
    static let primary = Color(red: 0x5B / 255, green: 0x5F / 255, blue: 0xC7 / 255)
    /// `--success` (dark): connected/saved states.
    static let success = Color(red: 0x4F / 255, green: 0xB0 / 255, blue: 0xFF / 255)
    /// `--warning` (dark): caution states such as low battery.
    static let warning = Color(red: 0xE8 / 255, green: 0xC2 / 255, blue: 0x4E / 255)
    /// `--danger` (dark): destructive or error actions.
    static let danger = Color(red: 0xF0 / 255, green: 0x86 / 255, blue: 0x4C / 255)
}
