import ActivityKit
import SwiftUI
import WidgetKit

/// Lock-screen / Dynamic Island card for a manual phone workout (#763) —
/// the native equivalent of the Capacitor `WorkoutLiveActivity`. CLIMBING
/// counts up from the boulder start; RESTING counts down to the configured
/// rest target. Timers render natively from the timestamps in the
/// ContentState, so the card needs zero per-tick updates from the app.
///
/// KEEP-IN-SYNC note: this widget target has no SendmeterCore dependency and
/// never sees `ManualWorkoutActivityContent`; it renders the wire
/// `ContentState` in `ManualWorkoutActivityAttributes` (from
/// `Sources/Shared`, compiled into both targets).
struct ManualWorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ManualWorkoutActivityAttributes.self) { context in
            LockScreenManualWorkoutView(context: context)
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

private struct LockScreenManualWorkoutView: View {
    let context: ActivityViewContext<ManualWorkoutActivityAttributes>

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
    let state: ManualWorkoutActivityAttributes.ContentState

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

private func phaseLabel(_ state: ManualWorkoutActivityAttributes.ContentState) -> String {
    state.phase == "climbing" ? "CLIMBING" : "RESTING"
}

private func iconName(_ state: ManualWorkoutActivityAttributes.ContentState) -> String {
    state.phase == "climbing" ? SendmeterIconSymbol.workout.rawValue : "timer"
}

private func phaseColor(_ state: ManualWorkoutActivityAttributes.ContentState) -> Color {
    state.phase == "climbing" ? .green : .blue
}

/// CLIMBING → count-up from phaseStartedAt; RESTING → countdown to
/// phaseStartedAt + restTargetS. Both native timer text (no updates needed).
@ViewBuilder
private func phaseTimer(_ state: ManualWorkoutActivityAttributes.ContentState) -> some View {
    if state.phase == "climbing" {
        Text(timerInterval: state.phaseStartedAt...state.phaseStartedAt.addingTimeInterval(4 * 3600), countsDown: false)
    } else if let restTargetS = state.restTargetS {
        let end = state.phaseStartedAt.addingTimeInterval(Double(restTargetS))
        Text(timerInterval: state.phaseStartedAt...end, countsDown: true)
    } else {
        Text("—")
    }
}
