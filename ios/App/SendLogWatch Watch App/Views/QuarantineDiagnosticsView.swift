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
    @State private var unscopedTotal: Int?
    @State private var entries: [QuarantineDiagnosticEntry] = []
    /// #606: the quarantine-exit breadcrumb ring, newest first for display —
    /// the "recent history" of records that LEFT quarantine (manually or by
    /// the automatic resurrection), so a resolved incident stays diagnosable.
    @State private var breadcrumbs: [QuarantineBreadcrumbEntry] = []
    @State private var isLoading = true
    /// #600: the manual retry's in-flight/result state — set by the retry
    /// action, cleared by the next load.
    @State private var isRetrying = false
    @State private var retrySummary: String?
    /// How many records the LAST retry pass actually restored — drives the
    /// result banner's tone, because a zero-restore outcome is NOT a success
    /// (review finding 2). Retired on the next `load()`.
    @State private var lastRetryRestored: Int?

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                summaryCard

                if let unscopedTotal, unscopedTotal > 0 {
                    WatchStateBanner(
                        state: .warning,
                        title: "Legacy uploads need review",
                        message: "\(unscopedTotal) watch item\(unscopedTotal == 1 ? "" : "s") have no account stamp. They are retained here but will not upload until an explicit recovery path can identify their owner."
                    )
                }

                historyCard

                if retryableCount > 0 {
                    retryCard
                }

                if let retrySummary {
                    let retrySucceeded = (lastRetryRestored ?? 0) > 0
                    // #600 review finding 2: zero restored is not a success —
                    // the banner must say so with tone and title, or a failed
                    // pass reads as a completed one.
                    WatchStateBanner(
                        state: retrySucceeded ? .success : .warning,
                        title: retrySucceeded ? "Retried" : "Nothing was retried",
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
        async let exitWorkouts = OfflineQueue.shared.quarantineExitHistory()
        async let exitSessions = PendingSessionQueue.shared.quarantineExitHistory()
        async let exitRecordings = PendingRecordingQueue.shared.quarantineExitHistory()
        let merged = await (workouts, sessions, recordings, terminal)
        let exits = await (exitWorkouts + exitSessions + exitRecordings)
        quarantinedTotal = caches.quarantinedTotal
        quarantinedStuckTotal = caches.quarantinedStuckTotal
        unscopedTotal = caches.unscopedTotal
        entries = [merged.0, merged.1, merged.2, merged.3].flatMap { $0 }
        breadcrumbs = exits.sorted { $0.exitedAt > $1.exitedAt }
        isLoading = false
    }

    /// #600: how many listed records are worth a manual retry — the button
    /// only exists when this is positive. `.schemaRejection` items are
    /// proven permanent and are never offered as an equal option.
    private var retryableCount: Int {
        entries.filter {
            if case .record(let item) = $0 { return QuarantineRetryPolicy.isManuallyRetryable(item.reason) }
            return false
        }.count
    }

    /// Issue #600: the manual retry. Every queue's engine restores its own
    /// retryable records (crash-safely), republishes the counts and tells
    /// the phone, then drains — this view then reloads against post-retry
    /// reality and reports what stayed behind.
    private func retryStuckUploads() async {
        guard !isRetrying else { return }
        isRetrying = true
        async let workouts = OfflineQueue.shared.retryQuarantinedItems()
        async let sessions = PendingSessionQueue.shared.retryQuarantinedItems()
        async let recordings = PendingRecordingQueue.shared.retryQuarantinedItems()
        async let terminal = LiveWorkoutTerminalRetry.shared.retryQuarantinedItems()
        let restored = await (workouts + sessions + recordings + terminal)
        // The guard stays armed through the reload (review finding 3): the
        // button must not come back live before the view reflects the pass
        // it just ran, or a second tap starts another pass mid-refresh.
        await load()
        isRetrying = false
        lastRetryRestored = restored
        // `kept` is the retry CANDIDATES the reload still finds quarantined —
        // a restore the disk refused (the only way a candidate survives).
        // Permanent rejections, unreadable records and other-account items
        // were never candidates and must not read as "attempted and refused".
        let kept = retryableCount
        retrySummary = QuarantineRetryPolicy.resultSummary(restored: restored, kept: kept)
    }

    // MARK: - Recent history (#606)

    /// Records that LEFT quarantine (manual retry or the automatic weekly
    /// resurrection) — kept even after the upload succeeds, because a
    /// RESOLVED incident is the one that most needs explaining afterwards.
    /// Hidden entirely when empty: an empty ring is not a state to read
    /// anything from (the same quiet-when-empty rule as the queue depth
    /// lines), and this card is about the past, not the present.
    @ViewBuilder
    private var historyCard: some View {
        if !breadcrumbs.isEmpty {
            WatchCard(accent: WatchPalette.secondary) {
                VStack(alignment: .leading, spacing: 4) {
                    WatchEyebrow(text: "Recent history")
                    Text("\(breadcrumbs.count) upload\(breadcrumbs.count == 1 ? "" : "s") left quarantine")
                        .font(.system(.footnote, design: .rounded).weight(.bold))
                    Text("Most recent: \(historyLine(breadcrumbs[0]))")
                        .font(.caption2)
                        .foregroundStyle(WatchPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Index identity, not the entry's id: the SAME item can
                    // legitimately exit quarantine more than once within the
                    // ring (a weekly F12 resurrection, a retry→re-quarantine
                    // cycle), so `id: \.id` would violate ForEach's
                    // unique-IDs precondition. Same pattern as the entry
                    // cards below.
                    ForEach(breadcrumbs.dropFirst().indices, id: \.self) { index in
                        Text(historyLine(breadcrumbs[index]))
                            .font(.caption2)
                            .foregroundStyle(WatchPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// One breadcrumb's line: the factual failure summary (stage / HTTP /
    /// code — `QuarantineBreadcrumbs.failureSummary`) plus when it exited,
    /// e.g. "stage session, HTTP 403 · 12 Aug 20:22". A failure that reached
    /// no server has no summary; the date alone still anchors it.
    private func historyLine(_ entry: QuarantineBreadcrumbEntry) -> String {
        let summary = QuarantineBreadcrumbs.failureSummary(for: entry)
        let date = dateText(entry.exitedAt)
        return summary.isEmpty ? date : "\(summary) · \(date)"
    }

    // MARK: - Retry card (#600)

    @ViewBuilder
    private var retryCard: some View {
        WatchCard(accent: WatchPalette.primary) {
            VStack(alignment: .leading, spacing: 6) {
                Text(QuarantineRetryPolicy.retryActionTitle)
                    .font(.system(.footnote, design: .rounded).weight(.bold))
                    .foregroundStyle(WatchPalette.foreground(WatchDesignTokens.primary))
                Text(QuarantineRetryPolicy.retryActionDetail)
                    .font(.caption2)
                    .foregroundStyle(WatchPalette.textSecondary)
                if isRetrying {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text("Retrying…")
                            .font(.caption2)
                            .foregroundStyle(WatchPalette.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: CGFloat(WatchDesignTokens.minimumHitTarget), alignment: .leading)
                } else {
                    Button {
                        Task { await retryStuckUploads() }
                    } label: {
                        Text("Retry \(retryableCount) upload\(retryableCount == 1 ? "" : "s")")
                            .font(.system(.footnote, design: .rounded).weight(.bold))
                            .frame(maxWidth: .infinity, minHeight: CGFloat(WatchDesignTokens.minimumHitTarget))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(WatchPalette.primary)
                    .accessibilityIdentifier("quarantine-retry-button")
                    .accessibilityHint("Tries the retryable uploads again now instead of waiting for the automatic retry")
                }
            }
        }
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
    ///
    /// Never collapses an unknown breakdown into a zero (review nit): if the
    /// `.stuckRetrying` slot hasn't reported, saying "0 retrying
    /// automatically" would invent a fact — the honest sentence says the
    /// breakdown isn't reported yet.
    private func splitSummary(total: Int) -> String {
        guard let stuck = quarantinedStuckTotal else {
            return "The retry breakdown hasn't been reported yet."
        }
        var parts: [String] = []
        if stuck > 0 {
            parts.append("\(stuck) retrying automatically")
        }
        let permanent = max(0, total - stuck)
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
            fieldLine("Quarantined", dateText(item.quarantinedAt))
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

    private func dateText(_ date: Date) -> String {
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
