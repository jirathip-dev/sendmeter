import SendLogWatchCore
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
    private var readinessZone: String? { StatusPresentation.readinessZoneLabel(snap.readinessZone) }
    private var risk: ACWRRiskBand? { StatusPresentation.acwrRiskBand(snap.acwr) }
    private var inlineText: String {
        let readiness = readinessZone.map { "R \(readinessText) \($0)" } ?? "R \(readinessText)"
        let acwr = risk.map { "A \(acwrText) \($0.label)" } ?? "A \(acwrText)"
        return "\(readiness) · \(acwr)"
    }

    private var readinessAccessibility: String {
        guard let readiness = snap.readiness else { return "Readiness, no data" }
        return "Readiness, \(readiness) out of 100, \(readinessZone ?? "zone unavailable")"
    }

    private var acwrAccessibility: String {
        guard snap.acwr != nil, let risk else { return "ACWR, no data" }
        return "ACWR, \(acwrText), \(risk.label)"
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ReadinessRingView(
                score: snap.readiness,
                zone: snap.readinessZone,
                lineWidth: 5,
                valueFontSize: 15
            )
            .padding(3)

        case .accessoryCorner:
            ReadinessRingView(
                score: snap.readiness,
                zone: snap.readinessZone,
                lineWidth: 5,
                valueFontSize: 15
            )
            .padding(3)
            .widgetLabel("ACWR \(acwrText) \(risk?.label ?? "No data")")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Readiness and ACWR")
            .accessibilityValue("\(readinessAccessibility); \(acwrAccessibility)")

        case .accessoryInline:
            Text(inlineText)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Readiness and ACWR")
                .accessibilityValue("\(readinessAccessibility); \(acwrAccessibility)")

        default: // .accessoryRectangular
            HStack(spacing: 8) {
                VStack(spacing: 2) {
                    ReadinessRingView(
                        score: snap.readiness,
                        zone: snap.readinessZone,
                        lineWidth: 5,
                        valueFontSize: 16
                    )
                    .frame(width: 43, height: 43)
                    Text(readinessZone ?? (snap.readiness == nil ? "No data" : "No zone"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(readinessColor(snap.readinessZone))
                        .lineLimit(1)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("ACWR")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(acwrText)
                            .font(.system(size: 18, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                        Text(risk?.label ?? "No data")
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(acwrColor(risk))
                    .accessibilityHidden(true)

                    ACWRRiskTrackView(value: snap.acwr, bandHeight: 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
                .widgetURL(WidgetRoute.status)
        }
        .configurationDisplayName("Readiness & ACWR")
        .description("Today's readiness score and training-load ratio.")
        .supportedFamilies([
            .accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular,
        ])
    }
}
