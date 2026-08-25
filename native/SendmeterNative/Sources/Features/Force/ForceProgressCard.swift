import SendmeterCore
import SwiftUI

/// O(1) render boundary around the progress card. The raw recordings are
/// intentionally passed through only after a progress-input key changes; a
/// display-rate Tindeq frame can rebuild `ForceView` without re-running the
/// full Static/Movement filters or disturbing the sheet-owned state below.
struct ForceProgressCardBoundary: View, Equatable {
    let recordings: [TindeqRecording]
    let selectedTag: String?
    let selectedSide: TindeqSide?
    let forceCurve: ForceCurveModel?
    let hasLoadedRecordings: Bool
    let progressRevision: UInt64
    let curveRevision: UInt64
    let targetBand: ForceTargetBand?
    let emptyActionTitle: String
    let emptyAction: () -> Void
    let connectionPending: Bool

    private var renderKey: ForceProgressCardKey {
        ForceProgressCardKey(
            progressRevision: progressRevision,
            selectedTag: selectedTag,
            selectedSide: selectedSide?.rawValue,
            hasLoadedRecordings: hasLoadedRecordings,
            curveRevision: curveRevision,
            targetBand: targetBand,
            emptyActionTitle: emptyActionTitle,
            connectionPending: connectionPending
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.renderKey == rhs.renderKey
    }

    var body: some View {
        ForceProgressCard(
            recordings: recordings,
            selectedTag: selectedTag,
            selectedSide: selectedSide,
            forceCurve: forceCurve,
            hasLoadedRecordings: hasLoadedRecordings,
            targetBand: targetBand,
            emptyActionTitle: emptyActionTitle,
            emptyAction: emptyAction,
            connectionPending: connectionPending
        )
    }
}

/// The Force tab's two compact progress surfaces (#655).
///
/// Static capacity and resisted movement intentionally share a visual home but
/// not a data scope. Static rows feed capacity evidence; movement rows expose
/// execution quality only.
struct ForceProgressCard: View {
    let recordings: [TindeqRecording]
    let selectedTag: String?
    let selectedSide: TindeqSide?
    let forceCurve: ForceCurveModel?
    let hasLoadedRecordings: Bool
    let targetBand: ForceTargetBand?
    let emptyActionTitle: String
    let emptyAction: () -> Void
    let connectionPending: Bool

    @Environment(\.colorScheme) private var scheme
    @State private var detail: Detail?

    private enum Detail: String, Identifiable {
        case staticCapacity
        case movement

        var id: String { rawValue }
    }

