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
    @State private var snap = WidgetStore.load()
    @State private var refreshing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                readiness
                Divider()
                acwr
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    // MARK: Blocks

    private var readiness: some View {
        VStack(alignment: .leading, spacing: 1) {
            eyebrow("READINESS")
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                value(
                    snap.readiness.map(String.init),
                    color: readinessColor(snap.readinessZone)
                )
                if let zone = snap.readinessZone, snap.readiness != nil {
                    Text(zone)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            // Honest empty state: readiness stays nil until the iPhone syncs
            // Health, and a zeroed gauge would read as "you're wrecked".
            if snap.readiness == nil {
                hint("Open Sendmeter on your iPhone to sync Health")
            }
        }
    }

    private var acwr: some View {
        VStack(alignment: .leading, spacing: 1) {
            eyebrow("ACWR")
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                value(
                    snap.acwr.map { String(format: "%.2f", $0) },
                    color: acwrColor(snap.acwrRisk)
                )
                if let risk = snap.acwrRisk, snap.acwr != nil {
                    Text(risk)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if snap.acwr == nil {
                hint("Not enough logged sessions yet")
            }
        }
    }

    // MARK: Pieces

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
    }

    /// The number, or an em dash when we haven't got one. A missing value is
    /// drawn muted rather than in its zone/risk colour — an unknown must not
    /// borrow the look of a real reading.
    private func value(_ text: String?, color: Color) -> some View {
        Text(text ?? "—")
            .font(.system(size: 36, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(text == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(color))
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Refresh

    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await WidgetBridge.refreshStatus()
        snap = WidgetStore.load()
    }
}
