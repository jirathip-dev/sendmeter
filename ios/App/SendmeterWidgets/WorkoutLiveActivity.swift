import ActivityKit
import SwiftUI
import WidgetKit

/// Lock-screen / Dynamic Island card for a running workout — same logic as
/// the in-app fullscreen: CLIMBING counts up from the boulder start, RESTING
/// counts down to the rest target. Timers render natively from timestamps, so
/// they tick with zero updates from the app.
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            LockScreenWorkoutView(context: context)
                .padding(14)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 4) {
                        Image(systemName: iconName(context.state))
                        Text(phaseLabel(context.state))
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(phaseColor(context.state))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    phaseTimer(context.state)
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .frame(maxWidth: 64)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("\(context.state.boulderCount) boulder\(context.state.boulderCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if #available(iOS 17.0, *) {
                        IntentButtonRow(state: context.state)
                    }
                }
            } compactLeading: {
                Image(systemName: iconName(context.state))
                    .foregroundStyle(phaseColor(context.state))
            } compactTrailing: {
                phaseTimer(context.state)
                    .monospacedDigit()
                    .frame(maxWidth: 44)
                    .foregroundStyle(phaseColor(context.state))
            } minimal: {
                Image(systemName: iconName(context.state))
                    .foregroundStyle(phaseColor(context.state))
            }
            .widgetURL(URL(string: "sendmeter://workout"))
        }
    }
}

private struct LockScreenWorkoutView: View {
    let context: ActivityViewContext<WorkoutActivityAttributes>

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(phaseLabel(context.state))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(phaseColor(context.state))
                phaseTimer(context.state)
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text("\(context.state.boulderCount) boulder\(context.state.boulderCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if #available(iOS 17.0, *) {
                IntentButtonRow(state: context.state)
            }
        }
    }
}

/// Boulder (resting) ⇄ Stop (climbing) — tappable straight from the lock
/// screen; the intent runs in the app process and updates this card natively.
@available(iOS 17.0, *)
private struct IntentButtonRow: View {
    let state: WorkoutActivityAttributes.ContentState

    var body: some View {
        if state.phase == "climbing" {
            Button(intent: StopIntent()) {
                Label("Stop", systemImage: "stop.fill")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        } else if state.phase == "resting" {
            Button(intent: BoulderIntent()) {
                Label("Boulder", systemImage: "play.fill")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
    }
}

private func phaseLabel(_ s: WorkoutActivityAttributes.ContentState) -> String {
    switch s.phase {
    case "climbing": return "CLIMBING"
    case "resting": return "RESTING"
    default: return "ENDED"
    }
}

private func iconName(_ s: WorkoutActivityAttributes.ContentState) -> String {
    s.phase == "climbing" ? "figure.climbing" : "timer"
}

private func phaseColor(_ s: WorkoutActivityAttributes.ContentState) -> Color {
    switch s.phase {
    case "climbing": return .green
    case "resting": return .blue
    default: return .secondary
    }
}

/// CLIMBING → count-up from phaseStartedAt; RESTING → countdown to
/// phaseStartedAt + restTargetS. Both native timer text (no updates needed).
@ViewBuilder
private func phaseTimer(_ s: WorkoutActivityAttributes.ContentState) -> some View {
    if s.phase == "climbing" {
        Text(timerInterval: s.phaseStartedAt...s.phaseStartedAt.addingTimeInterval(4 * 3600), countsDown: false)
    } else if s.phase == "resting" {
        let end = s.phaseStartedAt.addingTimeInterval(Double(s.restTargetS ?? 180))
        Text(timerInterval: s.phaseStartedAt...end, countsDown: true)
    } else {
        Text("—")
    }
}
