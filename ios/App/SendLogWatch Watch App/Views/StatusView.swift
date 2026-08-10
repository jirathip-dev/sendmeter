import SendLogWatchCore
import SwiftUI

/// Page 1 of the watch home (#278): today's glanceable status — readiness and
/// ACWR — the two numbers worth a wrist-raise before deciding what to do.
///
/// Renders straight out of the App Group snapshot, the same one the
/// complications read. `ReadinessManager` requests the iPhone-owned HealthKit
/// sync and applies its typed result to this snapshot; ACWR remains the
/// independent watch-local calculation. Cached values stay visible while a
/// request is in flight or the phone is offline.
struct StatusView: View {
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(ReadinessManager.self) private var readinessManager

    private var snap: WidgetSnapshot {
        ScreenshotFixtures.enabled ? ScreenshotFixtures.status : readinessManager.snapshot
    }

    private var statusChip: (state: WatchVisualState, title: String) {
        if ScreenshotFixtures.state == .statusSyncing {
            return (.syncing, "Updating")
        }
        if ScreenshotFixtures.enabled {
            switch ScreenshotFixtures.state {
            case .statusOffline:
                return (.offline, "Offline")
            case .statusCached:
                return (.cached, "Cached")
            case .statusEmpty:
                return (.warning, "No data")
            case .status:
                // The normal fixture has no network task by design; keep the
                // curated screenshot's completed state deterministic.
                return (.ready, "Synced")
            default:
                break
            }
        }
        switch readinessManager.syncState {
        case .fresh:
            return (.ready, "Synced")
        case .cached, .idle:
            return snap.updatedAt == 0 ? (.warning, "No data") : (.cached, "Cached")
        case .offline:
            return (.offline, "Offline")
        case .syncing:
            return (.syncing, "Updating")
        case .authRequired:
            return (.warning, "Phone needed")
        case .failed:
            return (.warning, "Retry")
        case .unsupported:
            return (.warning, "Update phone")
        }
    }

    var body: some View {
        ScrollView {
            // #539: a standalone "Today" + sync-chip row above these cards
            // pushed the readiness card below the first-viewport fold on
            // 40/41mm watches. The chip now sits in the readiness card's own
            // header (below) instead of costing its own row + spacing gap.
            VStack(alignment: .leading, spacing: 6) {
                WatchCard(accent: readinessAccent(snap.readinessZone, reducedLuminance: isLuminanceReduced)) {
                    readiness
                }
                WatchCard(accent: acwrAccent(
                    StatusPresentation.acwrRiskBand(snap.acwr),
                    reducedLuminance: isLuminanceReduced
                )) {
                    acwr
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .watchCanvas()
        .task {
            guard !ScreenshotFixtures.enabled else { return }
            readinessManager.request(reason: .statusRefresh)
        }
    }

    // MARK: Blocks

    private var readiness: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                eyebrow("READINESS")
                Spacer(minLength: 4)
                WatchStateChip(state: statusChip.state, title: statusChip.title, compact: true)
            }
            HStack(spacing: 10) {
                ReadinessRingView(
                    score: snap.readiness,
                    zone: snap.readinessZone,
                    lineWidth: 7,
                    valueFontSize: 25,
                    emptyAccessibilityHint: "Open Sendmeter on your iPhone to sync Health"
                )
                .frame(width: 68, height: 68)

                VStack(alignment: .leading, spacing: 2) {
                    if let zone = StatusPresentation.readinessZoneLabel(snap.readinessZone),
                       snap.readiness != nil {
                        Text(zone)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(readinessColor(snap.readinessZone))
                    } else if snap.readiness != nil {
                        Text("Zone unavailable")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No score")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text("0–100")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .accessibilityHidden(true)
            }
            // Honest empty state: readiness stays nil until the iPhone syncs
            // Health; the ring helper draws a neutral outline, not a zero.
            if snap.readiness == nil {
                hint("Open Sendmeter on your iPhone to sync Health")
            }
            if !ScreenshotFixtures.enabled {
                Text(readinessManager.syncLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(readinessManager.syncLabel)
            }
        }
    }

    private var acwr: some View {
        let risk = StatusPresentation.acwrRiskBand(snap.acwr)
        return VStack(alignment: .leading, spacing: 4) {
            eyebrow("ACWR")
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(snap.acwr.map { String(format: "%.2f", $0) } ?? "—")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(acwrColor(risk))
                if let risk {
                    Text(risk.label)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(acwrColor(risk))
                }
            }
            .accessibilityHidden(true)

            ACWRRiskTrackView(
                value: snap.acwr,
                bandHeight: 8,
                emptyAccessibilityHint: "Not enough logged sessions yet"
            )

            HStack {
                Text("0")
                Spacer()
                Text("2")
            }
            .font(.system(size: 8, weight: .medium, design: .rounded))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)

            if snap.acwr == nil {
                hint("Not enough logged sessions yet")
            }
        }
    }

    // MARK: Pieces

    private func eyebrow(_ text: String) -> some View {
        WatchEyebrow(text: text)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption2, design: .rounded))
            .foregroundStyle(WatchPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
    }

}
