import SwiftUI

/// Colour mapping for the two glanceable status values (readiness zone, ACWR
/// risk), shared by the watch app's status page and the complications so the
/// same number never reads as two different colours in the two places.
///
/// KEEP IN SYNC with the identical copy in the SendLogWatchWidgets target —
/// the widgets are a separate process and a separate filesystem-synchronized
/// group, so (like WidgetShared.swift) this is duplicated rather than shared.
/// Unlike WidgetShared.swift drift here doesn't break decode; it just makes the
/// watch face and the app disagree about what "optimal" looks like.
///
/// `nil` maps to the neutral middle colour, which is right for a complication
/// (it renders one tint either way) but NOT for a screen that has room to be
/// honest — the status page shows `—` in a muted colour instead of pretending
/// an unknown value sits in the middle band.

func acwrColor(_ risk: String?) -> Color {
    switch risk {
    case "high": return .orange
    case "low": return .purple
    default: return .blue // optimal / unknown
    }
}

func readinessColor(_ zone: String?) -> Color {
    switch zone {
    case "push": return .blue
    case "recover": return .orange
    default: return .yellow // maintain / unknown
    }
}
