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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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

                    curveMetricRow(model)
                        .font(.caption.monospacedDigit())

                    legendRow(hasConfidenceBand: hasConfidenceBand)
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

    /// #928: the three curve metrics read side by side at normal text sizes
    /// and one per line at accessibility sizes — three 40 pt metrics cannot
    /// fit a 375 pt card without splitting mid-number.
    @ViewBuilder
    private func curveMetricRow(_ model: ForceCurveModel) -> some View {
        let metrics: [(label: String, value: Double?, unit: String)] = [
            ("Max", model.maximumForceKilograms, "kg"),
            ("CF", model.criticalForceKilograms, "kg"),
            ("W′", model.impulseAboveCriticalForceKilogramSeconds, "kg·s")
        ]
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                metricEntries(metrics)
            }
        } else {
            HStack(spacing: 12) {
                metricEntries(metrics)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func metricEntries(_ metrics: [(label: String, value: Double?, unit: String)]) -> some View {
        ForEach(metrics.indices, id: \.self) { index in
            curveMetric(
                metrics[index].label,
                value: metrics[index].value,
                unit: metrics[index].unit
            )
        }
    }

    /// #928: the legend reads as one row at normal text sizes and one entry
    /// per line at accessibility sizes — a 40 pt "Plan target" hyphenates into
    /// a three-line column otherwise.
    @ViewBuilder
    private func legendRow(hasConfidenceBand: Bool) -> some View {
        let entries = legendEntries(hasConfidenceBand: hasConfidenceBand)
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                legendEntries(entries)
            }
        } else {
            HStack(spacing: 6) {
                legendEntries(entries)
            }
        }
    }

    @ViewBuilder
    private func legendEntries(_ entries: [LegendEntry]) -> some View {
        ForEach(entries.indices, id: \.self) { index in
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(entries[index].color.opacity(entries[index].opacity))
                    .frame(width: 10, height: entries[index].height)
                Text(entries[index].label)
            }
        }
    }

    private struct LegendEntry {
        let color: Color
        let opacity: Double
        let height: CGFloat
        let label: String
    }

    private func legendEntries(hasConfidenceBand: Bool) -> [LegendEntry] {
        var entries: [LegendEntry] = [
            LegendEntry(color: ChartToken.force.color(scheme), opacity: 1, height: 3, label: "Hill fit")
        ]
        if hasConfidenceBand {
            entries.append(
                LegendEntry(
                    color: ChartToken.force.color(scheme),
                    opacity: 0.18,
                    height: 8,
                    label: "95% band"
                )
            )
        }
        if targetBand != nil {
            entries.append(
                LegendEntry(
                    color: ChartToken.optimal.color(scheme),
                    opacity: 0.8,
                    height: 3,
                    label: "Plan target"
                )
            )
        }
        return entries
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

    /// #928: the one resolved axis-label size. Seeded with the shared rule's
    /// `caption2` base so the Canvas draws exactly the size the density and
    /// inset math measures — a Canvas cannot lay text out, so this single
    /// number feeds both the drawn glyphs and the rule.
    @ScaledMetric(relativeTo: .caption2)
    private var axisLabelPointSize: CGFloat = ChartAxisLabelRule.basePointSize

    /// The log-x window and y-maximum this plot draws with — the shared Core
    /// geometry (#928), unchanged from the formulas the Canvas used inline.
    private var geometry: ForceCurvePlotGeometry? {
        guard !model.points.isEmpty else { return nil }
        return ForceCurvePlotGeometry(model: model, targetBand: targetBand)
    }

    /// The duration ticks the log window admits, in seconds.
    private var tickCandidates: [Double] {
        guard let geometry else { return [] }
        return [1.0, 10.0, 60.0, 120.0].filter {
            $0 >= geometry.minimumSeconds && $0 <= geometry.maximumSeconds
        }
    }

    private func tickLabel(_ seconds: Double) -> String {
        "\(seconds.formatted(.number.precision(.fractionLength(0))))s"
    }

    /// The y value drawn on gridline `index` (0 = top), as the Canvas had it.
    private func yTickValue(index: Int) -> Double {
        (geometry?.maximumValue ?? 0) * Double(2 - index) / 2
    }

    private func yTickLabel(index: Int) -> String {
        yTickValue(index: index).formatted(.number.precision(.fractionLength(0)))
    }

    /// The shared rule's insets for this plot at the resolved label size.
    private var axisInsets: ChartAxisLabelRule.Insets {
        ChartAxisLabelRule.insets(
            yLabels: (0...2).map { yTickLabel(index: $0) },
            xLabels: tickCandidates.map { tickLabel($0) },
            pointSize: axisLabelPointSize
        )
    }

    private var topInset: CGFloat { axisInsets.top }
    private var bottomInset: CGFloat { axisInsets.bottom }
    private var leadingInset: CGFloat { axisInsets.leading }
    private var trailingInset: CGFloat { axisInsets.trailing }

    /// The Canvas label font: the resolved `caption2` size with monospaced
    /// digits, matching `ChartAxisLabelRule.font`.
    private var axisLabelFont: Font {
        .system(size: axisLabelPointSize).monospacedDigit()
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
            guard let geometry else { return }
            // One evaluation of the shared rule's insets per draw pass.
            let insets = axisInsets
            let plotWidth = size.width - insets.leading - insets.trailing
            let plotHeight = size.height - insets.top - insets.bottom
            guard plotWidth > 0, plotHeight > 0 else { return }

            func x(_ seconds: Double) -> CGFloat {
                insets.leading + CGFloat(geometry.xFraction(seconds: seconds)) * plotWidth
            }

            func y(_ kilograms: Double) -> CGFloat {
                insets.top + plotHeight
                    - CGFloat(geometry.yFraction(kilograms: kilograms)) * plotHeight
            }

            let gridColor = ChartToken.grid.color(scheme)
            let axisColor = ChartToken.axis.color(scheme)
            let forceColor = ChartToken.force.color(scheme)
            let secondaryColor = ChartToken.forceSecondary.color(scheme)
            let targetColor = ChartToken.optimal.color(scheme)

            for index in 0...2 {
                let lineY = insets.top + plotHeight * CGFloat(index) / 2
                var grid = Path()
                grid.move(to: CGPoint(x: insets.leading, y: lineY))
                grid.addLine(to: CGPoint(x: size.width - insets.trailing, y: lineY))
                context.stroke(grid, with: .color(gridColor), lineWidth: 1)

                let value = yTickValue(index: index)
                context.draw(
                    Text(value.formatted(.number.precision(.fractionLength(0))))
                        .font(axisLabelFont)
                        .foregroundColor(axisColor),
                    at: CGPoint(x: insets.leading / 2, y: lineY),
                    anchor: .center
                )
            }

            if let targetBand {
                let upperY = y(targetBand.highKilograms)
                let lowerY = y(targetBand.lowKilograms)
                context.fill(
                    Path(CGRect(
                        x: insets.leading,
                        y: upperY,
                        width: plotWidth,
                        height: max(1, lowerY - upperY)
                    )),
                    with: .color(targetColor.opacity(ChartToken.optimal.bandOpacity(scheme)))
                )

                var targetPath = Path()
                targetPath.move(to: CGPoint(x: insets.leading, y: y(targetBand.kilograms)))
                targetPath.addLine(
                    to: CGPoint(x: size.width - insets.trailing, y: y(targetBand.kilograms))
                )
                context.stroke(
                    targetPath,
                    with: .color(targetColor.opacity(0.85)),
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                )
            }

            // #928: every admitted tick keeps its gridline; the labels follow
            // the shared rule's tick-density adaptation, so a label that grew
            // with Dynamic Type can never collide with its neighbour.
            let tickSeconds = tickCandidates
            let tickPositions = tickSeconds.map(x)
            let labelledTicks = Set(
                ChartAxisLabelRule.visibleTickIndices(
                    labels: tickSeconds.map(tickLabel),
                    positions: tickPositions,
                    pointSize: axisLabelPointSize
                )
            )
            for (index, _) in tickSeconds.enumerated() {
                let lineX = tickPositions[index]
                var grid = Path()
                grid.move(to: CGPoint(x: lineX, y: insets.top))
                grid.addLine(to: CGPoint(x: lineX, y: insets.top + plotHeight))
                context.stroke(grid, with: .color(gridColor), lineWidth: 1)
                guard labelledTicks.contains(index) else { continue }
                context.draw(
                    Text(tickLabel(tickSeconds[index]))
                        .font(axisLabelFont)
                        .foregroundColor(axisColor),
                    at: CGPoint(x: lineX, y: size.height - insets.bottom / 2),
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
              let geometry,
              location.x >= leadingInset,
              location.x <= size.width - trailingInset
        else { return nil }
        let fraction = Double((location.x - leadingInset) / plotWidth)
        guard let seconds = ForceCurveSelection.seconds(
            atXFraction: fraction,
            firstSeconds: geometry.minimumSeconds,
            lastSeconds: geometry.maximumSeconds
        ) else { return nil }
        return ForceCurveSelection.nearestPointIndex(points: model.points, toSeconds: seconds)
    }

    private func x(for seconds: Double, size: CGSize) -> CGFloat {
        guard let geometry else { return leadingInset }
        let plotWidth = max(1, size.width - leadingInset - trailingInset)
        let fraction = ForceCurveSelection.xFraction(
            forSeconds: seconds,
            firstSeconds: geometry.minimumSeconds,
            lastSeconds: geometry.maximumSeconds
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
                x: ForceCurveTooltipPlacement.x(
                    anchor: x,
                    plotFrame: plotFrame,
                    tooltipWidth: tooltipSize.width
                ),
                y: ForceCurveTooltipPlacement.y(
                    plotFrame: plotFrame,
                    tooltipHeight: tooltipSize.height
                )
            )
            .zIndex(1)
    }

    private func confidenceBandText(for point: ForceCurveConfidencePoint) -> String {
        let lowKilograms: String = formattedForceKilograms(point.lowKilograms)
        let highKilograms: String = formattedForceKilograms(point.highKilograms)
        return "95% \(lowKilograms)–\(highKilograms) kg"
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
