import SendLogWatchCore
import SwiftUI

/// Health-scale colours for the glanceable status values. Keep these sourced
/// from the Core palette so complications and the full watch app never drift.
///
/// Keep the semantic mapping in sync with the full watch app's StatusColors.
extension Color {
    static let statusLow = designForeground(WatchDesignTokens.primary)
    static let statusOptimal = designForeground(WatchDesignTokens.secondary)
    static let statusCaution = designForeground(WatchDesignTokens.warning)
    static let statusHigh = designForeground(WatchDesignTokens.danger)
}

/// Decorative accents may dim in Always-On, but text and symbols use the
/// readable resolver below. Keep this split aligned with the full watch app.
func designAccent(_ rgb: PhaseRGB, reducedLuminance: Bool) -> Color {
    let adjusted = WatchDesignTokens.accent(rgb, reducedLuminance: reducedLuminance)
    return Color(red: adjusted.red, green: adjusted.green, blue: adjusted.blue)
}

func designForeground(_ rgb: PhaseRGB, on surface: PhaseRGB = WatchDesignTokens.cardStrong) -> Color {
    let adjusted = WatchDesignTokens.readableForeground(rgb, on: surface)
    return Color(red: adjusted.red, green: adjusted.green, blue: adjusted.blue)
}

private func acwrToken(_ risk: ACWRRiskBand?) -> PhaseRGB? {
    switch risk {
    case .low: WatchDesignTokens.primary
    case .optimal: WatchDesignTokens.secondary
    case .caution: WatchDesignTokens.warning
    case .high: WatchDesignTokens.danger
    case nil: nil
    }
}

func acwrColor(_ risk: ACWRRiskBand?) -> Color {
    guard let token = acwrToken(risk) else { return .secondary }
    return designForeground(token)
}

func acwrAccent(_ risk: ACWRRiskBand?, reducedLuminance: Bool) -> Color {
    guard let token = acwrToken(risk) else { return .secondary }
    return designAccent(token, reducedLuminance: reducedLuminance)
}

private func readinessToken(_ zone: String?) -> PhaseRGB? {
    switch zone?.lowercased() {
    case "push": WatchDesignTokens.secondary
    case "maintain": WatchDesignTokens.warning
    case "recover": WatchDesignTokens.danger
    default: nil
    }
}

func readinessColor(_ zone: String?) -> Color {
    guard let token = readinessToken(zone) else { return .secondary }
    return designForeground(token)
}

func readinessAccent(_ zone: String?, reducedLuminance: Bool) -> Color {
    guard let token = readinessToken(zone) else { return .secondary }
    return designAccent(token, reducedLuminance: reducedLuminance)
}
