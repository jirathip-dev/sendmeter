import Foundation
import SendLogWatchCore
import SwiftUI

/// Readiness uses a 0...100 circular grammar everywhere it appears. Unknown
/// data gets a neutral outline and dash, never a zero-length coloured gauge.
///
/// KEEP IN SYNC with the identical copy in the SendLogWatchWidgets target.
struct ReadinessRingView: View {
    let score: Int?
    let zone: String?
    var lineWidth: CGFloat = 7
    var valueFontSize: CGFloat = 24
    var emptyAccessibilityHint: String? = nil

    private var progress: Double? { StatusPresentation.readinessProgress(score) }
    private var zoneLabel: String? { StatusPresentation.readinessZoneLabel(zone) }

    private var accessibilityValue: String {
        guard let score else {
            return ["No data", emptyAccessibilityHint].compactMap { $0 }.joined(separator: ". ")
        }
        return "\(score) out of 100, \(zoneLabel ?? "zone unavailable")"
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.24), lineWidth: lineWidth)
            if let progress {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        readinessColor(zone),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            Text(score.map(String.init) ?? "—")
                .font(.system(size: valueFontSize, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(score == nil ? Color.secondary : readinessColor(zone))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Readiness")
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("readiness-ring")
    }
}

/// ACWR uses a fixed 0...2 track. Segment widths encode the exact risk ranges
/// (40% low, 25% optimal, 10% caution, 25% high); text and VoiceOver carry the
/// same risk name so colour is never the only signal.
struct ACWRRiskTrackView: View {
    let value: Double?
    var bandHeight: CGFloat = 7
    var emptyAccessibilityHint: String? = nil

    private var position: Double? { StatusPresentation.acwrTrackPosition(value) }
    private var risk: ACWRRiskBand? { StatusPresentation.acwrRiskBand(value) }

    private var accessibilityValue: String {
        guard let value, let risk else {
            return ["No data", emptyAccessibilityHint].compactMap { $0 }.joined(separator: ". ")
        }
        return "\(String(format: "%.2f", value)), \(risk.label)"
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                if let position {
                    HStack(spacing: 0) {
                        Rectangle().fill(Color.statusLow).frame(width: width * 0.40)
                        Rectangle().fill(Color.statusOptimal).frame(width: width * 0.25)
                        Rectangle().fill(Color.statusCaution).frame(width: width * 0.10)
                        Rectangle().fill(Color.statusHigh).frame(width: width * 0.25)
                    }
                    .frame(height: bandHeight)
                    .clipShape(Capsule())

                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.white)
                        .overlay {
                            RoundedRectangle(cornerRadius: 1.5)
                                .stroke(.black.opacity(0.45), lineWidth: 0.5)
                        }
                        .frame(width: 3, height: bandHeight + 4)
                        .offset(x: max(0, min(width - 3, width * position - 1.5)))
                } else {
                    Capsule()
                        .stroke(.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .frame(width: width, height: bandHeight)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: bandHeight + 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("ACWR")
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("acwr-risk-track")
    }
}
