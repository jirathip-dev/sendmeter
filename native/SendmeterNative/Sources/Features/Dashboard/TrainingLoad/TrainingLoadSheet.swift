import SendmeterCore
import SwiftUI

/// The training-load sheet: weekly bars (same `WeeklyLoad` array the card
/// behind it shows), the 53×7 daily heatmap, and the 28-day activity mix.
/// Port of the web `TrainingLoadSheet.tsx` (#650). Pure math lives in
/// `Sources/Core/TrainingLoad.swift`; this file is thin layout only.
struct TrainingLoadSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private var mix: ActivityMix {
        TrainingLoad.activityMix(
            sessions: model.sessions,
            endDate: LocalDateSupport.string(from: Date())
        )
    }

    private var daily: [String: TrainingLoad.DailyLoad] {
        TrainingLoad.dailyLoads(sessions: model.sessions)
    }

    private var currentDelta: TrainingLoad.WeekDelta? {
        let weeks = model.weeklyLoads
        guard weeks.count >= 2 else { return nil }
        return TrainingLoad.weekDelta(
            current: weeks[weeks.count - 1].total,
            previous: weeks[weeks.count - 2].total
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    weeklyLoadSection
                    dailyLoadSection
                    activityMixSection
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Training Load")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Weekly load

    private var weeklyLoadSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("Weekly load", systemImage: "chart.bar.fill")
                    Spacer()
                    if let delta = currentDelta, let label = deltaLabel(delta) {
                        Text(label)
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(deltaColor(delta))
                    }
                }
                WeeklyBarsView(weeks: model.weeklyLoads)
            }
        }
    }

    private func deltaLabel(_ delta: TrainingLoad.WeekDelta) -> String? {
        let pct = Int(abs(delta.pct).rounded())
        return "\(delta.arrow) \(pct)% vs prior wk"
    }

    private func deltaColor(_ delta: TrainingLoad.WeekDelta) -> Color {
        if delta.isFlat { return .secondary }
        return delta.isUp ? SendmeterStyle.optimal : SendmeterStyle.alert
    }

    // MARK: - Daily load

    private var dailyLoadSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Daily load", systemImage: "square.grid.3x3.fill")
                ContributionHeatmapView(daily: daily)
            }
        }
    }

    // MARK: - Activity mix

    private var activityMixSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Activity mix", systemImage: "chart.pie.fill")
                Text("Last 28 days · \(Int(mix.total)) AU")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if mix.activities.isEmpty {
                    Text("No training load in the last 28 days. Log a session to see how your activities contribute.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                } else {
                    ActivityMixBar(activities: mix.activities)
                    ForEach(mix.activities, id: \.type) { activity in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(ChartActivityHue.color(forActivityID: activity.type, scheme: scheme))
                                .frame(width: 9, height: 9)
                            Text(activity.label)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Text("\(Int(activity.load)) AU · \(TrainingLoad.formatSharePercent(activity.percentage))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}

/// Weekly bars with per-week totals + labels — the same `WeeklyLoad` array the
/// LoadCard uses, not a recomputed one (#650 acceptance 1).
private struct WeeklyBarsView: View {
    let weeks: [WeeklyLoad]

    private var maxW: Double { max(weeks.map(\.total).max() ?? 0, 1) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                VStack(spacing: 4) {
                    Text("\(Int(week.total))")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: index == weeks.count - 1
                                    ? [ChartToken.optimal.color(scheme).opacity(0.58), ChartToken.optimal.color(scheme)]
                                    : [ChartToken.load.color(scheme).opacity(0.58), ChartToken.load.color(scheme)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(height: max((week.total / maxW) * 64, 2))
                    Text(week.label)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(week.label): \(Int(week.total)) AU")
            }
        }
        .frame(height: 108)
    }

    @Environment(\.colorScheme) private var scheme
}

/// The horizontal 28-day activity-mix bar (web `ActivityMixBar`), plus the
/// swatch list rows rendered by the parent.
private struct ActivityMixBar: View {
    let activities: [ActivityLoad]

    @Environment(\.colorScheme) private var scheme

    private var description: String {
        activities
            .map { "\($0.label) \(TrainingLoad.formatSharePercent($0.percentage))" }
            .joined(separator: ", ")
    }

    var body: some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            HStack(spacing: 0) {
                ForEach(activities, id: \.type) { activity in
                    RoundedRectangle(cornerRadius: 0, style: .continuous)
                        .fill(ChartActivityHue.color(forActivityID: activity.type, scheme: scheme))
                        .frame(width: max(total * CGFloat(activity.percentage) / 100, activity.percentage > 0 ? 1.5 : 0))
                }
            }
            .frame(width: total, alignment: .leading)
        }
        .frame(height: 10)
        .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Activity mix: \(description)")
    }
}
