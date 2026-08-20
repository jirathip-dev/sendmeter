import SendmeterCore
import SwiftUI

/// Native counterpart of the web's `ForceCurveCard`.
///
/// The x-axis is logarithmic because the useful duration range spans 1–120s.
/// The shaded polygon is the pointwise 95% recording-level bootstrap band
/// produced by `ForceCurveEngine`; it is deliberately drawn from the fitted
/// prediction points rather than from the measured envelope so sparse data
/// remains visibly uncertain.
struct NativeForceCurveCard: View {
    let tag: String
    let model: ForceCurveModel?
    let hasLoadedRecordings: Bool

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Force duration curve · \(tag)", systemImage: "chart.xyaxis.line")

                if let model {
                    let hasConfidenceBand = (model.confidenceBand?.count ?? 0) >= 2
                    NativeForceCurvePlot(model: model)
                        .frame(height: 190)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            hasConfidenceBand
                                ? "Force duration curve with 95 percent confidence band"
                                : "Force duration curve"
                        )
                        .accessibilityValue(accessibilityValue(for: model))

                    HStack(spacing: 12) {
                        curveMetric("Max", value: model.maximumForceKilograms, unit: "kg")
                        curveMetric("CF", value: model.criticalForceKilograms, unit: "kg")
                        curveMetric("W′", value: model.impulseAboveCriticalForceKilogramSeconds, unit: "kg·s")
                        Spacer(minLength: 0)
                    }
                    .font(.caption.monospacedDigit())

                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(ChartToken.force.color(scheme))
                            .frame(width: 10, height: 3)
                        Text("Hill fit")
                        if hasConfidenceBand {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(ChartToken.force.color(scheme).opacity(0.18))
                                .frame(width: 10, height: 8)
                            Text("95% band")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                } else if hasLoadedRecordings {
                    Text("A force-duration curve appears after at least three long-duration efforts for this exercise.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView("Loading force-duration curve…")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func curveMetric(_ label: String, value: Double?, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value.map { "\($0.formatted(.number.precision(.fractionLength(1)))) \(unit)" } ?? "—")
                .fontWeight(.semibold)
        }
    }

    private func accessibilityValue(for model: ForceCurveModel) -> String {
        let band = model.confidenceBand
        let maximum = "Max \(model.maximumForceKilograms.formatted(.number.precision(.fractionLength(1)))) kilograms"
        guard let first = band?.first,
              let last = band?.last,
              (band?.count ?? 0) >= 2
        else {
            return maximum
        }
        return "\(maximum), 95 percent confidence band from \(first.windowSeconds.formatted(.number.precision(.fractionLength(0)))) to \(last.windowSeconds.formatted(.number.precision(.fractionLength(0)))) seconds"
    }
}

private struct NativeForceCurvePlot: View {
    let model: ForceCurveModel

    @Environment(\.colorScheme) private var scheme

    private let topInset: CGFloat = 8
    private let bottomInset: CGFloat = 20
    private let leadingInset: CGFloat = 32
    private let trailingInset: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            guard let firstPoint = model.points.first,
                  let lastPoint = model.points.last,
                  size.width > leadingInset + trailingInset,
                  size.height > topInset + bottomInset
            else { return }

            let plotWidth = size.width - leadingInset - trailingInset
            let plotHeight = size.height - topInset - bottomInset
            let minimumSeconds = max(0.001, firstPoint.windowSeconds)
            let maximumSeconds = max(minimumSeconds * 1.01, max(lastPoint.windowSeconds, 10))
            let minimumLog = log10(minimumSeconds)
            let maximumLog = log10(maximumSeconds)
            let maximumBand = model.confidenceBand?.map(\.highKilograms).max() ?? 0
            let maximumValue = max(10, max(model.maximumForceKilograms, maximumBand)) * 1.1

            func x(_ seconds: Double) -> CGFloat {
                let fraction = (log10(max(minimumSeconds, seconds)) - minimumLog)
                    / max(0.01, maximumLog - minimumLog)
                return leadingInset + CGFloat(fraction) * plotWidth
            }

            func y(_ kilograms: Double) -> CGFloat {
                topInset + plotHeight - CGFloat(max(0, kilograms) / maximumValue) * plotHeight
            }

