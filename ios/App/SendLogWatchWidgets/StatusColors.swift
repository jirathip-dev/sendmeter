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

func acwrColor(_ risk: ACWRRiskBand?) -> Color {
    switch risk {
    case .low: .statusLow
    case .optimal: .statusOptimal
    case .caution: .statusCaution
    case .high: .statusHigh
    case nil: .secondary
    }
}

func readinessColor(_ zone: String?) -> Color {
    switch zone?.lowercased() {
    case "push": .statusOptimal
    case "maintain": .statusCaution
    case "recover": .statusHigh
    default: .secondary
    }
}
