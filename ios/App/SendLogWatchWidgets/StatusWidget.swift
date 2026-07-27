import SwiftUI
import WidgetKit

// MARK: Timeline

struct StatusEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: .now, snap: .empty)
    }
    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: .now, snap: WidgetStore.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let entry = StatusEntry(date: .now, snap: WidgetStore.load())
        // The app reloads on every sync; this is just a safety re-poll.
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(1800))))
    }
}

// Colours (acwrColor / readinessColor) live in StatusColors.swift — the watch
// app's status page (#278) renders the same two values and must agree.

// MARK: Views (one per accessory family)

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snap: WidgetSnapshot

    private var readinessText: String { snap.readiness.map(String.init) ?? "—" }
    private var acwrText: String { snap.acwr.map { String(format: "%.2f", $0) } ?? "—" }

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: Double(snap.readiness ?? 0), in: 0...100) {
                Text("RDY")
            } currentValueLabel: {
                Text(readinessText).font(.system(size: 15, weight: .bold))
            }
            .gaugeStyle(.accessoryCircular)
            .tint(readinessColor(snap.readinessZone))

        case .accessoryCorner:
            Text(readinessText)
                .font(.system(size: 17, weight: .bold))
                .widgetLabel("ACWR \(acwrText)")

        case .accessoryInline:
            Text("Readiness \(readinessText) · ACWR \(acwrText)")

        default: // .accessoryRectangular
            VStack(alignment: .leading, spacing: 2) {
                Text("SENDMETER")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text(readinessText)
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundStyle(readinessColor(snap.readinessZone))
                    Text("readiness").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text("ACWR \(acwrText)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(acwrColor(snap.acwrRisk))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SendmeterStatus", provider: StatusProvider()) { entry in
            StatusWidgetView(snap: entry.snap)
                .containerBackground(.clear, for: .widget)
                .widgetURL(WidgetRoute.workout)
        }
        .configurationDisplayName("Readiness & ACWR")
        .description("Today's readiness score and training-load ratio.")
        .supportedFamilies([
            .accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular,
        ])
    }
}