            let gridColor = ChartToken.grid.color(scheme)
            let axisColor = ChartToken.axis.color(scheme)
            let forceColor = ChartToken.force.color(scheme)
            let secondaryColor = ChartToken.forceSecondary.color(scheme)

            for index in 0...2 {
                let lineY = topInset + plotHeight * CGFloat(index) / 2
                var grid = Path()
                grid.move(to: CGPoint(x: leadingInset, y: lineY))
                grid.addLine(to: CGPoint(x: size.width - trailingInset, y: lineY))
                context.stroke(grid, with: .color(gridColor), lineWidth: 1)

                let value = maximumValue * Double(2 - index) / 2
                context.draw(
                    Text(value.formatted(.number.precision(.fractionLength(0))))
                        .font(.system(size: 8))
                        .foregroundStyle(axisColor),
                    at: CGPoint(x: leadingInset / 2, y: lineY),
                    anchor: .center
                )
            }

            for seconds in [1.0, 10.0, 60.0, 120.0] where seconds >= minimumSeconds && seconds <= maximumSeconds {
                let lineX = x(seconds)
                var grid = Path()
                grid.move(to: CGPoint(x: lineX, y: topInset))
                grid.addLine(to: CGPoint(x: lineX, y: topInset + plotHeight))
                context.stroke(grid, with: .color(gridColor), lineWidth: 1)
                context.draw(
                    Text("\(seconds.formatted(.number.precision(.fractionLength(0))))s")
                        .font(.system(size: 8))
                        .foregroundStyle(axisColor),
                    at: CGPoint(x: lineX, y: size.height - bottomInset / 2),
                    anchor: .center
                )
            }

            if let band = model.confidenceBand, band.count >= 2 {
                var bandPath = Path()
                for (index, point) in band.enumerated() {
                    let location = CGPoint(x: x(point.windowSeconds), y: y(point.highKilograms))
                    if index == 0 { bandPath.move(to: location) } else { bandPath.addLine(to: location) }
                }
                for point in band.reversed() {
                    bandPath.addLine(to: CGPoint(x: x(point.windowSeconds), y: y(point.lowKilograms)))
                }
                bandPath.closeSubpath()
                context.fill(
                    bandPath,
                    with: .color(forceColor.opacity(ChartToken.force.bandOpacity(scheme)))
                )
            }

            let fitPoints: [(windowSeconds: Double, kilograms: Double)] = if let band = model.confidenceBand,
                                                                                 band.count >= 2 {
                band.map { ($0.windowSeconds, $0.kilograms) }
            } else if let capabilityFit = model.capabilityFit {
                model.points.map {
                    (
                        $0.windowSeconds,
                        ForceCurveEngine.predictCapabilityFit(capabilityFit, seconds: $0.windowSeconds)
                    )
                }
            } else {
                []
            }
            if fitPoints.count >= 2 {
                var fitPath = Path()
                for (index, point) in fitPoints.enumerated() {
                    let location = CGPoint(x: x(point.windowSeconds), y: y(point.kilograms))
                    if index == 0 { fitPath.move(to: location) } else { fitPath.addLine(to: location) }
                }
                context.stroke(
                    fitPath,
                    with: .color(forceColor),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )
            }

            if let criticalForce = model.criticalForceKilograms {
                var criticalPath = Path()
                criticalPath.move(to: CGPoint(x: leadingInset, y: y(criticalForce)))
                criticalPath.addLine(to: CGPoint(x: size.width - trailingInset, y: y(criticalForce)))
                context.stroke(
                    criticalPath,
                    with: .color(ChartToken.caution.color(scheme)),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
            }

            if model.points.count >= 2 {
                var measuredPath = Path()
                for (index, point) in model.points.enumerated() {
                    let location = CGPoint(x: x(point.windowSeconds), y: y(point.kilograms))
                    if index == 0 { measuredPath.move(to: location) } else { measuredPath.addLine(to: location) }
                }
                context.stroke(
                    measuredPath,
                    with: .color(secondaryColor.opacity(0.45)),
                    style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                )
            }

            for point in model.points {
                let center = CGPoint(x: x(point.windowSeconds), y: y(point.kilograms))
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)),
                    with: .color(secondaryColor)
                )
            }
        }
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
