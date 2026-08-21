import SendmeterCore
import SwiftUI

/// Resisted-movement execution detail sheet (#655).
///
/// Movement metrics are deliberately kept separate from Static capacity. The
/// distinction is product policy: execution quality cannot rewrite a Static
/// PR, force-duration model, or side comparison.
struct MovementDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let recordings: [TindeqRecording]
    let selectedTag: String?
    let selectedSide: TindeqSide?
    let hasLoadedRecordings: Bool

    private var movementRows: [TindeqRecording] {
        ForceProgress.movementRecordings(
            recordings,
            tag: selectedTag,
            side: selectedSide
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    policyCard

                    if !hasLoadedRecordings {
                        ProgressView("Loading force history…")
                            .frame(maxWidth: .infinity, minHeight: 100)
                    } else if let metrics = movementRows.last?.setMetrics {
                        metricsCard(metrics)
                    } else {
                        SurfaceCard {
                            Text("Complete a measured movement set to see execution metrics here.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Resisted movement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var policyCard: some View {
        SurfaceCard {
            Text("Movement is tracked as execution quality. It never changes your Static PR, Hill/CF model or asymmetry.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
        }
    }

    private func metricsCard(_ metrics: ReverseActionMetrics) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Latest measured set", systemImage: "chart.bar.xaxis")
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                    alignment: .leading,
                    spacing: 18
                ) {
                    MetricCell(title: "Completed", value: format(metrics.cadenceAdherencePercent, suffix: "%"))
                    MetricCell(title: "Mean force", value: format(metrics.meanKilograms, suffix: " kg"))
                    MetricCell(title: "Variation (CV)", value: format(metrics.coefficientOfVariationPercent, suffix: "%"))
                    MetricCell(
                        title: metrics.inTargetPercent == nil ? "Accuracy · no target" : "Target accuracy",
                        value: format(metrics.inTargetPercent, suffix: "%")
                    )
                    MetricCell(title: "Force drift", value: format(metrics.driftPercent, suffix: "%"))
                    MetricCell(title: "Measured sets", value: "\(movementRows.count)")
                }
            }
        }
    }

    private func format(_ value: Double?, suffix: String = "") -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(1))))\(suffix)"
    }
}

private struct MetricCell: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
