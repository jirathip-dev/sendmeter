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
