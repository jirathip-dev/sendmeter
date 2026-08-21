import SendmeterCore
import SwiftUI

/// Left/right Static capacity comparison for the Static detail sheet (#655).
///
/// This deliberately ignores the sheet's selected side: asymmetry needs both
/// sides to make a comparison, while the trend itself remains scoped to the
/// global side selection.
struct SideAsymmetryCard: View {
    let recordings: [TindeqRecording]
    let tag: String

    @Environment(\.colorScheme) private var scheme

    private var rows: [TindeqRecording] {
        ForceProgress.trendChartRecordings(recordings, tag: tag)
    }

    private var left: Double? {
        rows.filter { $0.side == .left }.compactMap(\.peakKilograms).max()
    }

    private var right: Double? {
        rows.filter { $0.side == .right }.compactMap(\.peakKilograms).max()
    }

    @ViewBuilder
    var body: some View {
        if let left, let right {
            let strongest = max(left, right)
            let weaker = min(left, right)
            let imbalance = strongest > 0 ? ((strongest - weaker) / strongest) * 100 : 0
            let strongerSide = left >= right ? "left" : "right"
            SurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel("Static left / right asymmetry", systemImage: "arrow.left.and.right")

                    HStack(spacing: 14) {
                        sideBar("Left", value: left, strongest: strongest)
                        sideBar("Right", value: right, strongest: strongest)
                    }

                    Text(
                        imbalance < 1
                            ? "Balanced (<1%)"
                            : "\(imbalance.formatted(.number.precision(.fractionLength(0))))% stronger on the \(strongerSide)\(imbalance >= 15 ? " — worth rebalancing" : "")"
                    )
                    .font(.caption)
                    .foregroundStyle(imbalance >= 15 ? ChartToken.caution.color(scheme) : .secondary)
                }
            }
        }
    }

    private func sideBar(_ label: String, value: Double, strongest: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value.formatted(.number.precision(.fractionLength(1))))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Text("kg")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.secondary.opacity(0.10))
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(value == strongest ? ChartToken.optimal.color(scheme) : ChartToken.forceSecondary.color(scheme))
                        .frame(width: geometry.size.width * CGFloat(strongest > 0 ? value / strongest : 0))
                }
            }
            .frame(height: 8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value.formatted(.number.precision(.fractionLength(1)))) kilograms")
    }
}
