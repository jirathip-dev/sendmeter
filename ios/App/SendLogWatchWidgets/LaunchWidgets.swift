import SwiftUI
import WidgetKit

/// Quick-launch complications — tap on the watch face to jump straight into a
/// workout or the Force gauge (deep-links routed by RootView).

struct LaunchEntry: TimelineEntry { let date: Date }

struct LaunchProvider: TimelineProvider {
    func placeholder(in context: Context) -> LaunchEntry { LaunchEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (LaunchEntry) -> Void) {
        completion(LaunchEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LaunchEntry>) -> Void) {
        completion(Timeline(entries: [LaunchEntry(date: .now)], policy: .never))
    }
}

private struct LaunchIcon: View {
    @Environment(\.widgetFamily) private var family
    let symbol: String
    let label: String

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(label, systemImage: symbol)
        case .accessoryRectangular:
            Label(label, systemImage: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
        default: // circular / corner
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .widgetLabel(label)
        }
    }
}

struct StartWorkoutWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SendmeterStartWorkout", provider: LaunchProvider()) { _ in
            LaunchIcon(symbol: "figure.climbing", label: "Climb")
                .containerBackground(.clear, for: .widget)
                .widgetURL(WidgetRoute.workout)
        }
        .configurationDisplayName("Start Workout")
        .description("Tap to start tracking a climbing workout.")
        .supportedFamilies([
            .accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular,
        ])
    }
}

struct ForceGaugeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SendmeterForceGauge", provider: LaunchProvider()) { _ in
            LaunchIcon(symbol: "gauge.with.dots.needle.bottom.50percent", label: "Force")
                .containerBackground(.clear, for: .widget)
                .widgetURL(WidgetRoute.force)
        }
        .configurationDisplayName("Force Gauge")
        .description("Tap to open the Tindeq force gauge.")
        .supportedFamilies([
            .accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular,
        ])
    }
}
