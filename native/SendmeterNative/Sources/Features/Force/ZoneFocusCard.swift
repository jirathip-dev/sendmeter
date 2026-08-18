import SendmeterCore
import SwiftUI

/// Training-balance card (#653) — port of the web's `ZoneFocusCard.tsx`
/// (SL-100, #182): four horizontal bars showing how many duration-normalised
/// sets in the last 4 weeks you trained each quality on THIS exercise, plus a
/// "FOCUS NEXT" recommendation — the least-trained zone, with the force curve
/// breaking near-ties.
///
/// Tapping the recommendation arms that zone's guided protocol for the active
/// tag (same path the web's TargetZonesCard → ForceView pick uses); tapping
/// the card body opens the detail sheet that shows every number's arithmetic
/// (#214). Both actions are delegated — the card stays pure.
struct ZoneFocusCard: View {
    @Environment(\.colorScheme) private var scheme

    /// Recordings for the active exercise, already tag-filtered by ForceView
    /// (both sides — the web's `recordings.filter((r) => r.tag === tag)`).
    let recordings: [TindeqRecording]
    /// The exercise those recordings are filtered to — named on the card,
    /// because "Training balance" alone reads as *your* balance when it is one
    /// exercise's (#214).
    let exercise: String
    /// The force-curve signal for the recommendation's tie-break, or nil when
    /// no fit exists (the least-trained zone stands on its own).
    let curveInput: ZoneCurveInput?
    /// Arm the recommended zone on the gauge + guided timer.
    let onPick: (ZoneQuality) -> Void
    /// #298 round 6 (finding A1): ForceView locks the gauge inputs for the
    /// whole duration of a run — arming a different zone mid-run must not be
    /// reachable any more than the target-zone chips are.
    let locked: Bool

    @State private var detailOpen = false
    /// `Date()` is impure in render — freeze it once for this mount.
    @State private var now = Date()

    private static let windowDays = 28

    private var sets: [ZoneQuality: Double] {
        ZoneMix.zoneTrainingSets(recordings, now: now, windowDays: Self.windowDays)
    }

    private var recommendation: ZoneRecommendation? {
        ZoneMix.recommendZone(sets: sets, model: curveInput)
    }

    private var maxSets: Double {
        max(1, ZoneQuality.allCases.map { sets[$0] ?? 0 }.max() ?? 0)
    }

    var body: some View {
        // The web hides the whole card when `recommendZone` returns nil — no
        // classifiable training in the 28-day window, so no recommendation
        // exists to show and no fabricated one should be invented from thin
        // data (`if (!rec) return null` in ZoneFocusCard.tsx).
        if let recommendation {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    // The chart region — tapping it opens the detail sheet. Kept
                    // as its own tap surface so the Focus Next button below can't
                    // double-fire (web `stopPropagation` on the button).
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            SectionLabel("Training balance · \(exercise)")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text("Last 4 weeks · this exercise only · sets, not sessions")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        bars
                    }
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Training balance for \(exercise), last four weeks")
                    .accessibilityHint("Opens the training balance detail")
                    .onTapGesture { detailOpen = true }

                    FocusNextButton(
                        recommendation: recommendation,
                        exercise: exercise,
                        disabled: locked,
                        arm: { onPick(recommendation.zone) }
                    )
                }
            }
            .sheet(isPresented: $detailOpen) {
                TrainingBalanceDetailView(
                    recordings: recordings,
                    exercise: exercise,
                    now: now,
                    windowDays: Self.windowDays,
                    sets: sets,
                    recommendation: recommendation,
                    curveInput: curveInput
                )
            }
        }
    }

    /// Four horizontal duration-normalised set bars, each labelled with its
    /// zone and its set count.
    private var bars: some View {
        VStack(spacing: 5) {
            ForEach(ZoneQuality.allCases, id: \.self) { zone in
                barRow(for: zone)
            }
        }
    }

    private func barRow(for zone: ZoneQuality) -> some View {
        let sets = sets[zone] ?? 0
        let rounded = (sets * 10).rounded() / 10
        let color = ChartToken.zoneQuality(zone).color(scheme)
        return HStack(spacing: 8) {
            Text(zone.label)
                .font(.caption)
                .foregroundStyle(.primary)
                .frame(width: 74, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.6), color],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * CGFloat(sets / maxSets))
                }
            }
            .frame(height: 8)
            Text("\(fmt1(sets)) set\(rounded == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(zone.label): \(fmt1(sets)) set\(rounded == 1 ? "" : "s")")
    }
}

/// The Focus Next recommendation — the one tap target that arms the zone.
private struct FocusNextButton: View {
    @Environment(\.colorScheme) private var scheme
    let recommendation: ZoneRecommendation
    let exercise: String
    let disabled: Bool
    let arm: () -> Void

    var body: some View {
        let color = ChartToken.zoneQuality(recommendation.zone).color(scheme)
        Button(action: arm) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("FOCUS NEXT")
                        .font(.caption2.weight(.semibold))
                        .tracking(1)
                        .foregroundStyle(color)
                    Text(recommendation.zone.label)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(recommendation.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Text("Arm ›")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(color.opacity(0.28), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel("Focus next: \(recommendation.zone.label)")
        .accessibilityValue(recommendation.reason)
        .accessibilityHint("Arms this zone's guided protocol for \(exercise)")
    }
}

private func fmt1(_ n: Double) -> String {
    let rounded = (n * 10).rounded() / 10
    if rounded == rounded.rounded() { return "\(Int(rounded))" }
    return String(format: "%.1f", rounded)
}
