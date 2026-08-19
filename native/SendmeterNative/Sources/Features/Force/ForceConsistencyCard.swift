import SendmeterCore
import SwiftUI

/// Force consistency (#654): distinct force-training days in eight rolling
/// seven-day windows. Tag chips filter the same bars; they never stack tag
/// counts, because two exercises trained on one day are still one day overall.
struct ForceConsistencyCard: View {
    let recordings: [TindeqRecording]
    let hiddenTags: Set<String>

    @Environment(\.colorScheme) private var scheme
    @State private var selectedTag: String?
    /// Freeze the reference day for this card mount so rendering stays pure;
    /// the model data remains the source of truth for subsequent refreshes.
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
        .onChange(of: data.tags) { tags in
            // A realtime refresh can hide a selected tag or age it out of the
            // window. Clear the state as well as deriving the visual fallback,
            // so a later refresh cannot unexpectedly reactivate the old tag.
            if let selectedTag, !tags.contains(selectedTag) {
                self.selectedTag = nil
            }
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
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func consistencyBars(
        _ weeks: [TindeqConsistency.Week],
        selectedTag: String?
    ) -> some View {
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
        .frame(height: 108)
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
