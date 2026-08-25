import Charts
import SendmeterCore
import SwiftUI

private func formattedForceKilograms(_ kilograms: Double) -> String {
    kilograms.formatted(.number.precision(.fractionLength(1)))
}

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
    /// The target is resolved once for the selected exercise/side/preset by
    /// ForceView. This card only renders that authoritative band; it never
    /// derives a second target from curve points.
    let targetBand: ForceTargetBand?
    let connectionPending: Bool
    let showsPrimaryEmptyState: Bool
    let emptyActionTitle: String
    let emptyAction: () -> Void

    @Environment(\.colorScheme) private var scheme

    init(
        tag: String,
        model: ForceCurveModel?,
        hasLoadedRecordings: Bool,
        targetBand: ForceTargetBand?,
        connectionPending: Bool = false,
        showsPrimaryEmptyState: Bool = true,
        emptyActionTitle: String,
        emptyAction: @escaping () -> Void
    ) {
        self.tag = tag
        self.model = model
        self.hasLoadedRecordings = hasLoadedRecordings
        self.targetBand = targetBand
        self.connectionPending = connectionPending
        self.showsPrimaryEmptyState = showsPrimaryEmptyState
        self.emptyActionTitle = emptyActionTitle
        self.emptyAction = emptyAction
    }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Force duration curve · \(tag)", systemImage: "chart.xyaxis.line")

                if let targetBand {
                    Text(targetDisplayText(for: targetBand))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(targetAccessibilityLabel(for: targetBand))
                }

                if let model, !model.points.isEmpty {
                    let hasConfidenceBand = (model.confidenceBand?.count ?? 0) >= 2
                    NativeForceCurvePlot(model: model, targetBand: targetBand)
                        .frame(height: 190)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            hasConfidenceBand
                                ? "Force duration curve with 95 percent confidence band"
                                : "Force duration curve"
                        )
                        .accessibilityValue(accessibilityValue(for: model, targetBand: targetBand))
                        .accessibilityForceCurveChartDescriptor(model, targetBand: targetBand)

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
                        if targetBand != nil {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(ChartToken.optimal.color(scheme).opacity(0.8))
                                .frame(width: 10, height: 3)
                            Text("Plan target")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                } else if hasLoadedRecordings {
                    if connectionPending {
                        ProgressView("Connecting to Progressor…")
                            .frame(maxWidth: .infinity, minHeight: 150)
                    } else if showsPrimaryEmptyState {
                        ProductEmptyState(
                            title: "Shape your force curve",
                            message: "Three long pulls reveal how your strength holds over time.",
                            actionTitle: emptyActionTitle,
                            action: emptyAction
                        )
                    } else {
                        Text("No long pulls match this exercise yet. Record one above to shape this force curve.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("Loading force-duration curve…")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func targetDisplayText(for band: ForceTargetBand) -> String {
        let targetKilograms: String = formattedForceKilograms(band.kilograms)
        let lowKilograms: String = formattedForceKilograms(band.lowKilograms)
        let highKilograms: String = formattedForceKilograms(band.highKilograms)
        let targetPrefix: String = "Plan target \(targetKilograms) kg · "
        let rangeDescription: String = "range \(lowKilograms)–\(highKilograms) kg"
        return targetPrefix + rangeDescription
    }

    private func targetAccessibilityLabel(for band: ForceTargetBand) -> String {
        let targetKilograms: String = formattedForceKilograms(band.kilograms)
        let lowKilograms: String = formattedForceKilograms(band.lowKilograms)
        let highKilograms: String = formattedForceKilograms(band.highKilograms)
        let targetPrefix: String = "Plan target \(targetKilograms) kilograms, "
        let rangeDescription: String = "range \(lowKilograms) to \(highKilograms) kilograms"
        return targetPrefix + rangeDescription
    }

    private func targetAccessibilitySuffix(for band: ForceTargetBand) -> String {
        let targetKilograms: String = formattedForceKilograms(band.kilograms)
        let lowKilograms: String = formattedForceKilograms(band.lowKilograms)
        let highKilograms: String = formattedForceKilograms(band.highKilograms)
        let targetPrefix: String = ", plan target \(targetKilograms) kilograms, "
        let rangeDescription: String = "range \(lowKilograms) to \(highKilograms) kilograms"
        return targetPrefix + rangeDescription
    }

    private func curveMetric(_ label: String, value: Double?, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value.map { "\($0.formatted(.number.precision(.fractionLength(1)))) \(unit)" } ?? "—")
                .fontWeight(.semibold)
        }
    }

    private func accessibilityValue(
        for model: ForceCurveModel,
        targetBand: ForceTargetBand?
    ) -> String {
        let band = model.confidenceBand
        let maximum = "Max \(model.maximumForceKilograms.formatted(.number.precision(.fractionLength(1)))) kilograms"
        let target = targetBand.map { targetAccessibilitySuffix(for: $0) } ?? ""
        guard let first = band?.first,
              let last = band?.last,
              (band?.count ?? 0) >= 2
        else {
            return maximum + target
        }
        return "\(maximum), 95 percent confidence band from \(first.windowSeconds.formatted(.number.precision(.fractionLength(0)))) to \(last.windowSeconds.formatted(.number.precision(.fractionLength(0)))) seconds\(target)"
    }
}

