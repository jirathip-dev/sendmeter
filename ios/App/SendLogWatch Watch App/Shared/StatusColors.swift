import SendLogWatchCore
import SwiftUI

/// Health-scale colours for the glanceable status values. These mirror the
/// dark-theme web tokens: violet for low load, blue for optimal/push, yellow
/// for caution/maintain and orange for high/recover.
///
/// KEEP IN SYNC with the identical copy in the SendLogWatchWidgets target.
extension Color {
    static let statusLow = WatchPalette.primary
    static let statusOptimal = WatchPalette.secondary
    static let statusCaution = WatchPalette.warning
    static let statusHigh = WatchPalette.danger
}

func acwrColor(_ risk: ACWRRiskBand?, reducedLuminance: Bool = false) -> Color {
    switch risk {
    case .low: WatchPalette.accent(WatchDesignTokens.primary, reducedLuminance: reducedLuminance)
    case .optimal: WatchPalette.accent(WatchDesignTokens.secondary, reducedLuminance: reducedLuminance)
    case .caution: WatchPalette.accent(WatchDesignTokens.warning, reducedLuminance: reducedLuminance)
    case .high: WatchPalette.accent(WatchDesignTokens.danger, reducedLuminance: reducedLuminance)
    case nil: .secondary
    }
}

func readinessColor(_ zone: String?, reducedLuminance: Bool = false) -> Color {
    switch zone?.lowercased() {
    case "push": WatchPalette.accent(WatchDesignTokens.secondary, reducedLuminance: reducedLuminance)
    case "maintain": WatchPalette.accent(WatchDesignTokens.warning, reducedLuminance: reducedLuminance)
    case "recover": WatchPalette.accent(WatchDesignTokens.danger, reducedLuminance: reducedLuminance)
    default: .secondary
    }
}
