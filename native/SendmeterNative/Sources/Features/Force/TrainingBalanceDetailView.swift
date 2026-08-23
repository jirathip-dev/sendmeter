import SendmeterCore
import SwiftUI

/// The training-balance card's own sheet (#653, port of
/// `TrainingBalanceDetail.tsx` / #214). The card can only ever be a summary;
/// this is where its scope is stated outright and every number is traced back
/// to the holds that produced it, because the same training used to read
/// differently here and in History with nothing on screen explaining why.
struct TrainingBalanceDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    /// Every recording for the active exercise (unwindowed) — the sheet
    /// applies the same trailing window the card does.
    let recordings: [TindeqRecording]
    let exercise: String
    /// The card's frozen clock — the same `now` that scoped the bars, so the
    /// sheet's window sentence and the bars can never disagree.
    let now: Date
    let windowDays: Int
    /// The card's own numbers, passed down rather than recomputed, so the
    /// sheet can never quote a different figure than the bars behind it.
    let sets: [ZoneQuality: Double]
    let recommendation: ZoneRecommendation?
    let curveInput: ZoneCurveInput?

    /// The holds the bars were scoped with — the same filter, not a second
    /// copy of the cutoff rule.
    private var windowRecordings: [TindeqRecording] {
        ZoneMix.holdsInWindow(recordings, now: now, windowDays: windowDays)
    }

    private var scopeCounts: (effortCount: Int, recordedCount: Int) {
        ZoneMix.balanceScopeCounts(windowRecordings)
    }

    private var since: String {
        LocalDateSupport.string(
            from: now.addingTimeInterval(-Double(windowDays) * 86_400)
        )
    }

    var body: some View {
        // #653 review finding 10: `windowRecordings`/`scopeCounts` recompute
        // per access; bind them once so the sheet body doesn't rescan the
        // recording array for each sentence.
        let windowRecordings = self.windowRecordings
        let scopeCounts = self.scopeCounts
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    scopeSection(windowRecordings: windowRecordings, scopeCounts: scopeCounts)
                    breakdownSection(windowRecordings)
                    if let recommendation {
                        recommendationSection(recommendation)
                    }
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Training balance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: What this counts

    private func scopeSection(
        windowRecordings: [TindeqRecording],
        scopeCounts: (effortCount: Int, recordedCount: Int)
    ) -> some View {
        SectionCard(title: "What this counts") {
            scopeRow("One exercise") {
                Text("Only holds tagged **\(exercise)** count. Every other exercise is excluded, so this is the balance of one exercise, not of your training as a whole.")
            }
            scopeRow("One window") {
                Text("The last \(windowDays) days (since \(since)). Anything older is excluded, however much of it there is.")
            }
            scopeRow("Both sides") {
                Text("Left, right and both-hands holds all count toward the same balance.")
            }
            scopeRow("Sets, not sessions") {
                Text("Each zone's total hold time divided by that zone's own protocol set length, so a 5-minute warm-up registers as a fraction of a set instead of a whole session. \(scopeCounts.effortCount) recording\(scopeCounts.effortCount == 1 ? "" : "s") fed the numbers below.")
            }
            scopeRow("Recorded vs inferred zones") {
                recordedVsInferred(scopeCounts)
            }
            scopeRow("Why History reads differently") {
                Text("History lists every session for every exercise over all time, and badges each one with the zone that session alone was mostly in. It's a different measurement over a different scope — the two are expected to disagree, and neither is wrong.")
            }
        }
    }

    @ViewBuilder
    private func recordedVsInferred(_ scopeCounts: (effortCount: Int, recordedCount: Int)) -> some View {
        let recorded = scopeCounts.recordedCount
        let inferred = scopeCounts.effortCount - recorded
        if recorded == 0 {
            Text("None of these holds store the zone they were performed under, so every one is bucketed by how long it lasted. Only holds recorded under an armed zone or preset carry the real thing.")
        } else {
            Text("\(recorded) of \(scopeCounts.effortCount) hold\(scopeCounts.effortCount == 1 ? "" : "s") store the zone they were performed under and are counted as that; \(inferred == 0 ? "none are inferred" : "the other \(inferred) have it inferred from hold length").")
        }
    }

    // MARK: Where each number comes from

    private func breakdownSection(_ windowRecordings: [TindeqRecording]) -> some View {
        SectionCard(title: "Where each number comes from") {
            ZoneBreakdownPanel(recordings: windowRecordings)
        }
    }

    // MARK: Why this zone is recommended

    private func recommendationSection(_ recommendation: ZoneRecommendation) -> some View {
        let detail = recommendation.detail
        let tiedOthers = detail.tied.filter { $0 != recommendation.zone }
        let color = ChartToken.zoneQuality(recommendation.zone).color(scheme)

        return SectionCard(title: "Why \(recommendation.zone.label) is recommended") {
            Text(recommendation.zone.label)
                .font(.headline.bold())
                .foregroundStyle(color)
                .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("Least-trained zone wins. The lowest of the four is \(fmt1(detail.minSets)) set\(fmt1(detail.minSets) == "1" ? "" : "s"); \(recommendation.zone.label) is at \(fmt1(sets[recommendation.zone] ?? 0)).")

                if tiedOthers.isEmpty {
                    Text("No other zone is within \(ZoneMix.tieBandSets) sets of it, so there was no tie to break.")
                } else {
                    Text("Within \(ZoneMix.tieBandSets) sets of that minimum, so treated as tied: \(detail.tied.map { "\($0.label) \(fmt1(sets[$0] ?? 0))" }.joined(separator: " · ")).")
                }

                if let ratio = detail.curveRatio {
                    let percent = Int((ratio * 100).rounded())
                    Text("Your critical force is \(percent)% of your predicted 5s peak — \(detail.curveBias == .endurance ? "under \(Int((ZoneMix.curveBiasRatio * 100).rounded()))%, which reads as endurance-limited" : "at or over \(Int((ZoneMix.curveBiasRatio * 100).rounded()))%, which reads as strength-limited"). \(tiedOthers.isEmpty ? "With no tie to break, it changed nothing here." : (detail.biasChangedPick ? "That broke the tie toward the \(detail.curveBias?.rawValue ?? "") side, over \(detail.unbiasedZone.label)." : "That points at the same zone the set counts already did (\(detail.unbiasedZone.label)), so it changed nothing."))")
                } else {
                    Text("No critical-force fit yet, so the force curve had no say — the least-trained zone stands on its own.")
                }

                Text("Tapping the recommendation on the card arms this zone's guided protocol for \(exercise).")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineSpacing(2)
        }
    }

    private func scopeRow(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(.primary)
            content()
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
        }
        .padding(.bottom, 8)
    }
}