private struct NativeForceCurvePlot: View {
    let model: ForceCurveModel
    let targetBand: ForceTargetBand?

    @Environment(\.colorScheme) private var scheme
    @State private var selectedPointIndex: Int?
    @State private var tooltipSize: CGSize = .zero
    @State private var tickedPointIndex: Int?

    private let topInset: CGFloat = 8
    private let bottomInset: CGFloat = 20
    private let leadingInset: CGFloat = 32
    private let trailingInset: CGFloat = 8

    var body: some View {
        ZStack(alignment: .topLeading) {
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
            let maximumTarget = targetBand?.highKilograms ?? 0
            let maximumValue = max(10, max(model.maximumForceKilograms, max(maximumBand, maximumTarget))) * 1.1

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
            let targetColor = ChartToken.optimal.color(scheme)

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
                        .foregroundColor(axisColor),
                    at: CGPoint(x: leadingInset / 2, y: lineY),
                    anchor: .center
                )
            }

            if let targetBand {
                let upperY = y(targetBand.highKilograms)
                let lowerY = y(targetBand.lowKilograms)
                context.fill(
                    Path(CGRect(
                        x: leadingInset,
                        y: upperY,
                        width: plotWidth,
                        height: max(1, lowerY - upperY)
                    )),
                    with: .color(targetColor.opacity(ChartToken.optimal.bandOpacity(scheme)))
                )

                var targetPath = Path()
                targetPath.move(to: CGPoint(x: leadingInset, y: y(targetBand.kilograms)))
                targetPath.addLine(to: CGPoint(x: size.width - trailingInset, y: y(targetBand.kilograms)))
                context.stroke(
                    targetPath,
                    with: .color(targetColor.opacity(0.85)),
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
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
                        .foregroundColor(axisColor),
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

            if let selectedPointIndex,
               model.points.indices.contains(selectedPointIndex) {
                let point = model.points[selectedPointIndex]
                let center = CGPoint(x: x(point.windowSeconds), y: y(point.kilograms))
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)),
                    with: .color(secondaryColor.opacity(0.2))
                )
            }

            for (index, point) in model.points.enumerated() {
                let center = CGPoint(x: x(point.windowSeconds), y: y(point.kilograms))
                let radius: CGFloat = index == selectedPointIndex ? 5 : 3
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )),
                    with: .color(secondaryColor)
                )
            }
            }

            GeometryReader { geo in
                if #available(iOS 17, *) {
                    Color.clear
                        .contentShape(Rectangle())
                        .hapticTapMuted()
                        .gesture(
                            SpatialTapGesture()
                                .onEnded { value in
                                    let index = selectedPointIndex(
                                        at: value.location,
                                        size: geo.size
                                    )
                                    select(index == selectedPointIndex ? nil : index)
                                }
                        )
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 10)
                                .onChanged { value in
                                    select(
                                        selectedPointIndex(
                                            at: value.location,
                                            size: geo.size
                                        )
                                    )
                                }
                        )
                        .accessibilityHidden(true)
                }

                if let selectedPointIndex,
                   model.points.indices.contains(selectedPointIndex) {
                    tooltip(
                        pointIndex: selectedPointIndex,
                        x: x(for: model.points[selectedPointIndex].windowSeconds, size: geo.size),
                        size: geo.size
                    )
                }
            }
        }
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onChange(of: model.points) { _ in
            selectedPointIndex = nil
            tickedPointIndex = nil
        }
        .onDisappear {
            selectedPointIndex = nil
            tickedPointIndex = nil
        }
    }

    private func select(_ index: Int?) {
        if SelectionHaptics.valueChanged(tickedPointIndex, index) {
            tickedPointIndex = index
            Haptics.shared.playGesture(.selection)
        }
        selectedPointIndex = index
    }

    private func selectedPointIndex(at location: CGPoint, size: CGSize) -> Int? {
        let plotWidth = size.width - leadingInset - trailingInset
        guard plotWidth > 0,
              let firstPoint = model.points.first,
              let lastPoint = model.points.last,
              location.x >= leadingInset,
              location.x <= size.width - trailingInset
        else { return nil }
        let minimumSeconds = max(0.001, firstPoint.windowSeconds)
        let maximumSeconds = max(minimumSeconds * 1.01, max(lastPoint.windowSeconds, 10))
        let fraction = Double((location.x - leadingInset) / plotWidth)
        guard let seconds = ForceCurveSelection.seconds(
            atXFraction: fraction,
            firstSeconds: minimumSeconds,
            lastSeconds: maximumSeconds
        ) else { return nil }
        return ForceCurveSelection.nearestPointIndex(points: model.points, toSeconds: seconds)
    }

    private func x(for seconds: Double, size: CGSize) -> CGFloat {
        guard let firstPoint = model.points.first,
              let lastPoint = model.points.last
        else { return leadingInset }
        let minimumSeconds = max(0.001, firstPoint.windowSeconds)
        let maximumSeconds = max(minimumSeconds * 1.01, max(lastPoint.windowSeconds, 10))
        let plotWidth = max(1, size.width - leadingInset - trailingInset)
        let fraction = ForceCurveSelection.xFraction(
            forSeconds: seconds,
            firstSeconds: minimumSeconds,
            lastSeconds: maximumSeconds
        ) ?? 0
        return leadingInset + CGFloat(fraction) * plotWidth
    }

    private func tooltip(pointIndex: Int, x: CGFloat, size: CGSize) -> some View {
        let point = model.points[pointIndex]
        let bandPoint = model.confidenceBand.flatMap { band -> ForceCurveConfidencePoint? in
            guard band.indices.contains(pointIndex),
                  abs(band[pointIndex].windowSeconds - point.windowSeconds) < 0.001
            else { return nil }
            return band[pointIndex]
        }
        let content = VStack(alignment: .leading, spacing: 2) {
            Text("\(point.windowSeconds.formatted(.number.precision(.fractionLength(0...1))))s")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(point.kilograms.formatted(.number.precision(.fractionLength(1)))) kg")
                .font(.subheadline.weight(.semibold).monospacedDigit())
            if let bandPoint {
                Text(confidenceBandText(for: bandPoint))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(ChartToken.tooltip.color(scheme), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ChartToken.tooltipBorder.color(scheme), lineWidth: 1)
        )
        .shadow(radius: 4, y: 2)
        .fixedSize()

        let plotFrame = CGRect(
            x: leadingInset,
            y: topInset,
            width: max(1, size.width - leadingInset - trailingInset),
            height: max(1, size.height - topInset - bottomInset)
        )
        return content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { tooltipSize = geo.size }
                        .onChange(of: geo.size) { newSize in tooltipSize = newSize }
                }
            )
            .position(
                x: clampedTooltipX(x: x, plotFrame: plotFrame, tooltipWidth: tooltipSize.width),
                y: clampedTooltipY(plotFrame: plotFrame, tooltipHeight: tooltipSize.height)
            )
            .zIndex(1)
    }

    private func confidenceBandText(for point: ForceCurveConfidencePoint) -> String {
        let lowKilograms: String = formattedForceKilograms(point.lowKilograms)
        let highKilograms: String = formattedForceKilograms(point.highKilograms)
        return "95% \(lowKilograms)–\(highKilograms) kg"
    }

    private func clampedTooltipX(x: CGFloat, plotFrame: CGRect, tooltipWidth: CGFloat) -> CGFloat {
        let width = tooltipWidth > 0 ? tooltipWidth : 90
        let minCenter = plotFrame.minX + width / 2 + 8
        let maxCenter = plotFrame.maxX - width / 2 - 8
        if minCenter > maxCenter { return plotFrame.midX }
        return min(max(x, minCenter), maxCenter)
    }

    private func clampedTooltipY(plotFrame: CGRect, tooltipHeight: CGFloat) -> CGFloat {
        let height = tooltipHeight > 0 ? tooltipHeight : 60
        let minCenter = plotFrame.minY + height / 2 + 4
        let maxCenter = plotFrame.maxY - height / 2 - 4
        if minCenter > maxCenter { return plotFrame.midY }
        return minCenter
    }
}

