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
                        SurfaceCard {
                            Text("Complete a couple of measured Static holds to unlock the trend and force-duration model.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForceTrendChart(recordings: staticEvidence.trendRecordings)

                        if let selectedTag {
                            NativeForceCurveCard(
                                tag: selectedTag,
                                model: forceCurve,
                                hasLoadedRecordings: hasLoadedRecordings
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
