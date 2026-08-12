import SendLogWatchCore
import SwiftUI

/// Issue #599: the watch-side diagnostics surface for quarantined uploads —
/// items `UploadQueueEngine` took OFF the ordinary drain path (#475). This is
/// the surface the phone's History banner describes: without it, the phone can
/// say "1 workout stuck" while the watch — the device that holds the data —
/// shows nothing at all, so the warning reads as a phantom and gets ignored.
///
/// Honest-states rules carried through from `PendingSyncCache` and the
/// phone's `uploadWarningPresentation` (CLAUDE.md #264):
/// - A quarantined item is NEVER phrased as "waiting to upload" or "will
///   sync". The two `QuarantineReason` cases get the same split the phone
///   already makes: `.schemaRejection` = "will not retry", `.stuckRetrying` =
///   "retrying automatically".
/// - Never-counted renders as "not reported", never as zero — the totals come
///   from `PendingSyncCache`, which keeps every total nil until all four
///   queues have published.
/// - An unreadable `.quarantine` file is retained on disk (#287) and listed
///   as unreadable rather than silently vanishing.
struct QuarantineDiagnosticsView: View {
    /// Total across both reasons — nil = "not reported" (honest unknown),
    /// never rendered as zero.
    @State private var quarantinedTotal: Int?
    @State private var quarantinedStuckTotal: Int?
    @State private var entries: [QuarantineDiagnosticEntry] = []
    @State private var isLoading = true
    /// #600: the manual retry's in-flight/result state — set by the retry
    /// action, cleared by the next load.
    @State private var isRetrying = false
    @State private var retrySummary: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                summaryCard

                if let retrySummary {
                    WatchStateBanner(
                        state: .success,
                        title: "Retried",
                        message: retrySummary
                    )
                }

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else if entries.isEmpty {
                    emptyCard
                } else {
                    ForEach(entries.indices, id: \.self) { index in
                        entryCard(entries[index])
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, 4)
        .watchCanvas()
        .navigationTitle("Quarantined uploads")
        .task { await load() }
    }

    /// Count every queue first so the cache totals are complete, then read
    /// the per-item list. The counts are display-only here; the phone hears
    /// the same refresh via `WatchBuild.reportQueueStatus`.
    private func load() async {
        isLoading = true
        retrySummary = nil
        await WatchBuild.refreshAndReportQueueStatus()
        let caches = PendingSyncCache.shared
        async let workouts = OfflineQueue.shared.quarantinedDiagnostics()
        async let sessions = PendingSessionQueue.shared.quarantinedDiagnostics()
        async let recordings = PendingRecordingQueue.shared.quarantinedDiagnostics()
        async let terminal = LiveWorkoutTerminalRetry.shared.quarantinedDiagnostics()
        let merged = await (workouts, sessions, recordings, terminal)
        quarantinedTotal = caches.quarantinedTotal
        quarantinedStuckTotal = caches.quarantinedStuckTotal
        entries = [merged.0, merged.1, merged.2, merged.3].flatMap { $0 }
        isLoading = false
    }

    // MARK: - Summary

    @ViewBuilder
    private var summaryCard: some View {
        WatchCard(accent: WatchPalette.warning) {
            VStack(alignment: .leading, spacing: 4) {
                WatchEyebrow(text: "Off the upload path")
                if let quarantinedTotal {
                    if quarantinedTotal == 0 {
                        Text("No quarantined uploads")
                            .font(.system(.footnote, design: .rounded).weight(.bold))
                        Text("Everything is on the ordinary upload path.")
                            .font(.caption2)
                            .foregroundStyle(WatchPalette.textSecondary)
                    } else {
                        Text("\(quarantinedTotal) upload\(quarantinedTotal == 1 ? "" : "s") set aside")
                            .font(.system(.footnote, design: .rounded).weight(.bold))
                        Text(splitSummary(total: quarantinedTotal))
                            .font(.caption2)
                            .foregroundStyle(WatchPalette.textSecondary)
                        // #264: "set aside" means exactly that — never
                        // "waiting to upload". The split sentence is the
                        // phone's `uploadWarningPresentation` wording
                        // mirrored on the wrist.
                    }
                } else {
                    Text("Not reported")
                        .font(.system(.footnote, design: .rounded).weight(.bold))
                    Text("The queues haven't been counted yet. Refresh this screen to read them.")
                        .font(.caption2)
                        .foregroundStyle(WatchPalette.textSecondary)
                }
            }
        }
    }

