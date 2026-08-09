import SendLogWatchCore
import SwiftUI
import WidgetKit

struct LiveEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot
}

struct LiveProvider: TimelineProvider {
    func placeholder(in context: Context) -> LiveEntry {
        LiveEntry(date: .now, snap: .empty)
    }
    func getSnapshot(in context: Context, completion: @escaping (LiveEntry) -> Void) {
        completion(LiveEntry(date: .now, snap: WidgetStore.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LiveEntry>) -> Void) {
        // The workout timer renders natively (Text(timerInterval:)) so we don't
        // need per-second reloads; the app reloads on boulder/phase changes.
        completion(Timeline(entries: [LiveEntry(date: .now, snap: WidgetStore.load())], policy: .never))
    }
}

struct LiveWorkoutView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let snap: WidgetSnapshot

    private func phaseColor(climbing: Bool) -> Color {
        let base = climbing
            ? PhaseRGB(0x4F / 255, 0xB0 / 255, 0xFF / 255)
            : PhaseRGB(0x5B / 255, 0x5F / 255, 0xC7 / 255)
        let adjusted = WatchDesignTokens.accent(base, reducedLuminance: isLuminanceReduced)
        return Color(red: adjusted.red, green: adjusted.green, blue: adjusted.blue)
    }

    private var phaseStart: Date {
        Date(timeIntervalSince1970: snap.phaseSinceEpoch ?? Date().timeIntervalSince1970)
    }
    private var restEnd: Date { phaseStart.addingTimeInterval(Double(snap.restTargetS)) }

    @ViewBuilder private var timer: some View {
        if snap.climbing {
            Text(timerInterval: phaseStart...phaseStart.addingTimeInterval(3600), countsDown: false)
                .monospacedDigit()
        } else {
            Text(timerInterval: phaseStart...restEnd, countsDown: true)
                .monospacedDigit()
        }
    }

    var body: some View {
        if !snap.workoutActive {
            // Idle: a tappable prompt (Smart Stack shows the live one only while
            // training; on the face this reads as a launcher).
            switch family {
            case .accessoryInline:
                Text("No active workout")
            default:
                VStack(alignment: .leading, spacing: 2) {
                    Label("Climb", systemImage: "figure.climbing")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Tap to start a workout")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            switch family {
            case .accessoryInline:
                Text("\(snap.boulders) boulders · \(snap.climbing ? "climbing" : "resting")")
            case .accessoryCircular:
                VStack(spacing: 0) {
                    Image(systemName: "figure.climbing").font(.system(size: 12))
                    Text("\(snap.boulders)").font(.system(size: 16, weight: .bold))
                }
            default: // rectangular (Smart Stack)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Image(systemName: "figure.climbing")
                            .foregroundStyle(phaseColor(climbing: snap.climbing))
                        Text(snap.climbing ? "CLIMBING" : "RESTING")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(phaseColor(climbing: snap.climbing))
                        Spacer()
                        Text("\(snap.boulders)")
                            .font(.system(size: 14, weight: .heavy)).monospacedDigit()
                    }
                    timer.font(.system(size: 22, weight: .heavy, design: .rounded))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct LiveWorkoutWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SendmeterLiveWorkout", provider: LiveProvider()) { entry in
            LiveWorkoutView(snap: entry.snap)
                .containerBackground(.clear, for: .widget)
                .widgetURL(WidgetRoute.workout)
        }
        .configurationDisplayName("Live Workout")
        .description("Boulders and the climb/rest timer while you train.")
        .supportedFamilies([
            .accessoryCircular, .accessoryInline, .accessoryRectangular,
        ])
    }
}
