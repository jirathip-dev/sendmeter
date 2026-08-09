import Combine
import SendLogWatchCore
import SwiftUI

private let SIDE_OPTIONS: [(value: String, label: String)] = [
    ("", "—"),
    ("left", "Left"),
    ("right", "Right"),
    ("both", "Both"),
]

private let LAST_TAG_KEY = "lastTindeqTag"
private let LAST_SIDE_KEY = "lastTindeqSide"

struct ForceGaugeView: View {
    // App-level so the connection + gauge session survive leaving this screen
    // (SL-58 #5). The finish prompt is presented from RootView.
    @Environment(TindeqManager.self) private var tindeq
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sparkSamples: [(t: Double, kg: Double)] = []

    // Exercise setup — set once before the first rep, tweak side between reps.
    // Stop always saves with whatever tag/side is set (no post-stop decision).
    @State private var tag = ""
    @State private var side = ""
    @State private var recentTags: [String] = []
    // SL-75: the one-shot fetch used to lose the auth race → "no tags yet"
    // even though the phone had plenty, and the silent first-tag default then
    // mislabeled the rep. Now: retried fetch with a visible loading state,
    // and only the persisted LAST-USED tag is auto-picked — never the first
    // of the list.
    @State private var tagsLoading = true
    @State private var tagFetchTask: Task<Void, Never>?
    // Bumped on every loadTags() call so a superseded fetch (cancelled
    // because a newer one started) never stomps on the current one's
    // tagsLoading flag — issue #147's leaked-spinner fix.
    @State private var tagFetchGeneration = 0

