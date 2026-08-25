import Foundation
import SwiftUI
import UIKit
import WidgetKit

private let readinessWidgetURL = URL(string: "sendmeter://dashboard")!

private func readinessWidgetLocalDay(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = .current
    calendar.timeZone = .current
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(
        format: "%04d-%02d-%02d",
        components.year ?? 0,
        components.month ?? 0,
        components.day ?? 0
    )
}

struct ReadinessWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: ReadinessWidgetSnapshot?
}

struct ReadinessWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> ReadinessWidgetEntry {
        ReadinessWidgetEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (ReadinessWidgetEntry) -> Void
    ) {
        let now = Date()
        completion(ReadinessWidgetEntry(
            date: now,
            snapshot: currentSnapshot(at: now)
        ))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<ReadinessWidgetEntry>) -> Void
    ) {
        let now = Date()
        let entry = ReadinessWidgetEntry(
            date: now,
            snapshot: currentSnapshot(at: now)
        )
        let next = ReadinessWidgetTimelinePolicy.nextReloadDate(after: now)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func currentSnapshot(at date: Date) -> ReadinessWidgetSnapshot? {
        guard let snapshot = ReadinessWidgetStore.load(),
              snapshot.freshness(on: readinessWidgetLocalDay(date)) == .current
        else { return nil }
        return snapshot
    }
}

struct ReadinessWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "SendmeterReadiness",
            provider: ReadinessWidgetProvider()
        ) { entry in
            ReadinessWidgetView(entry: entry)
                .widgetURL(readinessWidgetURL)
                .containerBackground(for: .widget) {
                    Color(.systemBackground)
                }
        }
        .configurationDisplayName("Today's readiness")
        .description("Readiness, training load, and your current block at a glance.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private struct ReadinessWidgetView: View {
    let entry: ReadinessWidgetEntry
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let snapshot = entry.snapshot {
            if snapshot.readiness == nil && snapshot.acwr == nil {
                emptyData(snapshot)
            } else {
                data(snapshot)
            }
        } else {
            noSnapshot
        }
    }

    private var noSnapshot: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("No data yet", systemImage: "heart.text.square")
                .font(.headline.weight(.semibold))
            Text("Connect Apple Health in Sendmeter to sync today's readiness.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Open Sendmeter")
                .font(.caption.weight(.bold))
                .foregroundStyle(semanticColor(.health))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No readiness data yet. Open Sendmeter to connect Apple Health and sync today's score.")
    }

    private func emptyData(_ snapshot: ReadinessWidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("No readiness yet", systemImage: "heart.text.square")
                .font(.headline.weight(.semibold))
            Text("Connect Apple Health or open Sendmeter to sync today's score.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            phaseSummary(snapshot)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No readiness score yet. Open Sendmeter to connect Apple Health and sync today's score.")
    }

    private func data(_ snapshot: ReadinessWidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                readinessSummary(snapshot)
                Spacer(minLength: 4)
                acwrSummary(snapshot, compact: true)
            }
            phaseSummary(snapshot)
        }
    }

    private func readinessSummary(_ snapshot: ReadinessWidgetSnapshot) -> some View {
        let band = ReadinessWidgetPresentation.readinessBand(snapshot.readiness)
        return VStack(alignment: .leading, spacing: 2) {
            Text("READINESS")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            if let score = snapshot.readiness {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(score)")
                        .font(.system(size: 39, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(semanticColor(band.semanticToken))
                    Text("/100")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(snapshot.readinessZone?.capitalized ?? band.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(semanticColor(band.semanticToken))
            } else {
                Text("No score yet")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Connect Apple Health")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(snapshot.readiness.map {
            "Readiness \($0) out of 100, \(snapshot.readinessZone ?? band.rawValue)"
        } ?? "Readiness score unavailable. Connect Apple Health.")
    }

    private func acwrSummary(
        _ snapshot: ReadinessWidgetSnapshot,
        compact: Bool
    ) -> some View {
        let band = ReadinessWidgetPresentation.acwrBand(snapshot.acwr)
        return VStack(alignment: .trailing, spacing: 2) {
            Text("ACWR")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            if let ratio = snapshot.acwr {
                Text(Self.decimal(ratio, places: 2))
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(semanticColor(band.semanticToken))
                Text(band.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(semanticColor(band.semanticToken))
                if let acute = snapshot.acute, let chronic = snapshot.chronic {
                    Text(compact
                        ? "A \(Self.decimal(acute, places: 0)) · C \(Self.decimal(chronic, places: 0))"
                        : "Acute \(Self.decimal(acute, places: 0)) · Chronic \(Self.decimal(chronic, places: 0))"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            } else {
                Text("No load data yet")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(snapshot.acwr.map {
            "ACWR \(Self.decimal($0, places: 2)), \(band.rawValue)"
        } ?? "ACWR unavailable because there is no load data yet.")
    }

    private func phaseSummary(_ snapshot: ReadinessWidgetSnapshot) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(phaseColor(snapshot.phaseColorHex))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("TRAINING BLOCK")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                if let phaseName = snapshot.phaseName {
                    Text(phaseName)
                        .font(.caption.weight(.semibold))
                    if let week = snapshot.phaseWeek, let day = snapshot.phaseDay {
                        Text("Week \(week) · Day \(day)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Unavailable")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(snapshot.phaseName.map {
            "Training block \($0)" + (snapshot.phaseWeek.map { ", week \($0)" } ?? "")
        } ?? "Training block unavailable")
    }

    private func semanticColor(_ token: ReadinessWidgetSemanticToken) -> Color {
        Color(widgetHex: colorScheme == .dark ? token.darkHex : token.lightHex)
    }

    private func phaseColor(_ hex: String?) -> Color {
        guard let hex, hex.hasPrefix("#") else { return semanticColor(.reference) }
        return Color(widgetHex: hex)
    }

    private static func decimal(_ value: Double, places: Int) -> String {
        String(
            format: "%.*f",
            locale: Locale(identifier: "en_US_POSIX"),
            arguments: [places, value]
        )
    }
}

private extension Color {
    init(widgetHex: String) {
        let cleaned = widgetHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red: UInt64
        let green: UInt64
        let blue: UInt64
        switch cleaned.count {
        case 3:
            red = ((value >> 8) & 0xF) * 17
            green = ((value >> 4) & 0xF) * 17
            blue = (value & 0xF) * 17
        default:
            red = (value >> 16) & 0xFF
            green = (value >> 8) & 0xFF
            blue = value & 0xFF
        }
        self.init(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255
        )
    }
}
