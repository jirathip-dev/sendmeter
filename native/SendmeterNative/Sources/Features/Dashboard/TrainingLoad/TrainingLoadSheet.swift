import SendmeterCore
import SwiftUI

/// The training-load sheet: weekly bars (same `WeeklyLoad` array the card
/// behind it shows), the 53×7 daily heatmap, and the 28-day activity mix.
/// Port of the web `TrainingLoadSheet.tsx` (#650). Pure math lives in
/// `Sources/Core/TrainingLoad.swift`; this file is thin layout only.
///
/// Snapshotting (F2/F10): `mix`, `daily` and the week-delta are computed once
/// per data/date change into `@State`, never per body pass — the original
/// recomputed `activityMix` up to 4× per pass. One `referenceDate` drives both
/// the 28-day mix and the heatmap so the two windows advance together across
/// midnight (`.NSCalendarDayChanged`).
struct TrainingLoadSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var mix: ActivityMix = ActivityMix(total: 0, activities: [])
    @State private var daily: [String: DailyLoad] = [:]
    @State private var currentDelta: WeekDelta?
    @State private var referenceDate = Date()

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
        .onAppear { rebuild() }
        .onChange(of: model.sessions) { _ in rebuild() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            referenceDate = Date()
            rebuild()
        }
    }

    private func rebuild() {
        mix = TrainingLoad.activityMix(
            sessions: model.sessions,
            endDate: LocalDateSupport.string(from: referenceDate)
        )
        daily = TrainingLoad.dailyLoads(sessions: model.sessions)
        let weeks = model.weeklyLoads
        guard weeks.count >= 2 else { currentDelta = nil; return }
        currentDelta = TrainingLoad.weekDelta(
            current: weeks[weeks.count - 1].total,
            previous: weeks[weeks.count - 2].total
        )
    }

    // MARK: - Weekly load

    private var weeklyLoadSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("Weekly load", systemImage: "chart.bar.fill")
                    Spacer()
                    if let delta = currentDelta {
                        Text(deltaLabel(delta))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(deltaColor(delta))
                    }
                }
                WeeklyBarsView(weeks: model.weeklyLoads)
            }
        }
    }

    private func deltaLabel(_ delta: WeekDelta) -> String {
        let pct = Int(abs(delta.pct).rounded())
        return "\(delta.arrow) \(pct)% vs prior wk"
    }

    /// #649 rule: chart views never read `SendmeterStyle.*` (static, no
    /// appearance switch). The up/down stops are ChartToken semantics; they
    /// are NOT a hex-for-hex match of the web's `--success`/`--danger`
    /// (those are `#1674BE`/`#B95122`) — the chart palette is the right call
    /// under #649 even though the exact hues differ (N5).
    private func deltaColor(_ delta: WeekDelta) -> Color {
        if delta.isFlat { return .secondary }
        return delta.isUp
            ? ChartToken.optimal.color(scheme)
            : ChartToken.alert.color(scheme)
    }

    // MARK: - Daily load

    private var dailyLoadSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Daily load", systemImage: "square.grid.3x3.fill")
                ContributionHeatmapView(daily: daily, today: referenceDate)
            }
        }
    }

    // MARK: - Activity mix

    private var activityMixSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Activity mix", systemImage: "chart.pie.fill")
                Text("Last 28 days · \(TrainingLoad.formatAU(mix.total)) AU")
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
                            Text("\(TrainingLoad.formatAU(activity.load)) AU · \(TrainingLoad.formatSharePercent(activity.percentage))")
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
                    Text(TrainingLoad.formatAU(week.total))
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
                .accessibilityLabel("\(week.label): \(TrainingLoad.formatAU(week.total)) AU")
            }
        }
        .frame(height: 108)
    }

    @Environment(\.colorScheme) private var scheme
}
