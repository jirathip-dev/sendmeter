import Foundation

/// The risk bands drawn on the ACWR status-card track (#748). Mirrors the web
/// card's `ACWR_TRACK_GRADIENT` (its `--info/--success/--warning/--danger`
/// family); the view maps each band to a `ChartToken` color so the gradient's
/// geometry stays in Core and only the colors live in the App layer.
public enum AcwrRiskBand: Equatable, Sendable {
    case low
    case optimal
    case caution
    case danger
}

/// One color stop on the ACWR status-card gradient track.
public struct AcwrTrackStop: Equatable, Sendable {
    /// Position on the track as a fraction of the 0–2 scale.
    public let fraction: Double
    public let band: AcwrRiskBand

    public init(fraction: Double, band: AcwrRiskBand) {
        self.fraction = fraction
        self.band = band
    }
}

/// One true-scale tick label under the ACWR status-card track.
public struct AcwrTrackTick: Equatable, Sendable {
    public let value: Double
    public let label: String

    public init(value: Double, label: String) {
        self.value = value
        self.label = label
    }

    /// Position on the track as a fraction of the 0–2 scale.
    public var fraction: Double { value / AcwrStatusCard.trackScale }
}

/// Pure geometry, status thresholds, and copy for the native Dashboard's ACWR
/// status card (#748) — a port of the web `Dashboard.tsx` ACWR card with the
/// `ACWR_TRACK_GRADIENT` / tick-placement / marker-clamping math from
/// `src/lib/metrics.ts`. Kept in `SendmeterCore` so the thresholds and band
/// geometry are unit-testable independently of SwiftUI; the view only resolves
/// the semantic `ChartToken` colors and never re-derives a threshold.
public enum AcwrStatusCard {
    /// The ACWR track runs 0–2 (the universal injury-risk scale).
    public static let trackScale = 2.0

    /// The universal risk-zone thresholds — identical to `getACWRStatus()`
    /// (web `src/lib/metrics.ts`) and `TrainingMetrics.acwrStatus(_:)`.
    public static let thresholds: [Double] = [0.8, 1.3, 1.5]

    /// Band-edge positions as a fraction of the 0–2 track: each threshold / 2
    /// → 0.8 = 0.40, 1.3 = 0.65, 1.5 = 0.75. This is the true geometry the
    /// marker dot shares so the dot always lands in the band that names its
    /// own status (issue #189).
    public static let bandEdgeFractions: [Double] = thresholds.map { $0 / trackScale }

    /// The gradient's blend stops, expressing the web's `ACWR_TRACK_GRADIENT`
    /// on a 0–1 track. Stops are placed symmetrically around each true
    /// threshold so the 50/50 blend midpoint lands exactly on the band edge
    /// (#189 + #213): 0.8 → 0.40 (blend 0.32–0.48), 1.3 → 0.65 (0.58–0.72),
    /// 1.5 → 0.75 (0.72–0.78). The transitions are deliberately NOT hard
    /// stops at the same position — that was the regression #213 fixed.
    public static let gradientStops: [AcwrTrackStop] = [
        AcwrTrackStop(fraction: 0.00, band: .low),
        AcwrTrackStop(fraction: 0.32, band: .low),
        AcwrTrackStop(fraction: 0.48, band: .optimal),
        AcwrTrackStop(fraction: 0.58, band: .optimal),
        AcwrTrackStop(fraction: 0.72, band: .caution),
        AcwrTrackStop(fraction: 0.78, band: .danger),
        AcwrTrackStop(fraction: 1.00, band: .danger)
    ]

    /// Tick values at their true scale fractions — 0/1.0/1.5/2 at 0/50/75/100%
    /// (issue #189: `justify-content: space-between` spaced these evenly
    /// regardless of value, so "1.5" sat at ~66% while the marker it was meant
    /// to label rendered at 75%).
    public static let ticks: [AcwrTrackTick] = [
        AcwrTrackTick(value: 0, label: "0"),
        AcwrTrackTick(value: 1.0, label: "1.0"),
        AcwrTrackTick(value: 1.5, label: "1.5"),
        AcwrTrackTick(value: 2, label: "2")
    ]

    /// Marker position on the track as a fraction of the 0–2 scale, clamped to
    /// [0, 1]. The web uses `(ratio / 2) * 100 %`, clamped to 0–100%. Nil when
    /// there is no ratio — a nil marker must render as no dot, never at 0
    /// (which would indistinguishable from a genuine 0 ratio).
    public static func markerFraction(_ ratio: Double?) -> Double? {
        guard let ratio else { return nil }
        return min(max(ratio / trackScale, 0), 1)
    }

    /// The phase-fit line under the status label, mirroring the web's
    /// `phaseAcwrFit` copy:
    ///   - inside the phase band → "On target for {phase.name}"
    ///   - below → "Below {phase.name} target ({phase.acwrBandText})"
    ///   - above → "Above {phase.name} target ({phase.acwrBandText})"
    ///      Nil when there is no ratio or no phase band to compare against.
    public static func phaseFitLine(
        ratio: Double?,
        phase: PhaseDefinition?
    ) -> String? {
        guard let phase else { return nil }
        switch TrainingMetrics.phaseFit(ratio: ratio, phase: phase) {
        case .below:
            return "Below \(phase.name) target (\(phase.acwrBandText))"
        case .onTarget:
            return "On target for \(phase.name)"
        case .above:
            return "Above \(phase.name) target (\(phase.acwrBandText))"
        case nil:
            return nil
        }
    }

    /// Honest explainer shown in the no-data state. The card must distinguish
    /// "still loading" from "genuinely no history" from "history too old to
    /// yield a ratio" instead of fabricating a value or blaming a fresh user
    /// on every cold launch (#652 F2 framing, mirrored here for the ratio).
    public static func nilExplainer(hasLoadedSessions: Bool, hasSessions: Bool) -> String {
        if !hasLoadedSessions {
            return "Your training history is still loading."
        }
        if !hasSessions {
            return "Log a few sessions to see your ACWR."
        }
        // Accuracy matters here (#748 round 2 finding 6): ratio is nil with
        // history present whenever the 90-day window has no measurable load —
        // the sessions may sit outside the window, OR be inside it but carry
        // zero load (duration × RPE = 0). Don't claim a single cause.
        return "There isn't enough training load in your recent 90 days to compute an ACWR ratio yet."
    }

    /// The VoiceOver summary for the card. Reads a single "No data." when the
    /// ratio is nil — never "No data. No data." — and otherwise combines the
    /// ratio, status, phase-fit line, and the Acute/Chronic footer.
    public static func accessibilitySummary(
        ratio: Double?,
        acute: Double,
        chronic: Double,
        phase: PhaseDefinition?
    ) -> String {
        var parts: [String] = []
        if let ratio {
            parts.append(String(format: "%.2f", ratio) + ". " + TrainingMetrics.acwrStatus(ratio).rawValue + ".")
            if let fitLine = phaseFitLine(ratio: ratio, phase: phase) {
                parts.append(fitLine + ".")
            }
        } else {
            parts.append("No data.")
        }
        parts.append("Acute 7d \(Int(acute.rounded())). Chronic avg \(Int(chronic.rounded())).")
        return parts.joined(separator: " ")
    }
}