    /// The reason split — `.stuckRetrying` gets the automatic-retry wording,
    /// the rest (`.schemaRejection` plus any unreadable record, which is
    /// counted as the cautious schema-like default by `quarantinedCount`)
    /// gets the "will not retry" wording. Mirrors the phone split exactly.
    private func splitSummary(total: Int) -> String {
        let stuck = quarantinedStuckTotal ?? 0
        let permanent = max(0, total - stuck)
        var parts: [String] = []
        if stuck > 0 {
            parts.append("\(stuck) retrying automatically")
        }
        if permanent > 0 {
            parts.append("\(permanent) will not retry")
        }
        let unreadable = entries.filter { if case .unreadable = $0 { return true } else { return false } }.count
        if unreadable > 0 {
            parts.append("\(unreadable) unreadable")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var emptyCard: some View {
        WatchCard {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nothing here")
                    .font(.system(.footnote, design: .rounded).weight(.bold))
                Text("No quarantined uploads are stored on this watch.")
                    .font(.caption2)
                    .foregroundStyle(WatchPalette.textSecondary)
            }
        }
    }

    // MARK: - Per-item rows

    @ViewBuilder
    private func entryCard(_ entry: QuarantineDiagnosticEntry) -> some View {
        switch entry {
        case .record(let item):
            WatchCard(accent: accent(for: item.reason)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(QuarantineCopy.title(for: item.reason))
                        .font(.system(.footnote, design: .rounded).weight(.bold))
                        .foregroundStyle(WatchPalette.foreground(for: state(for: item.reason)))
                    Text(QuarantineCopy.detail(for: item.reason))
                        .font(.caption2)
                        .foregroundStyle(WatchPalette.textSecondary)
                    fieldLines(item)
                }
            }
        case .unreadable(let id):
            WatchCard(accent: WatchPalette.danger) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Unreadable record")
                        .font(.system(.footnote, design: .rounded).weight(.bold))
                    Text("The record can't be read by this build. It is kept on the watch (#287); a newer build may be able to recover it.")
                        .font(.caption2)
                        .foregroundStyle(WatchPalette.textSecondary)
                    Text("id \(id.uuidString.prefix(8))")
                        .font(.caption2)
                        .foregroundStyle(WatchPalette.textTertiary)
                }
            }
        }
    }

    /// The item's factual header, one line per field that exists — nothing
    /// invented for a nil field. `errorMessage` arrives already truncated.
    @ViewBuilder
    private func fieldLines(_ item: QuarantineDiagnosticItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let stage = item.stage {
                fieldLine("Stage", stageDisplayName(stage))
            }
            if let httpStatus = item.httpStatus {
                fieldLine("HTTP", "\(httpStatus)")
            }
            if let postgrestCode = item.postgrestCode {
                fieldLine("Code", postgrestCode)
            }
            if let errorMessage = item.errorMessage {
                fieldLine("Error", errorMessage)
            }
            if let attemptCount = item.attemptCount {
                fieldLine("Attempts", "\(attemptCount)")
            }
            fieldLine("Quarantined", quarantinedAtText(item.quarantinedAt))
            if item.payloadDropped == true {
                fieldLine("Note", QuarantineCopy.payloadDroppedNote)
            }
        }
    }

    @ViewBuilder
    private func fieldLine(_ label: String, _ value: String) -> some View {
        Text("\(label): \(value)")
            .font(.caption2)
            .foregroundStyle(WatchPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func stageDisplayName(_ stage: UploadStage) -> String {
        switch stage {
        case .session: "Session insert"
        case .climbWorkout: "Workout insert"
        case .climbAttempts: "Attempts insert"
        }
    }

    private func quarantinedAtText(_ date: Date) -> String {
        // Display-only formatting: still Gregorian + POSIX so a Buddhist-
        // calendar region shows an AD date (CLAUDE.md's date rule), but local
        // time — this is for the user's own eyes, not storage.
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter.string(from: date)
    }

    private func accent(for reason: QuarantineReason) -> Color {
        switch reason {
        case .schemaRejection: WatchPalette.danger
        case .stuckRetrying: WatchPalette.warning
        }
    }

    private func state(for reason: QuarantineReason) -> WatchVisualState {
        switch reason {
        case .schemaRejection: .danger
        case .stuckRetrying: .warning
        }
    }
}
