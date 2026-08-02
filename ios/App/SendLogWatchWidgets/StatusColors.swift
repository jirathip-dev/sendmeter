import SendLogWatchCore
import SwiftUI

/// Health-scale colours for the glanceable status values. These mirror the
/// dark-theme web tokens: violet for low load, blue for optimal/push, yellow
/// for caution/maintain and orange for high/recover.
///
/// KEEP IN SYNC with the identical copy in the SendLogWatchWidgets target.
extension Color {
    static let statusLow = Color(red: 0x7B / 255, green: 0x83 / 255, blue: 0xEB / 255)
    static let statusOptimal = Color(red: 0x4F / 255, green: 0xB0 / 255, blue: 0xFF / 255)
    static let statusCaution = Color(red: 0xE8 / 255, green: 0xC2 / 255, blue: 0x4E / 255)
    static let statusHigh = Color(red: 0xF0 / 255, green: 0x86 / 255, blue: 0x4C / 255)
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
