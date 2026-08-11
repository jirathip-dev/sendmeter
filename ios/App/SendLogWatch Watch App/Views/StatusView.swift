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

    /// The line the readiness card renders below the ring/zone (`readiness`,
    /// below) — production always shows it; fixtures used to suppress it
    /// entirely, which is how #539 round 1 shipped a regression guard that
    /// measured a card production never renders (round-1 review F1). Kept
    /// alongside `statusChip` since both come from the same underlying
    /// `ReadinessManager.syncState`/`ScreenshotFixtureState` pairing.
    private var statusSyncLabel: String {
        ScreenshotFixtures.enabled ? ScreenshotFixtures.statusSyncLabel : readinessManager.syncLabel
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
            case .statusAuthRequired:
                return (.warning, "Phone needed")
            case .statusUnsupported:
                return (.warning, "Update phone")
            case .statusFailed:
                return (.warning, "Retry")
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
                // #539 round-1 review F1: tighter padding than the default
                // 11pt — this card gained back its sync-status line (see
                // `readiness`, below), and the reclaimed points keep the
                // full production card, not a shortened stand-in, inside the
                // 40/41mm first viewport.
                WatchCard(
                    accent: readinessAccent(snap.readinessZone, reducedLuminance: isLuminanceReduced),
                    // The empty/offline guidance is two lines on a 40mm
                    // watch. Keep the scored card's established rhythm, but
                    // reclaim the minimum space needed for that guidance
                    // before the card reaches the paged viewport edge.
                    padding: snap.readiness == nil ? 4 : 9
                ) {
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
            .padding(.top, 1)
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
        VStack(alignment: .leading, spacing: snap.readiness == nil ? 0 : 2) {
            // #539 round-1 review F3: on 40mm the longest real chip titles
            // ("Phone needed", "Update phone") sat flush against the card's
            // inner padding next to the decorative eyebrow, with no slack.
            // A `ViewThatFits` stacked-header fallback was tried first, but
            // its "fits" test uses each Text's un-scaled ideal width, so it
            // fell back for nearly every real title (not just the longest
            // ones) and pushed the whole card ~20pt taller in the common
            // case — a worse regression than the one being fixed. Giving the
            // chip layout priority instead means it keeps its full size
            // under compression and "READINESS" (redundant with the card's
            // own obvious content) shrinks first via its existing
            // `minimumScaleFactor`.
            HStack(alignment: .center) {
                eyebrow("READINESS")
                Spacer(minLength: 4)
                WatchStateChip(state: statusChip.state, title: statusChip.title, compact: true)
                    .layoutPriority(1)
            }
            HStack(spacing: snap.readiness == nil ? 8 : 10) {
                ReadinessRingView(
                    score: snap.readiness,
                    zone: snap.readinessZone,
                    lineWidth: 7,
                    valueFontSize: 25,
                    // The visible guidance below is the single VoiceOver
                    // announcement for an empty score; keeping the same copy
                    // on both this ring and the text would announce it twice.
                    emptyAccessibilityHint: nil
                )
                .frame(
                    // The empty-state ring is intentionally lighter than the
                    // scored ring: on 40mm the two-line phone-sync guidance
                    // must remain inside the first viewport, including its
                    // bottom edge. The ring still has enough room for the
                    // neutral outline and dash to read at a glance.
                    width: snap.readiness == nil ? 40 : 68,
                    height: snap.readiness == nil ? 40 : 68
                )

                VStack(alignment: .leading, spacing: snap.readiness == nil ? 0 : 2) {
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
            // Mutually exclusive with the sync-status line below: while
            // readiness is nil the two would say almost the same thing
            // ("Open Sendmeter…" vs. `syncLabel`'s "Waiting for iPhone"/
            // "Offline · no score yet") — showing both was redundant AND,
            // discovered while re-verifying #539 round-1 fixes, the
            // unbounded wrap on this hint plus the sync line together pushed
            // this card ~50pt past the viewport on 40mm.
            if snap.readiness == nil {
                // This is intentionally a visible, identifiable line rather
                // than the generic VoiceOver-hidden `hint()` helper: the
                // readiness ring carries only "No data" here, so the full
                // phone-sync instruction is announced once and can be
                // asserted as content by the screenshot suite.
                readinessEmptyHint
            } else {
                // #539 round-1 review F1: this used to be `.fixedSize(vertical:
                // true)` (wrap, never truncate) and was suppressed entirely
                // under fixtures/UI tests, so nothing ever exercised its real
                // length — several real `syncLabel` strings (`.authRequired`,
                // `.failed`, `.unsupported`) wrap to two lines at this width
                // and pushed the card past the viewport, the exact bug #539
                // was filed for. Bounded to one line + tail truncation so the
                // card's height can never depend on this string's length; the
                // full text still reaches VoiceOver via `accessibilityLabel`.
                // Rendered whenever there's a score now (fixture-aware via
                // `statusSyncLabel`) so the fixture path measures the same
                // card production renders.
                Text(statusSyncLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("status-sync-label")
                    .accessibilityLabel(statusSyncLabel)
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
            // #539 round-1 review F1: unbounded wrap on this VoiceOver-hidden
            // hint (the ring's own accessibilityHint already carries the full
            // text) was, together with the sync-status line, the dominant
            // contributor to the readiness card's worst-case overflow —
            // capped regardless of Dynamic Type, since this is the one
            // dynamic-style (`.caption2`) font on the card and would grow
            // further at an accessibility size otherwise.
            .lineLimit(2)
            .accessibilityHidden(true)
    }

    /// Empty readiness guidance is intentionally a visible, identifiable
    /// element: the ring carries only "No data" accessibility now, so this
    /// copy is announced once and the screenshot suite can prove it stayed in
    /// the first viewport (#539).
    private var readinessEmptyHint: some View {
        Text("Open Sendmeter on your iPhone to sync Health")
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundStyle(WatchPalette.textTertiary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("readiness-empty-guidance")
            .accessibilityLabel("Open Sendmeter on your iPhone to sync Health")
    }

}
