import ActivityKit
import SwiftUI
import WidgetKit

/// Lock-screen / Dynamic Island card for a guided force protocol (#674) —
/// the native equivalent of the Capacitor app's `TindeqLiveActivity`. The
/// current protocol segment counts down natively from the timestamps in the
/// ContentState (`Text(timerInterval:)`), so the card needs zero per-tick
/// updates from the app; the app only speaks on state transitions (stage
/// changes, hold-end peak), exactly the `GuidedProtocolActivityManager`
/// contract.
///
/// The rendered content model is the tested `GuidedActivityContent` in
/// SendmeterCore plus the shared `GuidedProtocolActivityAttributes` from
/// `Sources/Shared` — no logic is forked here, and the wire shape cannot
/// drift (single source files shared with the app target).
struct GuidedProtocolLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GuidedProtocolActivityAttributes.self) { context in
            LockScreenGuidedProtocolView(context: context)
                .padding(14)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(segLabel(context.state))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(segColor(context.state))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    segTimer(context.state)
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .frame(maxWidth: 64)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.detailLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let peak = context.state.peakKilograms {
                        Text("peak \(String(format: "%.1f", peak)) kg")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            } compactLeading: {
                Image(systemName: "scalemass")
                    .foregroundStyle(segColor(context.state))
            } compactTrailing: {
                segTimer(context.state)
                    .monospacedDigit()
                    .frame(maxWidth: 44)
                    .foregroundStyle(segColor(context.state))
            } minimal: {
                Image(systemName: "scalemass")
                    .foregroundStyle(segColor(context.state))
            }
            .widgetURL(URL(string: "sendmeter://force"))
        }
    }
}

private struct LockScreenGuidedProtocolView: View {
    let context: ActivityViewContext<GuidedProtocolActivityAttributes>

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(segLabel(context.state))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(segColor(context.state))
                segTimer(context.state)
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(context.state.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(context.state.detailLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                if let peak = context.state.peakKilograms {
                    Text("peak \(String(format: "%.1f", peak)) kg")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                if let target = context.state.targetKilograms {
                    Text("target \(String(format: "%.1f", target)) kg")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private func segLabel(_ s: GuidedProtocolActivityAttributes.ContentState) -> String {
    switch s.phase {
    case "prepare": return "GET READY"
    case "work": return "HOLD"
    case "switch": return "SWITCH HANDS"
    case "rest": return "REST"
    case "setRest": return "SET REST"
    case "complete": return "DONE"
    default: return s.phaseLabel.uppercased()
    }
}

private func segColor(_ s: GuidedProtocolActivityAttributes.ContentState) -> Color {
    switch s.phase {
    case "work": return .green
    case "prepare", "switch": return .yellow
    case "complete": return .secondary
    default: return .blue
    }
}

@ViewBuilder
private func segTimer(_ s: GuidedProtocolActivityAttributes.ContentState) -> some View {
    if s.phase == "complete" {
        Text("✓")
    } else {
        Text(timerInterval: s.segmentStart...s.segmentEnd, countsDown: true)
    }
}
