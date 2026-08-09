import SendLogWatchCore
import SwiftUI

/// Page 1 of the watch home (#278): today's glanceable status — readiness and
/// ACWR — the two numbers worth a wrist-raise before deciding what to do.
///
/// Renders straight out of the App Group snapshot, the same one the
/// complications read: `WidgetBridge.refreshStatus()` already fetches the
/// iPhone-computed readiness row and computes ACWR on-watch, so this page adds
/// no second fetch path — it shows what's cached, asks for a refresh on appear
/// and on foreground, and re-reads.
///
/// SendLogWatchApp also refreshes on foreground (for the complications, which
/// need it whether or not this page is on screen), so a foreground costs two
/// round trips rather than one. Deliberate: they're two small queries, and the
/// alternative — reading the store and hoping the app-level refresh has already
/// landed — is exactly the staleness this page is supposed to avoid.
///
/// `ReadinessManager` deliberately isn't used here: it covers readiness only,
/// and mixing it with the snapshot's ACWR would put two sources of truth on one
/// screen, free to disagree.
struct StatusView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var snap = ScreenshotFixtures.enabled
        ? ScreenshotFixtures.status
        : WidgetStore.load()
    @State private var refreshing = false
    @State private var refreshState: WatchStatusRefreshState = .notAttempted

    private var statusChip: (state: WatchVisualState, title: String) {
        if refreshing || ScreenshotFixtures.state == .statusSyncing {
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
        switch refreshState {
        case .synced:
            return (.ready, "Synced")
        case .cached, .notAttempted:
            return snap.updatedAt == 0 ? (.warning, "No data") : (.cached, "Cached")
        case .offline:
            return (.offline, "Offline")
        case .refreshing:
            return (.syncing, "Updating")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center) {
                    WatchEyebrow(text: "Today")
                    Spacer(minLength: 4)
                    WatchStateChip(state: statusChip.state, title: statusChip.title, compact: true)
                }
                WatchCard(accent: readinessColor(snap.readinessZone, reducedLuminance: isLuminanceReduced)) {
                    readiness
                }
                WatchCard(accent: acwrColor(
                    StatusPresentation.acwrRiskBand(snap.acwr),
                    reducedLuminance: isLuminanceReduced
                )) {
                    acwr
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .watchCanvas()
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    // MARK: Blocks

    private var readiness: some View {
        VStack(alignment: .leading, spacing: 4) {
            eyebrow("READINESS")
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
                            .foregroundStyle(readinessColor(
                                snap.readinessZone,
                                reducedLuminance: isLuminanceReduced
                            ))
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
                    .foregroundStyle(acwrColor(risk, reducedLuminance: isLuminanceReduced))
                if let risk {
                    Text(risk.label)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(acwrColor(risk, reducedLuminance: isLuminanceReduced))
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

    // MARK: Refresh

    private func refresh() async {
        // Fastlane launches the real view hierarchy with deterministic data.
        // Do not replace that fixture with an unauthenticated network result.
        guard !ScreenshotFixtures.enabled else { return }
        guard !refreshing else { return }
        refreshing = true
        refreshState = .refreshing
        defer { refreshing = false }
        let outcome = await WidgetBridge.refreshStatus()
        snap = WidgetStore.load()
        refreshState = .after(outcome, hasCachedSnapshot: snap.updatedAt > 0)
    }
}