/// The card section surface used by the detail sheet's stacked sections.
private struct SectionCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            content
        }
        .padding(SendmeterStyle.spacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: SendmeterStyle.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SendmeterStyle.radius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

/// The arithmetic behind the bars — per-zone hold seconds ÷ protocol set
/// length, the "recorded" provenance, and the holds behind each number (web
/// `ZoneBreakdownPanel.tsx`).
private struct ZoneBreakdownPanel: View {
    @Environment(\.colorScheme) private var scheme
    let recordings: [TindeqRecording]
    @State private var expandedZones: Set<ZoneQuality> = []

    private var breakdown: ZoneBreakdown {
        ZoneMix.zoneBreakdown(recordings)
    }

    private var excludedSummary: String {
        let warmups = breakdown.excluded.filter { $0.recording.zone == .warmup }.count
        let prehabs = breakdown.excluded.filter { $0.recording.zone == .prehab }.count
        var parts: [String] = []
        if warmups > 0 { parts.append("\(warmups) Warm-up hold\(warmups == 1 ? "" : "s")") }
        if prehabs > 0 { parts.append("\(prehabs) Prehab hold\(prehabs == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// Holds recorded with the native-only "capacity" zone — counted toward
    /// Endurance via `ZoneMix.zone(for:)` (#657).
    private var capacityCount: Int {
        recordings.filter { $0.zone == .capacity }.count
    }

    var body: some View {
        // #653 review finding 10: derive the breakdown once per body pass
        // instead of re-scanning the recording array on every access.
        let breakdown = self.breakdown
        VStack(alignment: .leading, spacing: 10) {
            ForEach(ZoneQuality.allCases, id: \.self) { zone in
                if let entry = breakdown.zones[zone] {
                    zoneRow(zone, entry: entry)
                }
            }

            if !breakdown.unclassified.isEmpty {
                Text("\(breakdown.unclassified.count) hold\(breakdown.unclassified.count == 1 ? "" : "s") under 1s counted toward nothing (stray blips)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if !breakdown.excluded.isEmpty {
                Text("\(excludedSummary) recorded outside training balance")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            // #657: native-only "capacity" recordings count toward Endurance —
            // said outright so a hold shown inside the Endurance band with a
            // "recorded as Capacity" origin doesn't read as a zone that isn't
            // one of the four bars (#653 review finding 13).
            if capacityCount > 0 {
                Text("\(capacityCount) hold\(capacityCount == 1 ? "" : "s") recorded as Capacity count toward Endurance (long holds).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Divider()
                .padding(.vertical, 4)

            SectionLabel("How a hold gets its zone")
            ForEach(ZoneMix.zoneBands, id: \.zone) { band in
                HStack {
                    Text("\(band.zone.label) · anchor hold \(band.anchorS)s")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(band.band)
                        .foregroundStyle(.primary)
                }
                .font(.caption2)
            }
            Text(ZoneMix.zoneBandCaveat)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineSpacing(2)
                .padding(.top, 4)
        }
    }

    private func zoneRow(_ zone: ZoneQuality, entry: ZoneBreakdownEntry) -> some View {
        let color = ChartToken.zoneQuality(zone).color(scheme)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(zone.label)
                    .font(.subheadline.weight(.bold))
                Spacer()
                Text("\(fmt1(entry.sets)) set\(fmt1(entry.sets) == "1" ? "" : "s")")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(color)
            }
            // The division itself — the number above is this line's result,
            // not an assertion the reader has to take on trust (#214). The
            // identity is holdS × holdCount = setDurationS, so endurance's
            // 1-rep × 8-set shape (#320) reads correctly instead of drifting.
            if entry.holds.isEmpty {
                Text("No holds in this band")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 15)
            } else {
                let anchor = Double(ZoneMix.anchorHoldSeconds(zone))
                Text("\(fmt1(entry.totalHoldS))s of holds ÷ \(Int(entry.setDurationS))s per set (\(fmt1(anchor))s × \(Int((entry.setDurationS / anchor).rounded())) holds) = \(fmt1(entry.sets))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 15)
            }
            if entry.recordedCount > 0 {
                Text("\(entry.recordedCount) recorded as \(zone.label)\(entry.inferredCount > 0 ? " · \(entry.inferredCount) inferred from hold length" : "")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 15)
            }
            if !entry.holds.isEmpty {
                Button {
                    if expandedZones.contains(zone) { expandedZones.remove(zone) } else { expandedZones.insert(zone) }
                } label: {
                    Text("\(expandedZones.contains(zone) ? "▾" : "▸") \(entry.holds.count) hold\(entry.holds.count == 1 ? "" : "s")")
                        .font(.caption2)
                }
                .hapticButtonStyle(.plain)
                .padding(.leading, 15)
                if expandedZones.contains(zone) {
                    holdList(entry.holds)
                }
            }
        }
    }

    private func holdList(_ holds: [ZoneHold]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(holds, id: \.recording.id) { hold in
                HStack {
                    Text(holdLine(hold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Text("\(fmt1(hold.durationS))s\(holdOriginSuffix(hold))")
                        .foregroundStyle(.primary)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 28)
    }

    private func holdLine(_ hold: ZoneHold) -> String {
        var line = hold.recording.recordedAt.formatted(date: .abbreviated, time: .shortened)
        if !hold.recording.tag.isEmpty { line += " · \(hold.recording.tag)" }
        let side = hold.recording.side
        if side == .left { line += " · L" }
        else if side == .right { line += " · R" }
        else if side == .both { line += " · L+R" }
        return line
    }

    private func holdOriginSuffix(_ hold: ZoneHold) -> String {
        // Web `holdOrigin`: a recorded zone shows "recorded as X"; an inferred
        // one shows the duration band it was bucketed by.
        switch hold.source {
        case .recorded:
            guard let zone = hold.recording.zone else { return "" }
            return " · recorded as \(zone.displayLabel)"
        case .inferred:
            guard let band = ZoneMix.band(for: hold.durationS)?.band else { return "" }
            return " · \(band)"
        }
    }
}

private func fmt1(_ n: Double) -> String {
    let rounded = (n * 10).rounded() / 10
    if rounded == rounded.rounded() { return "\(Int(rounded))" }
    return String(format: "%.1f", rounded)
}
