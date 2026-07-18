import ActivityKit
import SwiftUI
import WidgetKit

/// Lock-screen / Dynamic Island card for a Tindeq measurement: the current
/// protocol segment (HOLD/REST/…) counting down natively, rep × set, and the
/// session peak. The app steps the segment on each boundary; between updates
/// the countdown renders from timestamps with no help.
struct TindeqLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TindeqActivityAttributes.self) { context in
            LockScreenTindeqView(context: context)
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
                    Text(repSetLine(context))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let peak = context.state.peakKg {
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

private struct LockScreenTindeqView: View {
    let context: ActivityViewContext<TindeqActivityAttributes>

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
                Text(context.attributes.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(repSetLine(context))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                if let peak = context.state.peakKg {
                    Text("peak \(String(format: "%.1f", peak)) kg")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                if let target = context.attributes.targetKg {
                    Text("target \(String(format: "%.1f", target)) kg")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private func repSetLine(_ context: ActivityViewContext<TindeqActivityAttributes>) -> String {
    var line = "rep \(context.state.rep) · set \(context.state.set)"
    if let side = context.state.side {
        line = "\(side == "left" ? "L" : "R") · " + line
    }
    return line
}

private func segLabel(_ s: TindeqActivityAttributes.ContentState) -> String {
    switch s.segPhase {
    case "prepare": return "GET READY"
    case "hold": return "HOLD"
    case "switch": return "SWITCH HANDS"
    case "rest": return "REST"
    case "setRest": return "SET REST"
    case "done": return "DONE"
    default: return s.segPhase.uppercased()
    }
}

private func segColor(_ s: TindeqActivityAttributes.ContentState) -> Color {
    switch s.segPhase {
    case "hold": return .green
    case "prepare", "switch": return .yellow
    case "done": return .secondary
    default: return .blue
    }
}

@ViewBuilder
private func segTimer(_ s: TindeqActivityAttributes.ContentState) -> some View {
    if s.segPhase == "done" {
        Text("✓")
    } else {
        Text(timerInterval: s.segStart...s.segEnd, countsDown: true)
    }
}