    private let sparkTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    private var fixtureVisual: ScreenshotForceVisual? { ScreenshotFixtures.force }
    private var visibleStatus: TindeqManager.Status {
        switch fixtureVisual?.status {
        case .idle: .idle
        case .connecting: .connecting
        case .connected: .connected
        case .measuring: .measuring
        case nil: tindeq.status
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                // Measuring owns the whole screen in a plain, non-scrolling
                // VStack (issue #149) — the live gauge, peak/timer, and Stop
                // & Save must all be visible at once without hunting for a
                // scroll position mid-hang. Every other state keeps the
                // ScrollView (loading/empty/error states legitimately may
                // need it).
                if visibleStatus == .measuring {
                    VStack(spacing: 4) {
                        measuringContent
                    }
                } else {
                    ScrollView {
                        // Tightened from 8 (issue #149 follow-up): the setup +
                        // session-bar + saved-message combination between reps
                        // is the mainline flow, not a rare edge case — every
                        // point here counts toward fitting a 41mm screen.
                        VStack(spacing: 4) {
                            Color.clear.frame(height: 1).id("gaugeTop")
                            // Session controls hide while measuring — the live gauge owns
                            // the screen; they come back the moment the rep stops.
                            if visibleStatus != .unsupported && visibleStatus != .measuring {
                                sessionBar
                            }

                            switch visibleStatus {
                            case .unsupported:
                                WatchStateBanner(
                                    state: .danger,
                                    title: "Bluetooth unavailable",
                                    message: tindeq.errorMsg ?? "Turn on Bluetooth to connect a Progressor."
                                )

                            case .idle:
                                WatchCard(accent: WatchPalette.force) {
                                    VStack(alignment: .leading, spacing: 7) {
                                        WatchStateChip(state: .ready, title: "Force gauge ready", compact: true)
                                        Text("Connect your Progressor to measure a repeatable hold.")
                                            .font(.system(.footnote, design: .rounded))
                                            .foregroundStyle(WatchPalette.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Button("Connect Progressor") { tindeq.connect() }
                                    .buttonStyle(WatchPrimaryButtonStyle(tint: WatchPalette.force))
                                if let msg = fixtureVisual?.errorMessage ?? tindeq.errorMsg {
                                    WatchStateBanner(state: .danger, title: "Could not connect", message: msg)
                                }

                            case .scanning, .connecting:
                                WatchLoadingState(
                                    title: tindeq.status == .scanning ? "Scanning for Progressor…" : "Connecting…",
                                    message: "Keep the gauge nearby."
                                )

                            case .connected:
                                setupContent
                                if let msg = fixtureVisual?.errorMessage {
                                    WatchStateBanner(state: .danger, title: "Could not save", message: msg)
                                }

                            case .measuring:
                                // Unreachable — measuring renders in the non-scrolling
                                // branch above; kept only for switch exhaustiveness.
                                EmptyView()
                            }

                            if let savedMsg = fixtureVisual?.savedMessage ?? tindeq.savedMsg {
                                // Least essential line in the stack (issue #149
                                // follow-up) — kept last so it's the first thing
                                // to scroll off if the combo still overflows the
                                // smallest watch, and capped to one line so a
                                // long tag name can't silently wrap into a
                                // second line and blow the budget.
                                WatchStateBanner(
                                    state: tindeq.saving
                                        ? .syncing
                                        : savedMsg.hasPrefix("Rep not saved") ? .danger
                                            : savedMsg.hasPrefix("Saved") ? .success : .warning,
                                    title: savedMsg,
                                    message: nil
                                )
                            }
                        }
                    }
                }
            }
            .onChange(of: tindeq.status) { _, status in
                // Controls show/hide on start/stop, shifting layout — snap back to
                // the top so the live gauge stays in view instead of a blank scroll.
                // Guarded to the scrolling branch: the "gaugeTop" anchor doesn't
                // exist while measuring owns the screen non-scrolling.
                if status != .measuring {
                    if reduceMotion {
                        proxy.scrollTo("gaugeTop", anchor: .top)
                    } else {
                        withAnimation { proxy.scrollTo("gaugeTop", anchor: .top) }
                    }
                }
                // A connect is a fresh chance to win the tag fetch (auth relay may
                // have settled since launch) — but not if a fetch is already in
                // flight (issue #147: restarting a mid-retry fetch here reset its
                // backoff right as the BLE radio got busiest connecting to the
                // Progressor, which is how the loading spinner got stuck).
                if status == .connected
                    && TagFetchPolicy.shouldRestartOnConnect(hasTags: !recentTags.isEmpty, inFlight: tagsLoading) {
                    loadTags()
                }
            }
            // Keep the phone's live Force mirror in sync with the pickers (SL-87).
            .onChange(of: tag) { _, t in tindeq.liveTag = t }
            .onChange(of: side) { _, s in tindeq.liveSide = s }
        }
        .navigationTitle("Force")
        // Hide the nav bar while measuring to reclaim vertical space for the
        // live gauge — it returns the moment the rep stops (status flips back
        // to .connected).
        .toolbar(visibleStatus == .measuring ? .hidden : .visible, for: .navigationBar)
        .watchCanvas()
        .onReceive(sparkTimer) { _ in
            if tindeq.status == .measuring {
                sparkSamples = tindeq.recentSamples()
            }
        }
        .task {
            if let fixtureVisual {
                tag = fixtureVisual.tag
                side = fixtureVisual.side
                recentTags = fixtureVisual.tag.isEmpty ? [] : [fixtureVisual.tag, "Pinch block", "Half crimp"]
                tagsLoading = false
                tindeq.liveTag = tag
                tindeq.liveSide = side
                return
            }
            // Last-used tag/side restore instantly — no network needed to start.
            if tag.isEmpty { tag = UserDefaults.standard.string(forKey: LAST_TAG_KEY) ?? "" }
            if side.isEmpty { side = UserDefaults.standard.string(forKey: LAST_SIDE_KEY) ?? "" }
            tindeq.liveTag = tag
            tindeq.liveSide = side
            loadTags()
        }
        .onDisappear { tagFetchTask?.cancel() }
        // No .onDisappear disconnect — the connection persists across navigation
        // (SL-58 #5); it drops only on a real BLE loss, which prompts to finish.
    }

    /// Fetch the tag list with retries — a cold launch can lose the race with
    /// the auth relay, which used to leave "no tags yet" stuck on screen.
    /// Only a NON-EMPTY successful fetch is treated as a confirmed visible-tag
    /// set for `reconcileLastTag` (SL-94): under RLS an *unauthenticated*
    /// select returns an empty success, not an error, so an empty result is
    /// indistinguishable from the SL-75 auth race — trusting it would wipe a
    /// perfectly valid persisted tag on a slow cold launch. A genuine
    /// hide/rename still reconciles, since the other visible tags come back.
    private func loadTags() {
        tagFetchTask?.cancel()
        tagsLoading = true
        tagFetchGeneration += 1
        let generation = tagFetchGeneration
        tagFetchTask = Task {
            // Leak-proof clear: runs on every exit path (cancellation,
            // break, or falling out of the loop) but only when this task is
            // still the current one — a superseded task must not clear the
            // newer task's in-flight flag (issue #147).
            defer {
                if generation == tagFetchGeneration { tagsLoading = false }
            }
            var fetched: [String]?
            for attempt in 0..<TagFetchPolicy.maxAttempts {
                if Task.isCancelled { return }
                // Per-attempt timeout: this fetch is proxied over the BLE
                // link, so a request stalled by CoreBluetooth scanning/
                // connecting to the Progressor would otherwise ride out
                // URLSession's ~60s default, pinning the spinner for minutes.
                if let tags = try? await withTimeout(
                    seconds: TagFetchPolicy.perAttemptTimeoutSeconds,
                    operation: { try await Repo.fetchRecentTindeqTags() }
                ) {
                    fetched = tags.map(\.name)
                    // Same round trip carries each tag's fitted curve (#280),
                    // which the manager needs to predict the session's RPE.
                    // Merged, never replaced: a later empty/failed fetch must
                    // not drop curves an earlier one already provided.
                    for t in tags { tindeq.tagCurves[t.name] = t }
                    if !tags.isEmpty { break }
                }
                if Task.isCancelled { return }
                if let sleepSeconds = TagFetchPolicy.sleepSeconds(afterAttempt: attempt) {
                    try? await Task.sleep(for: .seconds(sleepSeconds))
                }
            }
            if Task.isCancelled { return }
            recentTags = fetched ?? []
            if let fetched, !fetched.isEmpty { reconcileLastTag(against: fetched) }
        }
    }

    /// SL-94: the persisted last-used tag can go stale if it was renamed or
    /// hidden on the phone since it was saved. Once a fetch has genuinely
    /// confirmed the current visible tag set, drop a selection (and its
    /// persisted default) that no longer appears in it — otherwise Start
    /// would stay enabled with a tag that isn't shown anywhere on screen.
    /// Keeps the SL-75 guard intact: Start is disabled whenever `tag` is
    /// empty, so clearing here re-enables that guard instead of bypassing it.
    private func reconcileLastTag(against visibleTags: [String]) {
        guard TagReconciliation.shouldClearStaleTag(tag, visibleTags: visibleTags) else { return }
        tag = ""
        UserDefaults.standard.removeObject(forKey: LAST_TAG_KEY)
    }

    // MARK: Session bar

    @ViewBuilder
    private var sessionBar: some View {
        // Only shown once a rep has minted the session (auto-group). Before the
        // first save there's nothing to end, so no bar — the gauge just records.
        // Sized down from .footnote (issue #149 follow-up): this bar is visible
        // on the setup screen for every rep after the first, stacked above the
        // pickers + Start, so its own footprint matters just as much as
        // setupContent's for fitting the smallest watch without scrolling.
        if tindeq.sessionId != nil || (fixtureVisual?.sessionCount ?? 0) > 0 {
            WatchCard(accent: WatchPalette.primary) {
                // The chip plus a 44pt Finish target is wider than the inner
                // card on a 40mm watch once the button's label padding is
                // included. ViewThatFits keeps the compact row on Ultra and
                // deliberately stacks it before SwiftUI can compress either
                // essential control on SE.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 7) {
                        sessionChip
                        Spacer(minLength: 0)
                        finishButton
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        sessionChip
                        finishButton
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var sessionChip: some View {
        WatchStateChip(
            state: .ready,
            title: "Session · \(fixtureVisual?.sessionCount ?? tindeq.sessionCount)",
            compact: true
        )
    }

    private var finishButton: some View {
        Button("Finish") { finish() }
            .buttonStyle(WatchSecondaryButtonStyle(tint: WatchPalette.foreground(WatchDesignTokens.primary)))
            .disabled(tindeq.saving)
            .accessibilityIdentifier("force-session-finish")
    }

    private func finish() {
        // A session only exists after ≥1 saved rep, so there's always
        // something to log. #280: no prompt any more — the RPE is predicted
        // from the session's W' depletion and the session logs immediately.
        tindeq.logSessionNow()
    }

    /// Deliberate disconnect (SL-75: there was no button). Logs any saved reps
    /// on the way out so the session isn't orphaned; logging doesn't need the
    /// BLE link, so disconnect right away.
    private func disconnectTapped() {
        tindeq.logSessionNow()
        tindeq.disconnect()
    }

    // MARK: Connected (setup) — fits one page: status, tag/side, Start.

    @ViewBuilder
    private var setupContent: some View {
        // Tighter spacing + small controls so the common path — connected
        // row, 2 pickers, Start — fits a 41mm screen without scrolling
        // (issue #149). This VStack is still a child of the outer
        // ScrollView's VStack, which stays as a fallback: the session bar
        // and saved-message lines (also sized down, issue #149 follow-up)
        // sit outside it, and the saved-message line — deliberately last in
        // the outer stack — is the one that scrolls off first if the
        // smallest watch still can't fit everything at once.
        WatchCard(accent: WatchPalette.force) {
            VStack(spacing: 5) {
                connectionRow

                // Tag is PICK-ONLY on the watch — typing on a watch is miserable and
                // free text drifts from the app's tag set. New tags are created in the
                // iPhone/web Force tab; the watch selects from what already exists.
                if tagsLoading && recentTags.isEmpty {
                    WatchLoadingState(title: "Loading exercises…")
                    sidePickerTitled
                } else if recentTags.isEmpty {
                    WatchStateBanner(
                        state: .warning,
                        title: "No exercises yet",
                        message: "Create an exercise in the iPhone app, then try again.",
                        actionTitle: "Retry",
                        action: { loadTags() }
                    )
                    sidePickerTitled
                } else {
                    // Prefer one row, but let the controls stack when their
                    // measured content cannot fit on a 40mm card. The
                    // navigation links keep their 44pt targets in either
                    // layout, so a narrow display never clips an essential
                    // exercise/side control.
                    compactPickers
                }

                if tindeq.handsFreeRequested {
                    Button { tindeq.cancelHandsFree() } label: {
                        Text(tindeq.saving ? "Saving…" : "Armed — pull to start")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(WatchPrimaryButtonStyle(tint: WatchPalette.success))
                    .disabled(tindeq.saving)
                    .accessibilityHint("Tap to disarm hands-free mode")
                } else {
                    Button { tindeq.start() } label: {
                        Text("Start")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(WatchPrimaryButtonStyle(tint: WatchPalette.force))
                    .disabled(tindeq.saving || tag.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button("Arm hands-free") { tindeq.armHandsFree() }
                        .buttonStyle(WatchSecondaryButtonStyle(tint: WatchPalette.foreground(WatchDesignTokens.secondary)))
                        .disabled(tindeq.saving || tag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if tag.trimmingCharacters(in: .whitespaces).isEmpty && !recentTags.isEmpty {
                    Text("Pick an exercise to start.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The battery label and disconnect action used to compete with the
    /// connected chip for the narrowest card width. ViewThatFits keeps the
    /// compact row on larger watches, then falls back to two short rows before
    /// SwiftUI can truncate or clip the destructive control.
    @ViewBuilder
    private var connectionRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                WatchStateChip(state: .ready, title: "Connected", compact: true)
                Spacer(minLength: 0)
                if tindeq.lowBattery {
                    Label("Low battery", systemImage: "battery.25")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(WatchPalette.foreground(WatchDesignTokens.warning))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                disconnectButton
            }
            HStack(spacing: 4) {
                WatchStateChip(state: .ready, title: "Connected", compact: true)
                Spacer(minLength: 0)
                if tindeq.lowBattery {
                    Image(systemName: "battery.25")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(WatchPalette.foreground(WatchDesignTokens.warning))
                        .frame(width: 22, height: 22)
                        .accessibilityLabel("Low battery")
                }
                disconnectButton
            }
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    WatchStateChip(state: .ready, title: "Connected", compact: true)
                    Spacer(minLength: 0)
                    if tindeq.lowBattery {
                        Image(systemName: "battery.25")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(WatchPalette.foreground(WatchDesignTokens.warning))
                            .frame(width: 22, height: 22)
                            .accessibilityLabel("Low battery")
                    }
                }
                HStack {
                    Spacer(minLength: 0)
                    disconnectButton
                }
            }
        }
    }

    @ViewBuilder
    private var disconnectButton: some View {
        Button {
            disconnectTapped()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(WatchSecondaryButtonStyle(tint: WatchPalette.foreground(WatchDesignTokens.danger)))
        .accessibilityLabel("Disconnect Progressor")
        .accessibilityIdentifier("disconnect-progressor")
    }

    @ViewBuilder
    private var compactPickers: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                exercisePicker
                    .layoutPriority(1)
                sidePickerCompact
                    .frame(width: 56)
            }
            VStack(spacing: 4) {
                exercisePicker
                sidePickerCompact
            }
        }
    }

    /// Exercise selector — deliberately NOT a `.navigationLink` Picker any
    /// more (#279). A Picker can only *display* a value that also exists as a
    /// row in its list, which is why the placeholder used to be an explicit
    /// `Text("pick…").tag("")` row: selectable, so "no exercise" was something
    /// the user could actively choose, which reads as broken. A NavigationLink
    /// over an explicit list splits the two — the placeholder is displayed,
    /// never offered. The SL-75 guard is untouched: nothing here can set `tag`
    /// to "", and Start stays disabled while it is.
    private var exercisePicker: some View {
        pickerLink(
            display: tag.isEmpty ? "pick…" : tag,
            isPlaceholder: tag.isEmpty,
            label: "Exercise"
        ) {
            OptionPickerList(
                title: "Exercise",
                options: recentTags.map { (value: $0, label: $0) },
                selection: $tag
            )
        }
    }

    /// Side, sharing the row with the exercise picker. Same link-shaped control
    /// rather than a `.navigationLink` Picker because that style stacks its
    /// title *above* the value — two lines where one has to do (#279), and
    /// `.labelsHidden()` doesn't suppress it on watchOS. Unset shows "Side",
    /// which doubles as the missing title; an unspecified side stays a real,
    /// pickable option here (unlike an empty exercise).
    private var sidePickerCompact: some View {
        pickerLink(
            display: side.isEmpty ? "Side" : sideLabel(side),
            isPlaceholder: side.isEmpty,
            label: "Side"
        ) {
            OptionPickerList(title: "Side", options: SIDE_OPTIONS, selection: $side)
        }
    }

    /// The titled, full-width Side picker kept for the loading/empty-tag
    /// states: with no exercise value beside it, a lone "—" has nothing to give
    /// it context.
    private var sidePickerTitled: some View {
        Picker("Side", selection: $side) {
            ForEach(SIDE_OPTIONS, id: \.value) { o in
                Text(o.label).tag(o.value)
            }
        }
        .pickerStyle(.navigationLink)
        .font(.system(.footnote, design: .rounded).weight(.semibold))
        .frame(minHeight: 44)
    }

    private func sideLabel(_ value: String) -> String {
        SIDE_OPTIONS.first { $0.value == value }?.label ?? value
    }

    /// One compact row of the setup screen: current value (or placeholder) on a
    /// mini bordered button that pushes its own list. Titles are dropped in the
    /// side-by-side row — there's no width for them at 40mm — so VoiceOver gets
    /// the name via `accessibilityLabel`.
    private func pickerLink<Destination: View>(
        display: String,
        isPlaceholder: Bool,
        label: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            Text(display)
                .font(.caption2)
                .foregroundStyle(isPlaceholder ? Color.secondary : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(WatchSecondaryButtonStyle(
            tint: isPlaceholder ? WatchPalette.textSecondary : WatchPalette.foreground(WatchDesignTokens.force)
        ))
        .frame(minHeight: 44)
        .accessibilityLabel(label)
        .accessibilityIdentifier("force-\(label.lowercased())-picker")
    }

    // MARK: Measuring — the live gauge owns the whole screen.

    @ViewBuilder
    private var measuringContent: some View {
        let currentKg = fixtureVisual?.currentKg ?? tindeq.currentKg
        let peakKg = fixtureVisual?.peakKg ?? tindeq.peakKg
        let elapsedS = fixtureVisual?.elapsedS ?? tindeq.elapsedMs / 1000
        let displayTag = fixtureVisual?.tag.isEmpty == false ? fixtureVisual!.tag : tag
        HStack {
            WatchStateChip(state: .syncing, title: "Measuring", compact: true)
            Spacer(minLength: 4)
            Text(displayTag)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(WatchPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .truncationMode(.tail)
        }

        (Text(String(format: "%.1f", currentKg))
            .font(.system(size: 42, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(WatchPalette.foreground(WatchDesignTokens.force))
        + Text(" kg").font(.footnote).foregroundStyle(WatchPalette.textSecondary))
            .lineLimit(1)
            .minimumScaleFactor(0.7)

        // Hold time — the primary live number after force, so it reads at a
        // glance mid-hang.
        HStack(alignment: .firstTextBaseline) {
            Text("peak \(String(format: "%.1f", peakKg))")
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .foregroundStyle(WatchPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
            (Text(String(format: "%.1f", elapsedS))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
            + Text(" s").font(.footnote).foregroundStyle(.secondary))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }

        Sparkline(samples: sparkSamples)
            .frame(minHeight: 28, maxHeight: 50)

        Button("Stop & Save") { tindeq.stopAndSave(reason: .userTapped) }
            .buttonStyle(WatchPrimaryButtonStyle(tint: WatchPalette.force))
            .accessibilityIdentifier("force-stop-save")
    }
}

/// The list behind the setup pickers (#279). Only the options handed to it are
/// offered — the exercise list is built from `recentTags`, so unlike the old
/// `Text("pick…").tag("")` row there is nothing here that labels a rep with no
/// exercise. Tapping selects and pops straight back, same feel as the
/// `.navigationLink` Picker it replaces.
private struct OptionPickerList: View {
    let title: String
    let options: [(value: String, label: String)]
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(options, id: \.value) { o in
                Button {
                    selection = o.value
                    dismiss()
                } label: {
                    HStack {
                        Text(o.label)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        if o.value == selection {
                            Image(systemName: "checkmark")
                            .foregroundStyle(WatchPalette.foreground(WatchDesignTokens.force))
                        }
                    }
                    .frame(minHeight: 44)
                }
            }
        }
        .navigationTitle(title)
        .scrollContentBackground(.hidden)
        .watchCanvas()
    }
}
