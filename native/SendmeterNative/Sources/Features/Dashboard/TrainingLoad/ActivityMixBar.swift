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

    private var description: String {
        activities
            .map { "\($0.label) \(TrainingLoad.formatSharePercent($0.percentage))" }
            .joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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

            GeometryReader { proxy in
                let total = proxy.size.width
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(Array(activities.enumerated()), id: \.offset) { index, activity in
                            Button {
                                toggleSelection(index)
                            } label: {
                                RoundedRectangle(cornerRadius: 0, style: .continuous)
                                    .fill(ChartActivityHue.color(forActivityID: activity.type, scheme: scheme))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 0, style: .continuous)
                                            .stroke(index == selectedIndex ? Color.primary : .clear, lineWidth: 1.5)
                                    )
                            }
                            .buttonStyle(.plain)
                            .frame(width: total * CGFloat(activity.percentage) / 100)
                            .opacity(selectedIndex == nil || selectedIndex == index ? 1 : 0.5)
                            .accessibilityLabel(activity.label)
                            .accessibilityValue(
                                "\(TrainingLoad.formatAU(activity.load)) AU, \(TrainingLoad.formatSharePercent(activity.percentage))"
                                    + (selectedIndex == index ? ", selected" : "")
                            )
                            .accessibilityHint(selectedIndex == index ? "Double-tap to hide details." : "Double-tap to show details.")
                            .accessibilityAddTraits(selectedIndex == index ? .isSelected : [])
                        }
                    }
                    .frame(width: total, alignment: .leading)

                    // A single surface makes a scrub usable even when a
                    // segment is narrower than a fingertip. The clear layer
                    // is not an additional VoiceOver element; the buttons
                    // beneath retain the per-activity labels and actions.
                    Color.clear
                        .contentShape(Rectangle())
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
                .frame(width: total, height: 10, alignment: .leading)
                .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .frame(height: 10)
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

    private func index(at x: CGFloat, width: CGFloat) -> Int? {
        guard !activities.isEmpty, width > 0 else { return nil }
        let position = max(0, min(x, width))
        var start: CGFloat = 0
        for (index, activity) in activities.enumerated() {
            let segmentWidth = width * CGFloat(activity.percentage) / 100
            if position < start + segmentWidth || index == activities.count - 1 {
                return index
            }
            start += segmentWidth
        }
        return nil
    }

    private func select(_ index: Int) {
        guard activities.indices.contains(index) else { return }
        setSelection(index)
    }

    private func toggleSelection(_ index: Int) {
        guard activities.indices.contains(index) else { return }
        setSelection(tickedIndex == index ? nil : index)
    }

    private func setSelection(_ index: Int?) {
        if SelectionHaptics.valueChanged(tickedIndex, index) {
            tickedIndex = index
            Haptics.shared.play(.selection)
        }
        selectedIndex = index
    }
}
