import SendLogWatchCore
import SwiftUI

/// Health-scale colours for the glanceable status values. Keep these sourced
/// from the Core palette so complications and the full watch app never drift.
///
/// Keep the semantic mapping in sync with the full watch app's StatusColors.
extension Color {
    static let statusLow = Color(red: WatchDesignTokens.primary.red, green: WatchDesignTokens.primary.green, blue: WatchDesignTokens.primary.blue)
    static let statusOptimal = Color(red: WatchDesignTokens.secondary.red, green: WatchDesignTokens.secondary.green, blue: WatchDesignTokens.secondary.blue)
    static let statusCaution = Color(red: WatchDesignTokens.warning.red, green: WatchDesignTokens.warning.green, blue: WatchDesignTokens.warning.blue)
    static let statusHigh = Color(red: WatchDesignTokens.danger.red, green: WatchDesignTokens.danger.green, blue: WatchDesignTokens.danger.blue)
}

func designAccent(_ rgb: PhaseRGB, reducedLuminance: Bool) -> Color {
    let adjusted = WatchDesignTokens.accent(rgb, reducedLuminance: reducedLuminance)
    return Color(red: adjusted.red, green: adjusted.green, blue: adjusted.blue)
}

func acwrColor(_ risk: ACWRRiskBand?, reducedLuminance: Bool = false) -> Color {
    switch risk {
    case .low: designAccent(WatchDesignTokens.primary, reducedLuminance: reducedLuminance)
    case .optimal: designAccent(WatchDesignTokens.secondary, reducedLuminance: reducedLuminance)
    case .caution: designAccent(WatchDesignTokens.warning, reducedLuminance: reducedLuminance)
    case .high: designAccent(WatchDesignTokens.danger, reducedLuminance: reducedLuminance)
    case nil: .secondary
    }
}

func readinessColor(_ zone: String?, reducedLuminance: Bool = false) -> Color {
    switch zone?.lowercased() {
    case "push": designAccent(WatchDesignTokens.secondary, reducedLuminance: reducedLuminance)
    case "maintain": designAccent(WatchDesignTokens.warning, reducedLuminance: reducedLuminance)
    case "recover": designAccent(WatchDesignTokens.danger, reducedLuminance: reducedLuminance)
    default: .secondary
    }
}