private struct ForceCurveAccessibilityDescriptor: AXChartDescriptorRepresentable {
    let model: ForceCurveModel
    let targetBand: ForceTargetBand?

    func makeChartDescriptor() -> AXChartDescriptor { makeDescriptor() }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        let rebuilt = makeDescriptor()
        descriptor.title = rebuilt.title
        descriptor.summary = rebuilt.summary
        descriptor.xAxis = rebuilt.xAxis
        descriptor.yAxis = rebuilt.yAxis
        descriptor.series = rebuilt.series
    }

    private func makeDescriptor() -> AXChartDescriptor {
        let labels = model.points.indices.map { index in
            "\(index + 1): \(model.points[index].windowSeconds.formatted(.number.precision(.fractionLength(0...1))))s"
        }
        let yMax = max(
            1,
            max(
                model.maximumForceKilograms,
                max(model.confidenceBand?.map(\.highKilograms).max() ?? 0, targetBand?.highKilograms ?? 0)
            )
        ) * 1.1
        let points = model.points.enumerated().map { index, point -> AXDataPoint in
            let bandLabel: String
            if let band = model.confidenceBand,
               band.indices.contains(index),
               abs(band[index].windowSeconds - point.windowSeconds) < 0.001
            {
                bandLabel = ", 95% \(band[index].lowKilograms.formatted(.number.precision(.fractionLength(1)))) to \(band[index].highKilograms.formatted(.number.precision(.fractionLength(1)))) kilograms"
            } else {
                bandLabel = ""
            }
            return AXDataPoint(
                x: labels[index],
                y: point.kilograms,
                label: "\(point.windowSeconds.formatted(.number.precision(.fractionLength(0...1)))) seconds, \(point.kilograms.formatted(.number.precision(.fractionLength(1)))) kilograms\(bandLabel)"
            )
        }
        return AXChartDescriptor(
            title: "Force duration curve",
            summary: summary,
            xAxis: AXCategoricalDataAxisDescriptor(title: "Seconds", categoryOrder: labels),
            yAxis: AXNumericDataAxisDescriptor(title: "Kilograms", range: 0...yMax, gridlinePositions: []) {
                "\($0.formatted(.number.precision(.fractionLength(1)))) kg"
            },
            additionalAxes: [],
            series: [AXDataSeriesDescriptor(
                name: "Measured force",
                isContinuous: true,
                dataPoints: points
            )]
        )
    }

    private var summary: String {
        guard let targetBand else {
            return "Measured force-duration curve with the fitted Hill model and 95 percent confidence band."
        }
        let targetKilograms: String = formattedForceKilograms(targetBand.kilograms)
        let lowKilograms: String = formattedForceKilograms(targetBand.lowKilograms)
        let highKilograms: String = formattedForceKilograms(targetBand.highKilograms)
        let targetDescription: String = "Measured force-duration curve with the fitted Hill model, 95 percent confidence band, and a plan target of "
            + "\(targetKilograms) kilograms from "
        let rangeDescription: String = "\(lowKilograms) to \(highKilograms) kilograms."
        return targetDescription + rangeDescription
    }
}

private extension View {
    func accessibilityForceCurveChartDescriptor(
        _ model: ForceCurveModel,
        targetBand: ForceTargetBand?
    ) -> some View {
        accessibilityChartDescriptor(
            ForceCurveAccessibilityDescriptor(model: model, targetBand: targetBand)
        )
    }
}
