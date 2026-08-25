import SendmeterCore
import SwiftUI

/// The horizontal 28-day activity-mix bar (web `ActivityMixBar`). Each segment
/// is a VoiceOver button labelled with its activity + share; the surrounding
/// chart-level scrub surface keeps narrow segments tappable by touch.
///
/// Widths are proportional only (F9): the web deliberately has NO minimum
/// slice — `trainingLoadSheet.test.tsx` asserts a 0.1% share stays `0.1%`
/// without a `min-width` — so a sub-1% sliver renders proportionally, and a
/// floor would make the fixed widths sum past the container, clipping the
/// rightmost activity.
struct ActivityMixBar: View {
    let activities: [ActivityLoad]

    @Environment(\.colorScheme) private var scheme
    @State private var selectedIndex: Int?
    /// Haptic dedupe guard: a scrub can deliver many frames for one segment,
    /// so this tracks the last tick independently of the rendered state.
    @State private var tickedIndex: Int?

    private let tooltipHeight: CGFloat = 48
    private let visualBarHeight = CGFloat(TrainingLoadInteraction.activityMixVisualHeight)
    private let hitTargetHeight = CGFloat(TrainingLoadInteraction.activityMixHitHeight)

    private var description: String {
        activities
            .map { "\($0.label) \(TrainingLoad.formatSharePercent($0.percentage))" }
            .joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if let selectedIndex, let activity = activity(at: selectedIndex) {
                    TrainingLoadTooltip {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(activity.label)
                                .font(.subheadline.weight(.semibold))
                            Text("\(TrainingLoad.formatAU(activity.load)) AU · \(TrainingLoad.formatSharePercent(activity.percentage))")
                                .font(.caption2.monospacedDigit())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: tooltipHeight, alignment: .topLeading)

            GeometryReader { proxy in
                let total = proxy.size.width
                ZStack(alignment: .leading) {
                    visualBar(width: total)

                    HStack(spacing: 0) {
                        ForEach(Array(activities.enumerated()), id: \.offset) { index, activity in
                            Button {
                                toggleSelection(index)
                            } label: {
                                Color.clear
                                    .frame(
                                        width: total * CGFloat(activity.percentage) / 100,
                                        height: hitTargetHeight
                                    )
                            }
                            .hapticButtonStyle(.plain)
                            .frame(
                                width: total * CGFloat(activity.percentage) / 100,
                                height: hitTargetHeight
                            )
                            .accessibilityLabel(activity.label)
                            .accessibilityValue(
                                "\(TrainingLoad.formatAU(activity.load)) AU, \(TrainingLoad.formatSharePercent(activity.percentage))"
                                    + (selectedIndex == index ? ", selected" : "")
                            )
                            .accessibilityHint(selectedIndex == index ? "Double-tap to hide details." : "Double-tap to show details.")
                            .accessibilityAddTraits(selectedIndex == index ? .isSelected : [])
                        }
                    }
                    .frame(width: total, height: hitTargetHeight, alignment: .leading)

                    // A single surface makes a scrub usable even when a
                    // segment is narrower than a fingertip. It is 44pt tall,
                    // while `visualBar` above remains the 10pt painted bar.
                    // The clear layer is not an additional VoiceOver element;
                    // the transparent buttons retain per-activity actions.
                    Color.clear
                        .frame(width: total, height: hitTargetHeight)
                        .contentShape(Rectangle())
                        .hapticTapMuted()
                        .gesture(
                            SpatialTapGesture()
                                .onEnded { value in
                                    guard let index = index(at: value.location.x, width: total) else { return }
                                    toggleSelection(index)
                                }
                        )
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 12)
                                .onChanged { value in
                                    if let index = index(at: value.location.x, width: total) {
                                        select(index)
                                    }
                                }
                        )
                        .accessibilityHidden(true)
                }
                .frame(width: total, height: hitTargetHeight, alignment: .leading)
            }
            .frame(height: hitTargetHeight)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity mix: \(description)")
        .onChange(of: activities) { _ in
            // A changed data snapshot must not produce a selection tick.
            selectedIndex = nil
            tickedIndex = nil
        }
        .onDisappear {
            selectedIndex = nil
            tickedIndex = nil
        }
    }

    private func activity(at index: Int) -> ActivityLoad? {
        guard activities.indices.contains(index) else { return nil }
        return activities[index]
    }

    private func visualBar(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(activities.enumerated()), id: \.offset) { index, activity in
                RoundedRectangle(cornerRadius: 0, style: .continuous)
                    .fill(ChartActivityHue.color(forActivityID: activity.type, scheme: scheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: 0, style: .continuous)
                            .stroke(index == selectedIndex ? Color.primary : .clear, lineWidth: 1.5)
                    )
                    .opacity(selectedIndex == nil || selectedIndex == index ? 1 : 0.5)
                    .frame(
                        width: width * CGFloat(activity.percentage) / 100,
                        height: visualBarHeight
                    )
            }
        }
        .frame(width: width, height: visualBarHeight, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemFill),
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func index(at x: CGFloat, width: CGFloat) -> Int? {
        TrainingLoadInteraction.activityMixIndex(
            x: Double(x),
            width: Double(width),
            percentages: activities.map(\.percentage)
        )
    }

    private func select(_ index: Int) {
        guard activities.indices.contains(index) else { return }
        setSelection(index)
    }

    private func toggleSelection(_ index: Int) {
        guard activities.indices.contains(index) else { return }
        setSelection(
            TrainingLoadInteraction.toggledSelection(current: tickedIndex, candidate: index)
        )
    }

    private func setSelection(_ index: Int?) {
        if SelectionHaptics.valueChanged(tickedIndex, index) {
            tickedIndex = index
            Haptics.shared.playGesture(.selection)
        }
        selectedIndex = index
    }
}
