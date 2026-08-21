import ActivityKit
import SwiftUI
import WidgetKit

/// Lock-screen / Dynamic Island card for a guided force protocol (#674) —
/// the native equivalent of the Capacitor app's `TindeqLiveActivity`. The
/// current protocol segment counts down natively from the timestamps in the
/// ContentState (`Text(timerInterval:)`), so the card needs zero per-tick
/// updates from the app; the app only speaks on state transitions (stage
/// changes, Skip Stage, hold-end peak, run complete), exactly the
/// `GuidedProtocolActivityManager` contract.
///
/// KEEP-IN-SYNC note: this widget target has NO SendmeterCore dependency and
/// never sees `GuidedActivityContent` — it renders the wire `ContentState` in
/// `GuidedProtocolActivityAttributes` (the one genuinely shared file,
/// `Sources/Shared`, compiled into both targets). Keep it that way: no Core
/// import, no copied model. Both the countdown AND the progress bar animate
/// natively from the segment window (`Text(timerInterval:)` /
/// `ProgressView(timerInterval:)`), so the app's pushes carry only the window
/// timestamps — keep the rendering in step with the manager that produces
/// them.
///
/// The Dynamic Island tap deep-links to the Force tab through the registered
/// `sendmeter://force` scheme: WidgetKit delivers the URL to the containing
/// app, whose `onOpenURL` routes it (see `AppModel.handleDeepLink`) — the
/// scheme is in Info.plist and the router intercepts it BEFORE the auth
/// parser. This is the fix for the Capacitor widget's `widgetURL` line being
/// copied verbatim: it originally fed every URL to supabase-swift's PKCE
/// `session(from:)`, which threw "Not a valid PKCE flow URL" and surfaced the
/// raw error in a red banner (#674 review F2). The URL is only safe because
/// the native app has a real route for it.
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
        VStack(alignment: .leading, spacing: 6) {
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
            // #674 review N2: a static `ProgressView(value:)` would sit at ~0
            // for a whole segment because the app only pushes on transitions
            // — the card would read as hung next to a correctly-counting
            // timer. `ProgressView(timerInterval:)` animates natively from
            // the segment window (same trick as `Text(timerInterval:)`) with
            // zero pushes. The zero-length complete window is guarded by
            // rendering the checkmark instead, exactly like `segTimer`.
            segProgress(context.state)
                .progressViewStyle(.linear)
                .tint(segColor(context.state))
        }
    }
}

private func segLabel(_ s: GuidedProtocolActivityAttributes.ContentState) -> String {
    if s.isPaused { return "PAUSED" }
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
    if s.isPaused { return .yellow }
    switch s.phase {
    case "work": return .green
    case "prepare", "switch": return .yellow
    case "complete": return .secondary
    default: return .blue
    }
}

@ViewBuilder
private func segTimer(_ s: GuidedProtocolActivityAttributes.ContentState) -> some View {
    if s.isPaused {
        Text("PAUSED")
    } else if s.phase == "complete" {
        Text("✓")
    } else {
        Text(timerInterval: s.segmentStart...s.segmentEnd, countsDown: true)
    }
}

@ViewBuilder
private func segProgress(_ s: GuidedProtocolActivityAttributes.ContentState) -> some View {
    if s.isPaused {
        ProgressView(value: 0)
    } else if s.phase == "complete" {
        // Zero-length window: a full bar reads as "done" rather than 0%.
        ProgressView(value: 1)
    } else {
        ProgressView(timerInterval: s.segmentStart...s.segmentEnd, countsDown: true)
    }
}
