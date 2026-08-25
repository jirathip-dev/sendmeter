import SendmeterCore
import SwiftUI

/// Full-height Static capacity detail sheet (#655).
///
/// The trend, curve, and asymmetry views all consume the same filtered Static
/// evidence. A sheet with fewer than two rows stays explanatory instead of
/// presenting a misleading one-point "trend".
struct StaticCapacityDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let recordings: [TindeqRecording]
    let selectedTag: String?
    let selectedSide: TindeqSide?
    let forceCurve: ForceCurveModel?
    let hasLoadedRecordings: Bool
    let targetBand: ForceTargetBand?
    let connectionPending: Bool

    private var staticEvidence: StaticCapacityEvidence {
        ForceProgress.staticCapacityEvidence(
            recordings: recordings,
            tag: selectedTag,
            side: selectedSide
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    if !hasLoadedRecordings {
                        ProgressView("Loading force history…")
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else if staticEvidence.trendRecordings.count < 2 {
                        ProductEmptyState(
                            title: "Build your capacity baseline",
                            message: "Two measured Static holds reveal your force trend and curve.",
                            actionTitle: "Back to Force",
                            action: { dismiss() }
                        )
                    } else {
                        ForceTrendChart(
                            recordings: staticEvidence.trendRecordings,
                            targetBand: targetBand
                        )

                        if let selectedTag {
                            NativeForceCurveCard(
                                tag: selectedTag,
                                model: forceCurve,
                                hasLoadedRecordings: hasLoadedRecordings,
                                targetBand: targetBand,
                                connectionPending: connectionPending,
                                emptyActionTitle: "Back to Force",
                                emptyAction: { dismiss() }
                            )
                            SideAsymmetryCard(recordings: recordings, tag: selectedTag)
                        } else {
                            SurfaceCard {
                                Text("Select an exercise to see its force-duration model and left/right asymmetry.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Static capacity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
