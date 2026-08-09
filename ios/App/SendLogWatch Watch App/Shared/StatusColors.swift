import SendLogWatchCore
import SwiftUI

/// Health-scale colours for the glanceable status values. These mirror the
/// dark-theme web tokens: violet for low load, blue for optimal/push, yellow
/// for caution/maintain and orange for high/recover.
///
/// KEEP IN SYNC with the identical copy in the SendLogWatchWidgets target.
extension Color {
    static let statusLow = WatchPalette.foreground(WatchDesignTokens.primary)
    static let statusOptimal = WatchPalette.foreground(WatchDesignTokens.secondary)
    static let statusCaution = WatchPalette.foreground(WatchDesignTokens.warning)
    static let statusHigh = WatchPalette.foreground(WatchDesignTokens.danger)
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
    return WatchPalette.foreground(token)
}

func acwrAccent(_ risk: ACWRRiskBand?, reducedLuminance: Bool) -> Color {
    guard let token = acwrToken(risk) else { return .secondary }
    return WatchPalette.accent(token, reducedLuminance: reducedLuminance)
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
    return WatchPalette.foreground(token)
}

func readinessAccent(_ zone: String?, reducedLuminance: Bool) -> Color {
    guard let token = readinessToken(zone) else { return .secondary }
    return WatchPalette.accent(token, reducedLuminance: reducedLuminance)
}