    var body: some View {
        let staticProgress = ForceProgress.staticCapacityProgress(
            recordings: recordings,
            tag: selectedTag,
            side: selectedSide
        )
        let movementProgress = ForceProgress.movementProgress(
            recordings: recordings,
            tag: selectedTag,
            side: selectedSide
        )

        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Progress & insights", systemImage: "chart.bar.xaxis")
            if hasLoadedRecordings,
               staticProgress.totalCount == 0,
               movementProgress.latestMetrics == nil {
                if connectionPending {
                    ProgressView("Connecting to Progressor…")
                        .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    ProductEmptyState(
                        title: "Your first pull starts the trend",
                        message: "Connect your Progressor and save a pull to see capacity and movement progress.",
                        actionTitle: emptyActionTitle,
                        action: emptyAction
                    )
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    staticTile(staticProgress)
                    movementTile(movementProgress)
                }
            }
        }
        .sheet(item: $detail, onDismiss: { Haptics.shared.sheetDismissed() }) { detail in
            Group {
                switch detail {
                case .staticCapacity:
                    StaticCapacityDetailView(
                        recordings: recordings,
                        selectedTag: selectedTag,
                        selectedSide: selectedSide,
                        forceCurve: forceCurve,
                        hasLoadedRecordings: hasLoadedRecordings,
                        targetBand: targetBand,
                        connectionPending: connectionPending
                    )
                    .onAppear { Haptics.shared.sheetPresented() }
                case .movement:
                    MovementDetailView(
                        recordings: recordings,
                        selectedTag: selectedTag,
                        selectedSide: selectedSide,
                        hasLoadedRecordings: hasLoadedRecordings
                    )
                    .onAppear { Haptics.shared.sheetPresented() }
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private func staticTile(_ progress: StaticCapacityProgress) -> some View {
        tile(
            title: "Static capacity",
            selectedTag: selectedTag,
            systemImage: "waveform.path.ecg",
            color: ChartToken.force.color(scheme),
            accessibilityLabel: "Open Static capacity progress and insights"
        ) {
            detail = .staticCapacity
        } content: {
            if progress.totalCount > 0 {
                HStack(spacing: 6) {
                    previewMetric(
                        value: format(progress.latestPeakKilograms),
                        label: "Latest kg"
                    )
                    previewMetric(
                        value: format(progress.bestPeakKilograms),
                        label: "Best kg"
                    )
                    previewMetric(
                        value: "\(progress.totalCount)",
                        label: "Recordings"
                    )
                }

                sparkline(
                    values: progress.recordings.compactMap(\.peakKilograms),
                    maximum: progress.bestPeakKilograms ?? 0,
                    color: ChartToken.force.color(scheme),
                    label: "Recent Static peaks"
                )
            } else {
                Text(
                    hasLoadedRecordings
                        ? "Complete a measured Static hold to start this capacity view."
                        : "Loading force history…"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
            }
        }
    }

    private func movementTile(_ progress: MovementProgress) -> some View {
        tile(
            title: "Resisted movement",
            selectedTag: selectedTag,
            systemImage: "arrow.left.and.right.circle",
            color: ChartToken.optimal.color(scheme),
            accessibilityLabel: "Open resisted movement progress and insights"
        ) {
            detail = .movement
        } content: {
            if let metrics = progress.latestMetrics {
                HStack(spacing: 6) {
                    previewMetric(
                        value: format(metrics.cadenceAdherencePercent, suffix: "%"),
                        label: "Completed"
                    )
                    previewMetric(
                        value: format(metrics.meanKilograms),
                        label: "Mean kg"
                    )
                    previewMetric(
                        value: format(metrics.coefficientOfVariationPercent, suffix: "%"),
                        label: "Variation"
                    )
                }

                sparkline(
                    values: progress.recordings.compactMap { $0.setMetrics?.cadenceAdherencePercent },
                    maximum: 100,
                    color: ChartToken.optimal.color(scheme),
                    label: "Recent movement completion"
                )
            } else {
                Text(
                    hasLoadedRecordings
                        ? "Complete a measured movement set to see completion, mean force, stability, accuracy and drift."
                        : "Loading force history…"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
            }
        }
    }

    @ViewBuilder
    private func tile<Content: View>(
        title: String,
        selectedTag: String?,
        systemImage: String,
        color: Color,
        accessibilityLabel: String,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: {
            Haptics.shared.tap()
            action()
        }) {
            tileSurface(
                title: title,
                selectedTag: selectedTag,
                systemImage: systemImage,
                color: color,
                showsChevron: true,
                content: content
            )
        }
        .hapticButtonStyle(.plain)
        .accessibilityLabel(
            selectedTag.map { "\(accessibilityLabel), \($0)" } ?? accessibilityLabel
        )
        .accessibilityHint("Opens a full-height detail sheet")
    }

    @ViewBuilder
    private func tileSurface<Content: View>(
        title: String,
        selectedTag: String?,
        systemImage: String,
        color: Color,
        showsChevron: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Label {
                    Text(selectedTag.map { "\(title) · \($0)" } ?? title)
                } icon: {
                    Image(systemName: systemImage)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(2)

                Spacer(minLength: 0)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
            }

            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(color.opacity(0.24), lineWidth: 1)
        )
    }

    private func previewMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sparkline(
        values: [Double],
        maximum: Double,
        color: Color,
        label: String
    ) -> some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color.opacity(0.75))
                    .frame(maxWidth: .infinity)
                    .frame(
                        height: max(
                            5,
                            38 * CGFloat(ForceProgress.barFraction(value: value, maximum: maximum))
                        )
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 40, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(values.map { $0.formatted(.number.precision(.fractionLength(1))) }.joined(separator: ", "))
    }

    private func format(_ value: Double?, suffix: String = "") -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(1))))\(suffix)"
    }
}
