import Charts
import SendmeterCore
import SwiftUI

/// Force consistency (#654): distinct force-training days in eight rolling
/// seven-day windows. Tag chips filter the same bars; they never stack tag
/// counts, because two exercises trained on one day are still one day overall.
struct ForceConsistencyCard: View {
    let recordings: [TindeqRecording]
    let hiddenTags: Set<String>
    let hasLoadedRecordings: Bool

    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTag: String?
    @State private var selectedWindowIndex: Int?
    @State private var tickedWindowIndex: Int?
    @State private var tooltipSize: CGSize = .zero
    /// Keep one reference date for a render pass, but advance it when the
    /// local calendar day changes or the app becomes active again. A card can
    /// remain mounted across both events, and a recording saved after
    /// midnight must not be classified as future just because the view was
    /// mounted yesterday.
    @State private var now = Date()

    private var snapshot: TindeqConsistency.Snapshot {
        TindeqConsistency.compute(
            recordings: recordings,
            hiddenTags: hiddenTags,
            now: now,
            timeZone: .current
        )
    }

    var body: some View {
        let data = snapshot
        let activeTag = TindeqConsistency.effectiveSelectedTag(
            selectedTag,
            availableTags: data.tags
        )

        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Force consistency", systemImage: "chart.bar.fill")

                if !hasLoadedRecordings {
                    Text("Your force history is still loading.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    if !data.tags.isEmpty {
                        tagChips(data.tags, activeTag: activeTag)
                    }

                    if !data.hasRecordings {
                        Text("No force recordings in the last 8 weeks")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        consistencyBars(data.weeks, selectedTag: activeTag)
                    }
                }
            }
        }
        .onChange(of: data.tags) { tags in
            // A realtime refresh can hide a selected tag or age it out of the
            // window. Clear the state as well as deriving the visual fallback,
            // so a later refresh cannot unexpectedly reactivate the old tag.
            if let selectedTag, !tags.contains(selectedTag) {
                self.selectedTag = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            now = Date()
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            now = Date()
        }
        .onAppear {
            now = Date()
        }
        .onDisappear {
            selectedWindowIndex = nil
            tickedWindowIndex = nil
        }
    }

    @ViewBuilder
    private func tagChips(_ tags: [String], activeTag: String?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                consistencyChip("All", isActive: activeTag == nil) {
                    selectedTag = nil
                }
                ForEach(tags, id: \.self) { tag in
                    consistencyChip(tag, isActive: activeTag == tag) {
                        selectedTag = tag
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter force consistency by exercise")
    }

    private func consistencyChip(
        _ title: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(isActive ? ChartToken.force.color(scheme) : .primary)
                .background(
                    isActive
                        ? ChartToken.force.color(scheme).opacity(0.14)
                        : Color(uiColor: .secondarySystemFill),
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .stroke(
                            isActive
                                ? ChartToken.force.color(scheme).opacity(0.35)
                                : Color.primary.opacity(0.08),
                            lineWidth: 1
                        )
                )
        }
        .hapticButtonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func consistencyBars(
        _ weeks: [TindeqConsistency.Week],
        selectedTag: String?
    ) -> some View {
        ZStack(alignment: .topLeading) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                    let days = TindeqConsistency.selectedTagDays(
                        for: week,
                        selectedTag: selectedTag
                    )
                    VStack(spacing: 4) {
                        Text("\(days)")
                            .font(.system(size: 9).weight(.semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(barGradient(isCurrent: index == weeks.count - 1))
                            .frame(
                                height: max(
                                    CGFloat(days) / CGFloat(TindeqConsistency.daysPerWindow)
                                        * CGFloat(TindeqConsistency.barHeight),
                                    2
                                )
                            )

                        Text(week.label)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "\(week.label): \(days) \(days == 1 ? "day" : "days") trained"
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
                                    let index = windowIndex(
                                        at: value.location,
                                        width: geo.size.width,
                                        count: weeks.count
                                    )
                                    select(index == selectedWindowIndex ? nil : index)
                                }
                        )
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 10)
                                .onChanged { value in
                                    select(
                                        windowIndex(
                                            at: value.location,
                                            width: geo.size.width,
                                            count: weeks.count
                                        )
                                    )
                                }
                        )
                        .accessibilityHidden(true)
                }

                if let selectedWindowIndex,
                   weeks.indices.contains(selectedWindowIndex) {
                    let week = weeks[selectedWindowIndex]
                    let days = TindeqConsistency.selectedTagDays(
                        for: week,
                        selectedTag: selectedTag
                    )
                    tooltip(
                        week: week,
                        days: days,
                        x: windowCenterX(
                            index: selectedWindowIndex,
                            width: geo.size.width,
                            count: weeks.count
                        ),
                        containerSize: geo.size
                    )
                }
            }
        }
        .frame(height: 108)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Force consistency across eight seven-day windows")
        .accessibilityValue(accessibilityValue(weeks: weeks, selectedTag: selectedTag))
        .accessibilityForceConsistencyChartDescriptor(weeks, selectedTag: selectedTag)
    }

    private func select(_ index: Int?) {
        if SelectionHaptics.valueChanged(tickedWindowIndex, index) {
            tickedWindowIndex = index
            Haptics.shared.playGesture(.selection)
        }
        selectedWindowIndex = index
    }

    private func windowIndex(at point: CGPoint, width: CGFloat, count: Int) -> Int? {
        guard count > 0, width > 0 else { return nil }
        let spacing: CGFloat = 6
        let bandWidth = (width - spacing * CGFloat(count - 1)) / CGFloat(count)
        return (0..<count).min { lhs, rhs in
            abs(point.x - windowCenterX(index: lhs, bandWidth: bandWidth, count: count))
                < abs(point.x - windowCenterX(index: rhs, bandWidth: bandWidth, count: count))
        }
    }

    private func windowCenterX(index: Int, width: CGFloat, count: Int) -> CGFloat {
        let spacing: CGFloat = 6
        let bandWidth = (width - spacing * CGFloat(count - 1)) / CGFloat(count)
        return windowCenterX(index: index, bandWidth: bandWidth, count: count)
    }

    private func windowCenterX(index: Int, bandWidth: CGFloat, count: Int) -> CGFloat {
        let spacing: CGFloat = 6
        return CGFloat(index) * (bandWidth + spacing) + bandWidth / 2
    }

    private func tooltip(
        week: TindeqConsistency.Week,
        days: Int,
        x: CGFloat,
        containerSize: CGSize
    ) -> some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(week.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(days) \(days == 1 ? "day" : "days") trained")
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .padding(8)
        .background(ChartToken.tooltip.color(scheme), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ChartToken.tooltipBorder.color(scheme), lineWidth: 1)
        )
        .shadow(radius: 4, y: 2)
        .fixedSize()

        let plotFrame = CGRect(origin: .zero, size: containerSize)
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

    private func accessibilityValue(
        weeks: [TindeqConsistency.Week],
        selectedTag: String?
    ) -> String {
        guard let selectedWindowIndex,
              weeks.indices.contains(selectedWindowIndex)
        else {
            let total = weeks.reduce(0) { $0 + $1.days }
            return "\(total) distinct training days across eight windows"
        }
        let week = weeks[selectedWindowIndex]
        let days = TindeqConsistency.selectedTagDays(for: week, selectedTag: selectedTag)
        return "Selected \(week.label): \(days) \(days == 1 ? "day" : "days") trained"
    }

    private func barGradient(isCurrent: Bool) -> LinearGradient {
        let token: ChartToken = isCurrent ? .optimal : .forceSecondary
        let color = token.color(scheme)
        return LinearGradient(
            colors: [color.opacity(0.58), color],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct ForceConsistencyAccessibilityDescriptor: AXChartDescriptorRepresentable {
    let weeks: [TindeqConsistency.Week]
    let selectedTag: String?

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
        let points = weeks.map { week -> AXDataPoint in
            let days = TindeqConsistency.selectedTagDays(for: week, selectedTag: selectedTag)
            return AXDataPoint(
                x: week.label,
                y: Double(days),
                label: "\(week.label): \(days) \(days == 1 ? "day" : "days") trained"
            )
        }
        return AXChartDescriptor(
            title: "Force consistency",
            summary: "Distinct force-training days in each rolling seven-day window.",
            xAxis: AXCategoricalDataAxisDescriptor(
                title: "Window",
                categoryOrder: weeks.map(\.label)
            ),
            yAxis: AXNumericDataAxisDescriptor(
                title: "Days trained",
                range: 0...Double(TindeqConsistency.daysPerWindow),
                gridlinePositions: []
            ) { "\(Int($0))" },
            additionalAxes: [],
            series: [AXDataSeriesDescriptor(
                name: "Distinct training days",
                isContinuous: false,
                dataPoints: points
            )]
        )
    }
}

private extension View {
    func accessibilityForceConsistencyChartDescriptor(
        _ weeks: [TindeqConsistency.Week],
        selectedTag: String?
    ) -> some View {
        accessibilityChartDescriptor(
            ForceConsistencyAccessibilityDescriptor(
                weeks: weeks,
                selectedTag: selectedTag
            )
        )
    }
}
