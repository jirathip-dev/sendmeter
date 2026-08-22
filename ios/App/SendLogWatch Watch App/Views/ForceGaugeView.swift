import Combine
import SendLogWatchCore
import SwiftUI

private let LAST_TAG_KEY = "lastTindeqTag"
private let LAST_SIDE_KEY = "lastTindeqSide"

struct ForceGaugeView: View {
    // App-level so the connection + gauge session survive leaving this screen
    // (SL-58 #5). The finish prompt is presented from RootView.
    @Environment(TindeqManager.self) private var tindeq
    @Environment(ForceProtocolCatalog.self) private var protocolCatalog
    @Environment(GuidedForceRunner.self) private var guidedForceRunner
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var sparkSamples: [(t: Double, kg: Double)] = []
    @State private var showingFinishConfirmation = false
    /// SL-584 auto-connect bookkeeping. `autoConnectSuppressed` is per-VISIT
    /// on purpose (plain `@State`): a deliberate disconnect stops any further
    /// auto-reconnect until the user leaves and re-enters the screen (Q5).
    /// `connectAttempt` feeds the `.task(id:)` stale timer so every attempt
    /// (auto or manual retry) gets its own ~8s window; `connectAttemptStale`
    /// is presentation-only — the BLE scan itself never self-terminates and
    /// is deliberately left running (Q4), so a late-appearing Progressor
    /// still connects.
    @State private var autoConnectSuppressed = false
    @State private var connectAttempt = 0
    @State private var connectAttemptStale = false
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(ForceRuntimeCoordinator.self) private var forceRuntimeCoordinator

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

    private var selectedStartEligibility: GuidedForceStartEligibility {
        guidedForceStartEligibility(
            for: protocolCatalog.selected,
            sensorConnected: visibleStatus == .connected
        )
    }

    private var staticRequiresSensor: Bool {
        selectedStartEligibility == .requiresProgressor
    }

    private var alternatingSidesUnsupported: Bool {
        selectedStartEligibility == .alternatingSidesUnsupported
    }

    /// #683: the persistent mode header. When a guided runner is active this
    /// view is replaced by `GuidedForceRunnerView`, so here it only ever
    /// narrates the always-armed free hold (resting or recording).
    private var modeHeaderText: String? {
        if visibleStatus == .measuring { return "Free hold · recording" }
        if visibleStatus == .connected { return "Free hold · armed" }
        return nil
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                // #683: one persistent header line naming the live mode — the
                // always-armed free hold (resting or recording). The guided
                // screen replaces ForceGaugeView (RootView) while a protocol
                // is active and carries its own Repeaters · set header.
                if let headerText = modeHeaderText {
                    Text(headerText)
                        .font(.system(.caption2, design: .rounded).weight(.semibold))
                        .foregroundStyle(WatchPalette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9)
                        .environment(\.dynamicTypeSize, .medium)
                        .accessibilityIdentifier("force-mode-header")
                }
                // Measuring owns the whole screen in a plain, non-scrolling
                // VStack (issue #149) — the live gauge, peak/timer, and
                // Save now must all be visible at once without hunting for a
                // scroll position mid-hang. Every other state keeps the
                // ScrollView (loading/empty/error states legitimately may
                // need it).
                if visibleStatus == .measuring {
                    VStack(spacing: 4) {
                        measuringContent(availableSize: geometry.size)
                    }
                } else {
                    ScrollView {
                        // Tightened from 8 (issue #149 follow-up): the setup +
                        // session-bar + saved-message combination between reps
                        // is the mainline flow, not a rare edge case — every
                        // point here counts toward fitting a 41mm screen.
                        VStack(spacing: 4) {
                            Color.clear.frame(height: 1).id("gaugeTop")

                            switch visibleStatus {
                            case .unsupported:
                                WatchStateBanner(
                                    state: .danger,
                                    title: "Bluetooth unavailable",
                                    message: tindeq.errorMsg ?? "Turn on Bluetooth to connect a Progressor."
                                )

                            case .idle:
                                setupContent()
                                if let msg = fixtureVisual?.errorMessage ?? tindeq.errorMsg {
                                    WatchStateBanner(state: .danger, title: "Could not connect", message: msg)
                                }

                            // SL-584: scanning/connecting no longer swaps in a
                            // full-screen loading state — auto-connect starts on
                            // entry, so the page itself presents the in-flight
                            // state (connect pill + connecting card) while the
                            // selector rows stay usable.
                            case .scanning, .connecting:
                                setupContent()

                            case .connected:
                                setupContent()
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
                // A BLE connection is often the first point at which the
                // phone's relay has settled. Refresh a cached/empty/failed
                // catalog here without allowing an older task to overwrite it
                // (ForceProtocolCatalog owns the generation guard).
                if status == .connected,
                   protocolCatalog.status != .fresh,
                   protocolCatalog.status != .loading {
                    Task { await protocolCatalog.refresh() }
                }
            }
            // Keep the phone's live Force mirror in sync with the pickers (SL-87).
                .onChange(of: tag) { _, t in
                    // #543: a newly selected exercise may not permit the
                    // currently remembered side. Restore per-exercise, then
                    // force the canonical recorded side so a stale side is
                    // never armed or persisted.
                    tindeq.liveTag = t
                    restoreRememberedSide()
                    normalizeSideForMode()
                    tindeq.liveSide = side
                }
                .onChange(of: side) { _, s in
                    tindeq.liveSide = s
                    persistRememberedSide()
                }
                // #720/#543: the exercise's mode can resolve ASYNCHRONOUSLY
                // (the registry fetch that carries `side_mode` lands after the
                // tag list). A freshly-selected tag may therefore start at the
                // default mode and later tighten — re-normalize so a side that
                // became invalid under the resolver's mode is corrected.
                .onChange(of: activeSideMode) { _, _ in
                    normalizeSideForMode()
                }
            }
            // The watch's accessibility-large title can consume the same
            // navigation-bar area as the back/time affordances. The primary
            // setup rows already carry explicit labels, so reclaim that bar
            // only for the 40mm micro path; larger watches keep the premium
            // Force title even at large text sizes.
            .navigationTitle(
                dynamicTypeSize.isAccessibilitySize && isMicroSetupSize(geometry.size)
                    ? ""
                    : "Force"
            )
        // Hide the nav bar while measuring to reclaim vertical space for the
        // live gauge — it returns the moment the rep stops (status flips back
        // to .connected).
        .toolbar(visibleStatus == .measuring ? .hidden : .visible, for: .navigationBar)
        // #588 review F6: the finish-session icon shares the Workout finish's
        // checkered-flag glyph and danger tint, so it must also share the
        // ask-first behavior — an identical control that sometimes asks and
        // sometimes fires immediately is the exact ambiguity #580 scope 1
        // exists to avoid. This does NOT reintroduce the #295/#280 log-time
        // prompt: confirming still auto-logs immediately with the predicted
        // RPE (`rpe_confirmed = false`, editable later in History) — the
        // card is a tap-guard for the compact destructive control, not an
        // RPE/duration review step.
        // SL-584: finish and disconnect are ONE control now — disconnecting
        // already auto-logs the session (#295's phone-Finish / watch /
        // disconnect all end-and-log), so two buttons covered one outcome.
        // With no session yet the same control is an honest "Disconnect?".
        .watchFinishConfirmation(
            isPresented: $showingFinishConfirmation,
            title: sessionInProgress ? "Finish session?" : "Disconnect?",
            message: sessionInProgress
                ? "Logs your session to History and disconnects."
                : "Disconnects the Progressor.",
            confirmIdentifier: "force-finish-confirm",
            confirmHint: sessionInProgress
                ? "Logs the session and disconnects the Progressor"
                : "Disconnects the Progressor",
            cancelIdentifier: "force-finish-cancel"
        ) {
            // #590 review F1 backstop: with hands-free armed, a pull can
            // start a rep while the confirmation card covers the gauge, and
            // `disconnect()` would discard that in-flight rep AND suppress
            // the salvage path — the one interleaving where finishing loses
            // data. The `onChange` below dismisses the card the moment
            // recording starts; this guard closes the same-instant race
            // where the confirm tap lands as the pull begins. The rep
            // always wins — the user re-taps the flag after it completes.
            // Decision lives in Core (`ForceFinishPolicy`) so both layers
            // are unit-tested against the real manager interleaving.
            guard ForceFinishPolicy.mayExecuteFinish(isMeasuring: tindeq.status == .measuring) else {
                return
            }
            tindeq.logSessionNow()
            tindeq.disconnect()
            // #540: confirm the finish so a dim pull that ends with a
            // confirmed disconnect is unambiguous.
            forceRuntimeCoordinator.acknowledge(.finish)
            // A deliberate disconnect means "I'm done" — no auto-reconnect
            // for the rest of this visit (approved design Q5); re-entering
            // the Force screen from Home starts a fresh visit.
            autoConnectSuppressed = true
        }
        // #590 review F1 layer 1: a live pull means the user is not done —
        // an open finish confirmation must never sit over a recording rep.
        .onChange(of: tindeq.status) { _, status in
            if ForceFinishPolicy.shouldDismissConfirmation(isMeasuring: status == .measuring) {
                showingFinishConfirmation = false
            }
        }
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
                if fixtureVisual.status == .measuring {
                    // A deterministic live pull makes the 40mm trace visible
                    // in UI-test evidence without requiring Bluetooth.
                    sparkSamples = [
                        (0.0, 0.0), (0.2, 5.8), (0.4, 12.4), (0.6, 18.9),
                        (0.8, 15.7), (1.0, 23.6), (1.2, 20.8), (1.4, 27.1),
                        (1.6, 24.9), (1.8, 28.4), (2.0, 26.8),
                    ]
                }
                tindeq.liveTag = tag
                tindeq.liveSide = side
                return
            }
            // SL-584 (user decision): the exercise deliberately does NOT
            // restore on entry — the page starts with no exercise selected
            // and the ready card gates on "Pick an exercise" until a chip is
            // tapped. Only SIDE keeps its last value; its restore reads the
            // same key the save path has always written, so persistence
            // semantics are unchanged. `LAST_TAG_KEY` keeps being written on
            // save (and cleared by `reconcileLastTag`) but is no longer read
            // here.
            // #543: restore a per-exercise remembered side once an exercise is
            // known; a free hold (no exercise) falls back to the legacy global
            // last-side key. `normalizeSideForMode` then stamps the canonical
            // recorded side for the active mode.
            if side.isEmpty {
                restoreRememberedSide()
            }
            tindeq.liveTag = tag
            tindeq.liveSide = side
            normalizeSideForMode()
            loadTags()
            // SL-584: auto-initiate the connection on entry (issue #589 §1).
            // For real BLE "a device is available" is only discoverable by
            // scanning, so auto-initiate = auto-scan; the #567 fake
            // transport connects immediately. Gated on a posed force
            // fixture being absent (fixtures own their displayed state),
            // this visit having no deliberate disconnect, and the manager
            // actually being idle — never fires while connected, scanning,
            // or measuring. #683: the gauge arms hands-free automatically on
            // connect, so this only kicks off the connection; no arm tap.
            if ScreenshotFixtures.force == nil, !autoConnectSuppressed, tindeq.status == .idle {
                startConnectAttempt()
            }
            await protocolCatalog.refresh()
        }
        // Presentation-only "no device nearby" fallback (Q4): each connect
        // attempt gets ~8s; if the manager is still scanning/connecting
        // after that, the page falls back to the cadence-only presentation
        // while the scan keeps running underneath.
        .task(id: connectAttempt) {
            guard connectAttempt > 0 else { return }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            if tindeq.status == .scanning || tindeq.status == .connecting {
                connectAttemptStale = true
            }
        }
            .onDisappear { tagFetchTask?.cancel() }
        // No .onDisappear disconnect — the connection persists across navigation
        // (SL-58 #5); it drops only on a real BLE loss, which prompts to finish.
        }
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

    // MARK: SL-584 selector + connection rows (the old session bar, context
    // corner icon, and passive connection footer collapse into these two).

    /// Rows are 34pt of layout with 44pt hit slots centered inside (±5pt
    /// overhang — the #582 pattern). The overhangs land only on the 4pt row
    /// gaps and neighbors' visible-chrome insets (capsules are ≥3pt inset in
    /// their slots), so no control's hit frame covers another control's
    /// visible pixels; a later sibling always wins its own surface.
    private static let compactRowHeight: CGFloat = 34
    private static let connectionRowHeight: CGFloat = 38

    private var sessionInProgress: Bool {
        tindeq.sessionId != nil || (fixtureVisual?.sessionCount ?? 0) > 0
    }

    /// Every connect attempt — auto on entry or a manual retry tap — resets
    /// the stale flag and re-arms its own ~8s presentation window.
    private func startConnectAttempt() {
        connectAttemptStale = false
        connectAttempt += 1
        tindeq.connect()
    }

    /// Manual retry (the stale pill or the Connect card). #590 review F5:
    /// the ~8s fallback is presentation-only, so the ORIGINAL scan is often
    /// still running when the user taps retry — and `connect()` has no
    /// re-entrancy guard (it resets the phone-mirror pipeline and mints a
    /// fresh run identity). Only enter `connect()` from idle; over a live
    /// scan, just re-arm the presentation window and let that scan finish.
    private func retryConnect() {
        autoConnectSuppressed = false
        if tindeq.status == .idle {
            startConnectAttempt()
        } else {
            connectAttemptStale = false
            connectAttempt += 1
        }
    }

    /// The 2 most recent exercises as quick-select chips: the chips ARE the
    /// tag selector (approved design Q1) — cadence-only and every start path
    /// gates on picking one here (or the full list behind the settings
    /// icon). Nothing is pre-selected on entry (user decision).
    private var quickTags: [String] {
        if let fixtureVisual {
            return fixtureVisual.tag.isEmpty ? [] : [fixtureVisual.tag]
        }
        return Array(recentTags.prefix(2))
    }

    /// Row 1: exercise chips · L|R side toggle · settings icon. Moving the
    /// settings icon out of the ready card's corner overlay into this row is
    /// the structural fix for the icon overlapping the readout's kg unit on
    /// 40mm (issue #589 §2) — the card gets its full width back.
    private var selectorRow: some View {
        HStack(spacing: 4) {
            if quickTags.isEmpty {
                // #590 review finding 10: the placeholder truncated to
                // "No ex…" beside the side toggle on 40mm. Same recipe as
                // the chips (whose scaling provably works): a fixed-height
                // flexible frame OUTSIDE the scale floor, so the text gets a
                // definite proposal to scale into instead of truncating.
                Text(tagsLoading ? "Loading…" : "No exercises")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(WatchPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 28)
            } else {
                ForEach(quickTags, id: \.self) { name in
                    quickTagChip(name)
                }
            }
            Spacer(minLength: 0)
            sideToggle
            contextButton
        }
        .frame(height: Self.compactRowHeight)
    }

    private func quickTagChip(_ name: String) -> some View {
        let selected = tag == name
        let accent = WatchPalette.accent(WatchDesignTokens.secondary, reducedLuminance: isLuminanceReduced)
        return Button {
            // SL-585: tapping the selected chip DESELECTS — back to the
            // free-hold primary. `""` is a first-class selection now.
            tag = (tag == name) ? "" : name
        } label: {
            Text(name)
                .font(.system(size: 12, weight: selected ? .heavy : .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(
                    selected ? WatchPalette.textPrimary : WatchPalette.foreground(WatchDesignTokens.secondary)
                )
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background {
                    Capsule()
                        .fill(accent.opacity(selected ? 0.42 : 0.14))
                        .overlay {
                            Capsule().stroke(
                                accent.opacity(selected ? 0.9 : 0.38),
                                lineWidth: selected ? 1.2 : 0.8
                            )
                        }
                }
                .frame(maxWidth: .infinity, minHeight: CGFloat(WatchDesignTokens.minimumHitTarget))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityValue(tag == name ? "Selected" : "Not selected")
        .accessibilityAddTraits(tag == name ? .isSelected : [])
        .accessibilityHint(selected ? "Deselects this exercise, returning to free hold" : "Selects this exercise")
        .accessibilityIdentifier("force-quick-tag-\(name)")
    }

    /// Compact L|R on the main page — Side is sticky across reps and drives
    /// per-side PR/curve attribution, so the pre-recording confirmation of
    /// which side a rep lands on stays one glance (and now one tap) away.
    /// The chooser's full side list (both/none) stays behind the settings
    /// icon; these two cover the mainline. Distinct identifiers from the
    /// chooser's `force-side-*` rows so queries can never straddle screens.
    @ViewBuilder
    private var sideToggle: some View {
        // #543 (slice 3): the side controls follow the active exercise's side
        // mode. A non-sided exercise (`not_applicable`) hides the selector
        // entirely; bilateral-only shows a single selected "Both"; unilateral
        // and either-or-both show L/R (+ Both for the latter). A legacy
        // persisted "both"/"" on a non-bilateral exercise renders with no
        // segment selected; the active mode's deterministic fallback corrects
        // it on exercise selection and again once the async registry fetch
        // resolves the mode (a historical "" is never rewritten to "both").
        if ForceSidePolicy.showsSideSelector(activeSideMode) {
            HStack(spacing: 2) {
                ForEach(sideChoices, id: \.self) { value in
                    sideSegment(value)
                }
            }
        }
    }

    private func sideSegment(_ value: String) -> some View {
        let selected = side == value
        let accent = WatchPalette.accent(WatchDesignTokens.primary, reducedLuminance: isLuminanceReduced)
        return Button {
            // Tapping the already-selected segment is a no-op: clearing back
            // to unspecified is deliberately not offered.
            guard side != value else { return }
            side = value
        } label: {
            Text(sideSegmentLabel(value))
                .font(.system(size: 12, weight: selected ? .heavy : .semibold, design: .rounded))
                .foregroundStyle(selected ? WatchPalette.textPrimary : WatchPalette.textTertiary)
                .frame(width: 24, height: 28)
                .background {
                    Capsule()
                        .fill(accent.opacity(selected ? 0.42 : 0.1))
                        .overlay {
                            Capsule().stroke(
                                accent.opacity(selected ? 0.9 : 0.3),
                                lineWidth: selected ? 1.2 : 0.8
                            )
                        }
                }
                .frame(minHeight: CGFloat(WatchDesignTokens.minimumHitTarget))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sideSegmentAccessibilityLabel(value))
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("force-main-side-\(value)")
    }

    private func sideSegmentLabel(_ value: String) -> String {
        switch value {
        case ForceSidePolicy.left: return "L"
        case ForceSidePolicy.right: return "R"
        case ForceSidePolicy.both: return "B"
        default: return value
        }
    }

    private func sideSegmentAccessibilityLabel(_ value: String) -> String {
        switch value {
        case ForceSidePolicy.left: return "Left side"
        case ForceSidePolicy.right: return "Right side"
        case ForceSidePolicy.both: return "Both sides"
        default: return value
        }
    }

    /// Row 2: connection state (pill, with session rep count and low-battery
    /// once connected) + the unified finish/disconnect flag.
    private var connectionRow: some View {
        HStack(spacing: 6) {
            connectPill
            if visibleStatus == .connected && tindeq.lowBattery {
                Image(systemName: "battery.25")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(WatchPalette.foreground(WatchDesignTokens.warning))
                    .accessibilityLabel("Low battery")
            }
            Spacer(minLength: 0)
            if visibleStatus == .connected || sessionInProgress {
                finishButton
            }
        }
        // 38, not 34: the finish flag's 44pt hit frame overhangs ±3 here,
        // which stays inside the 3pt row gaps — at 34 its bottom overhang
        // reached 1pt into the ready card's tap surface (caught by the
        // setup fit assertions).
        .frame(height: Self.connectionRowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("force-connection-status")
    }

    private var isSearching: Bool {
        visibleStatus == .scanning || visibleStatus == .connecting
    }

    /// True while the page presents the in-flight connect state (first ~8s
    /// of an attempt). After the stale fallback the same scan may still be
    /// running, but the page has moved on to the cadence-only presentation.
    private var isPresentingConnecting: Bool {
        isSearching && !connectAttemptStale
    }

    @ViewBuilder
    private var connectPill: some View {
        if visibleStatus == .connected {
            connectPillLabel(
                dotToken: WatchDesignTokens.success,
                text: sessionInProgress
                    ? "Connected · \(fixtureVisual?.sessionCount ?? tindeq.sessionCount)"
                    : "Connected"
            )
            .accessibilityLabel(
                sessionInProgress
                    ? "Connected, session of \(fixtureVisual?.sessionCount ?? tindeq.sessionCount)"
                    : "Connected"
            )
        } else if isPresentingConnecting {
            connectPillLabel(dotToken: WatchDesignTokens.secondary, text: "Connecting…")
                .accessibilityLabel("Connecting")
        } else {
            // Idle, or a stale attempt (~8s with nothing found): a tappable
            // retry. The underlying scan is still running in the stale case,
            // so a late device connects either way.
            Button {
                retryConnect()
            } label: {
                connectPillLabel(dotToken: WatchDesignTokens.warning, text: "Connect")
                    .frame(minHeight: CGFloat(WatchDesignTokens.minimumHitTarget))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Connect Tindeq")
            .accessibilityHint("Scans for a Progressor nearby")
            .accessibilityIdentifier("force-connect-pill")
        }
    }

    private func connectPillLabel(dotToken: PhaseRGB, text: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(WatchPalette.foreground(dotToken))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(WatchPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background {
            Capsule()
                .fill(Color.white.opacity(0.06))
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.8))
        }
    }

    /// Unified finish/disconnect — same compact flag treatment (and shared
    /// `watchFinishConfirmation` tap-guard) as the Workout finish. One
    /// control for one outcome: disconnecting auto-logs any session (#295),
    /// so a separate disconnect button covered nothing the flag doesn't.
    private var finishButton: some View {
        WatchIconButton(
            systemImage: tindeq.saving ? "ellipsis" : WatchIconSymbol.finishWorkout,
            accessibilityLabel: tindeq.saving
                ? "Finishing session"
                : sessionInProgress ? "Finish session" : "Disconnect",
            accessibilityHint: tindeq.saving
                ? "Logging the session"
                : sessionInProgress
                    ? "Shows a confirmation before logging the session and disconnecting"
                    : "Shows a confirmation before disconnecting",
            accessibilityIdentifier: "force-session-finish",
            tint: WatchDesignTokens.danger,
            usesTintWhenUnselected: true,
            isDisabled: tindeq.saving
        ) {
            showingFinishConfirmation = true
        }
    }

    // MARK: Connected/idle setup — one primary ready state (issue #537).
    //
    // The setup screen centers on ONE ready/measurement state: a live force
    // reading, a status line and the selected exercise/side/protocol
    // context, all inside a single card that IS the Start control.
    // Everything that used to compete with it for space (separate
    // exercise/side/protocol rows, the full protocol detail card, a
    // "Connected" chip, disconnect) is either folded into that one card,
    // demoted to a compact top-right context action, or made
    // passive/below-the-fold — see #541's icon-first rule for the same
    // move. #683: the gauge arms hands-free automatically on connect (the
    // always-armed resting state), so there is no separate arm button or
    // mode toggle to place; the ready card is a passive status.
    //
    // Round-1 review (SL-537): every current Watch size measures as
    // `isMicroSetupSize` here once the nav bar is subtracted, so this no
    // longer branches on size — there is one design, proven to fit on the
    // smallest supported watch, used everywhere. That is a deliberate
    // simplification, not an oversight: a size-conditional design that only
    // one branch ever exercises is worse than one always-verified design.
    // `isMicroSetupSize` itself is untouched and still used correctly by
    // `measuringContent` and the `navigationTitle` reclaim below — this
    // screen just stopped being one of its callers.
    //
    // No container-level `.accessibilityIdentifier` here — see
    // `GuidedForceRunnerView`'s note on this exact footgun: on this
    // device+OS an identifier on a container silently overwrites every
    // descendant's own identifier (several `force-*` controls were all
    // reported back as this container's ID during this redesign's own
    // testing). Every control below already carries its own unique
    // `force-*` identifier, so no container ID is needed.
    @ViewBuilder
    private func setupContent() -> some View {
        VStack(spacing: 3) {
            // SL-584: the whole one-page primary path — selector row,
            // connection row and the ready card — is the no-scroll
            // guarantee: cap Dynamic Type here exactly like the old micro
            // rows did, so an accessibility text size cannot push the
            // primary start below the fold. Everything below (the guided
            // start, then banners) stays free to scale and may scroll, same
            // as before this redesign. (#683 removed the start-mode toggle —
            // free hold is always armed, so there is nothing to toggle.)
            Group {
                selectorRow
                connectionRow
                readyCard
            }
            .environment(\.dynamicTypeSize, .medium)
            secondaryContent
        }
    }

    /// The viewport is finite even though the setup ScrollView's content
    /// proposal is unbounded. Keep this threshold in one place so the
    /// accessibility navigation treatment and `measuringContent`'s row
    /// treatment make the same 40mm decision.
    private func isMicroSetupSize(_ size: CGSize) -> Bool {
        size.height <= 205 || size.width < 180
    }

    /// Full exercise list, protocol selection and the full side list — one
    /// entry point (#537 AC-1), now a compact icon in the selector row
    /// (SL-584) instead of a corner overlay on the ready card, which is what
    /// used to collide with the readout's kg unit on 40mm (issue #589 §2).
    private var contextButton: some View {
        NavigationLink {
            ForceProtocolChooserView(
                catalog: protocolCatalog,
                tag: $tag,
                recentTags: recentTags,
                tagsLoading: tagsLoading,
                onRetryTags: loadTags
            )
        } label: {
            // Reuses the shared compact circular glyph so this settings entry
            // stays in lockstep with `WatchIconButton` (circle + 44pt target),
            // not a one-off styling copy (#541).
            WatchIconGlyph(systemImage: WatchIconSymbol.forceContext)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Exercise and protocol")
        .accessibilityHint("Choose exercise, side and protocol")
        .accessibilityIdentifier("force-context-button")
    }

    /// Round-1 review finding 1 (BLOCKER): a movement protocol is runnable
    /// as cadence-only without a Progressor (`GuidedForcePolicy` returns
    /// `.allowed` with `sensorConnected: false`, and the always-available
    /// `movementStarter` default is exactly that mode) — the pre-#537
    /// design always kept a Start control on screen for this reason. Route
    /// to the Start card whenever eligible, connected or not; only fall
    /// back to "Connect Progressor" when starting genuinely requires the
    /// sensor (a static hold) or the protocol can't run on watch at all.
    @ViewBuilder
    private var readyCard: some View {
        if visibleStatus == .connected {
            // #683: connecting a gauge ALWAYS arms free hold, so the ready
            // state is a passive status card ("pull to start"), never an
            // arm button or a tap-to-start toggle.
            armedReadyCard
        } else if isPresentingConnecting {
            connectingCard
        } else if selectedStartEligibility == .allowed && !noExerciseSelected {
            // No device answered (or none was sought): cadence-only
            // fallback — reachable only through this disconnected path with
            // an exercise selected, never while connected (approved design).
            startReadyCard
        } else {
            // Disconnected with nothing selected lands here too (SL-585):
            // a free hold needs the sensor, so the primary action is the
            // connect retry — there is no refused dead-end state any more.
            connectReadyCard
        }
    }

    /// SL-585: `""` IS the free-hold selection — there is no refused
    /// "Pick an exercise" state any more. With nothing selected the primary
    /// card is the always-armed untagged free hold; picking a chip switches
    /// to the tagged flow and reveals the guided-protocol start.
    private var noExerciseSelected: Bool {
        tag.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var activeTag: String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// #543 (slice 3): the side-applicability policy for the active exercise.
    /// The single source of truth is `ForceSidePolicy`; views never hardcode a
    /// mode→side mapping. A tag not yet seen in the registry (or a free hold)
    /// reads as the default — every side valid, pre-#543 behavior.
    private var activeSideMode: ForceSideMode {
        guard !activeTag.isEmpty else { return .defaultMode }
        return tindeq.tagCurves[activeTag]?.sideMode ?? .defaultMode
    }

    /// The concrete side choices the active exercise offers, in display order.
    /// `bilateral_only` yields just `["both"]` — shown as a single selected
    /// "Both" so it stays explicit rather than implicit.
    private var sideChoices: [String] {
        ForceSidePolicy.allowedConcreteSides(activeSideMode)
    }

    /// #543: the canonical side to stamp on a NEW rep under the active mode.
    /// Distinct from `normalizeSide`, which keeps `""` as "not chosen yet":
    /// the WATCH stamps the live side directly at save time, so a
    /// bilateral-only exercise's unchosen side must become "both", and a
    /// non-sided exercise must record the no-side value.
    private var recordedSide: String {
        ForceSidePolicy.recordedSide(activeSideMode, side)
    }

    /// Restore the remembered side for the active exercise (or the legacy
    /// global last-side for a free hold) before normalizing.
    private func restoreRememberedSide() {
        if activeTag.isEmpty {
            if side.isEmpty {
                side = UserDefaults.standard.string(forKey: LAST_SIDE_KEY) ?? ""
            }
            return
        }
        side = ForceSideMemory.restoreValidSide(
            mode: activeSideMode,
            name: activeTag
        )
    }

    /// #543: nudge a stale/legacy side onto the active exercise's valid set.
    /// A historical empty side stays empty (never reinterpreted as `both`);
    /// a side that is simply invalid under the mode falls back to the mode's
    /// canonical state. Runs on exercise selection and on any mode change.
    private func normalizeSideForMode() {
        let normalized = recordedSide
        if normalized != side {
            side = normalized
        }
        persistRememberedSide()
    }

    /// Persist the active side per-exercise so the next selection restores a
    /// valid, non-leaking value; a free hold keeps the legacy global key.
    private func persistRememberedSide() {
        if activeTag.isEmpty {
            UserDefaults.standard.set(side, forKey: LAST_SIDE_KEY)
            return
        }
        ForceSideMemory.store(side: side, for: activeTag)
    }

    /// Auto-connect in flight (first ~8s): passive, not a control.
    private var connectingCard: some View {
        readyCardBody(token: WatchDesignTokens.secondary, status: "Connecting…")
            .accessibilityLabel("Connecting to Progressor")
            .accessibilityIdentifier("force-connecting-card")
    }

    /// Disconnected cadence-only Start: a movement protocol is runnable
    /// without a Progressor, so this card remains the primary when a device
    /// never answered (or none was sought). #683: connected free hold is
    /// always armed, so this Start card is only ever the disconnected
    /// cadence-only path — it enters the guided protocol, not a free hold.
    private var startReadyCard: some View {
        let eligible = !tindeq.saving
            && !guidedForceRunner.isActive
            && selectedStartEligibility == .allowed
        return Button {
            startSelectedProtocol()
        } label: {
            readyCardBody(
                token: WatchDesignTokens.primary,
                status: readyStatusText,
                symbol: eligible ? "play.fill" : nil
            )
        }
        .buttonStyle(.plain)
        .disabled(!eligible)
        .opacity(eligible ? 1 : 0.52)
        .accessibilityLabel("Start selected protocol")
        .accessibilityHint(startHint)
        .accessibilityIdentifier("force-start-selected")
    }

    /// #683: the connected resting state — always-armed free hold, so this
    /// card is a passive status (pull-to-start), not a dismissible chip.
    /// The "Armed" state lives on the gauge itself; there is no longer a
    /// tap-to-disarm control to remove.
    private var armedReadyCard: some View {
        readyCardBody(
            token: WatchDesignTokens.primary,
            status: "Armed — pull to start",
            symbol: "hand.raised.fill"
        )
        .accessibilityLabel("Free hold, armed")
        .accessibilityIdentifier("force-armed-ready")
    }

    private var connectReadyCard: some View {
        Button {
            retryConnect()
        } label: {
            readyCardBody(token: WatchDesignTokens.secondary, status: "Connect Progressor")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connect Progressor")
        .accessibilityHint("Connect a Progressor to measure force, or start a movement cadence without one")
        .accessibilityIdentifier("force-connect-progressor")
    }

    /// Shared visual shape for every ready-state card: the live/placeholder
    /// force reading and a status line — the "one primary ready state" the
    /// setup screen centers on. SL-584: the corner icon overlay and its
    /// reserved trailing width are gone (the settings icon lives in the
    /// selector row now — the structural fix for the 40mm kg overlap), and
    /// the context line is gone too: exercise and side are visible in the
    /// selector row, and the protocol name lives in the start state's
    /// hint/status. Never itself a `Button`; callers wrap it so each state
    /// carries its own accessibility label/hint/identifier.
    private func readyCardBody(token: PhaseRGB, status: String, symbol: String? = nil) -> some View {
        // Tighter than the default 11pt card padding: the one-page stack
        // needs the points back so the card bottom clears the 40mm fold at
        // accessibility sizes (same reclaim the readiness card made in #539).
        WatchCard(accent: WatchPalette.color(token), padding: 8) {
            VStack(spacing: 1) {
                readyForceReadout(token: token)
                HStack(spacing: 4) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .bold))
                            .accessibilityHidden(true)
                    }
                    Text(status)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(WatchPalette.textPrimary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func readyForceReadout(token: PhaseRGB) -> some View {
        (Text(String(format: "%.1f", fixtureVisual?.currentKg ?? tindeq.currentKg))
            .font(.system(size: 26, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(WatchPalette.foregroundOnAccentCard(token, accent: token))
        + Text(" kg").font(.caption).foregroundStyle(WatchPalette.textSecondary))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    // SL-537 round-1 finding 3(a)'s Side-visibility requirement is now met
    // by the selector row's L|R toggle (always visible, and tappable), so
    // the old card context line is gone — the card carries readout + status
    // only.

    private var readyStatusText: String {
        // SL-585: nothing selected means free hold, never a refusal.
        if noExerciseSelected { return "Start free hold" }
        switch selectedStartEligibility {
        case .allowed:
            return visibleStatus == .connected ? "Ready to pull" : "Ready · cadence only"
        case .requiresProgressor: return "Connect Progressor"
        case .alternatingSidesUnsupported: return "Unsupported on watch"
        }
    }

    private func startSelectedProtocol() {
        // #543: the run/arm path stamps the canonical recorded side for the
        // active exercise's mode, never the raw selector value — a stale or
        // invalid side is corrected deterministically at start, not persisted
        // as-is.
        guidedForceRunner.start(
            protocolValue: protocolCatalog.selected,
            tag: tag,
            side: recordedSide,
            sideMode: activeSideMode,
            manager: tindeq
        )
    }

    private var startHint: String {
        switch selectedStartEligibility {
        case .allowed:
            return "Starts \(protocolCatalog.selected.name)"
        case .requiresProgressor:
            return "Connect Progressor to measure this static hold"
        case .alternatingSidesUnsupported:
            return "Run this alternating-sides protocol on your iPhone; alternating sides are unsupported on watch"
        }
    }

    /// Everything below the no-scroll primary path: the explicit guided
    /// protocol start (while connected), then warnings and hints. Reachable
    /// by scrolling, same acceptance the pre-#537 design already gave its
    /// secondary controls. #683: the arm and tap-to-start controls are gone —
    /// connecting always arms free hold, so the only connected secondary
    /// action is entering a guided protocol.
    @ViewBuilder
    private var secondaryContent: some View {
        // #683: with free hold always-armed on connect, a guided protocol is
        // an explicit secondary action the user enters (and then exits) — a
        // "screen", not the resting state. This button renders even while
        // hands-free is armed (the old `!tindeq.handsFreeRequested` gate is
        // dropped) so guided remains reachable once the gauge is connected.
        if visibleStatus == .connected,
           !noExerciseSelected,
           !guidedForceRunner.isActive,
           selectedStartEligibility == .allowed {
            guidedStartButton
        }

        if let error = guidedForceRunner.errorMessage {
            WatchStateBanner(state: .danger, title: "Protocol not saved", message: error)
        } else if let message = guidedForceRunner.completionMessage {
            WatchStateBanner(state: .success, title: message, message: nil)
        }

        if let availability = ForceProtocolPresentation.watchAvailability(for: protocolCatalog.selected) {
            Text(availability)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(WatchPalette.foreground(WatchDesignTokens.warning))
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .accessibilityLabel(availability)
                .accessibilityIdentifier("force-protocol-watch-availability")
        }

        // #590 review F9: while the page itself says "Connecting…", a
        // "Cadence only · force not measured" row directly below it is a
        // contradiction — the sensor verdict isn't in yet. The row returns
        // with the stale cadence-only fallback.
        if visibleStatus != .connected && !isPresentingConnecting {
            noSensorRow
        }

        if noExerciseSelected && !recentTags.isEmpty {
            // SL-585: guidance, not a gate — free hold starts untagged.
            Text("Pick an exercise to tag your holds.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHint("Holds record untagged until an exercise is selected")
        }

        if tagsLoading && recentTags.isEmpty {
            Text("Loading exercises…")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(WatchPalette.textSecondary)
        } else if recentTags.isEmpty {
            WatchStateBanner(
                state: .warning,
                title: "No exercises yet",
                message: "Create an exercise in the iPhone app, then try again.",
                actionTitle: "Retry",
                action: { loadTags() }
            )
        }
    }

    /// The connected secondary action that enters the guided protocol screen.
    /// While the runner is active the Force screen is replaced by
    /// `GuidedForceRunnerView` (RootView), which suspends free hold entirely.
    private var guidedStartButton: some View {
        Button {
            startSelectedProtocol()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .bold))
                Text(startHint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: CGFloat(WatchDesignTokens.minimumHitTarget))
            .contentShape(Rectangle())
        }
        .buttonStyle(WatchSecondaryButtonStyle(tint: WatchPalette.primary))
        .disabled(tindeq.saving)
        .accessibilityLabel("Start selected protocol")
        .accessibilityHint(startHint)
        .accessibilityIdentifier("force-guided-start")
    }

    @ViewBuilder
    private var noSensorRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                WatchStateChip(
                    state: staticRequiresSensor || alternatingSidesUnsupported ? .warning : .offline,
                    title: staticRequiresSensor
                        ? "Static · connect Progressor"
                        : alternatingSidesUnsupported ? "Run on iPhone" : "Cadence only",
                    compact: true
                )
                Spacer(minLength: 0)
                Text(staticRequiresSensor
                    ? "Start disabled"
                    : alternatingSidesUnsupported ? "Alternating sides unsupported" : "Force not measured")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(WatchPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            VStack(alignment: .leading, spacing: 2) {
                WatchStateChip(
                    state: staticRequiresSensor || alternatingSidesUnsupported ? .warning : .offline,
                    title: staticRequiresSensor
                        ? "Static · connect Progressor"
                        : alternatingSidesUnsupported ? "Run on iPhone" : "Cadence only",
                    compact: true
                )
                Text(staticRequiresSensor
                    ? "Start is disabled until Progressor connects."
                    : alternatingSidesUnsupported
                        ? "Alternating sides are unsupported on watch."
                        : "Cadence only · force not measured")
                    .font(.caption2)
                    .foregroundStyle(WatchPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Measuring — the live gauge owns the whole screen.

    @ViewBuilder
    private func measuringContent(availableSize: CGSize) -> some View {
        if isLuminanceReduced {
            reducedLuminanceMeasuringContent()
            return
        }
        let currentKg = fixtureVisual?.currentKg ?? tindeq.currentKg
        let peakKg = fixtureVisual?.peakKg ?? tindeq.peakKg
        let elapsedS = fixtureVisual?.elapsedS ?? tindeq.elapsedMs / 1000
        let displayTag = fixtureVisual?.tag.isEmpty == false ? fixtureVisual!.tag : tag
        let forceReadout = (Text(String(format: "%.1f", currentKg))
            .font(.system(size: 42, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(WatchPalette.foreground(WatchDesignTokens.primary))
        + Text(" kg").font(.footnote).foregroundStyle(WatchPalette.textSecondary))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
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

        if isMicroSetupSize(availableSize) {
            // Preserve the live trace on 40mm without spending another row:
            // the translucent readout floats over a compact accent line.
            ZStack {
                Sparkline(samples: sparkSamples)
                    .frame(height: 32)
                    .opacity(0.68)
                forceReadout
                    .padding(.horizontal, 6)
                    .background(WatchPalette.canvas.opacity(0.82), in: Capsule())
            }
            // 47pt is deliberate: watchOS draws the primary button's focus
            // edge half a point beyond its layout frame on the 40mm canvas.
            // This preserves a full-size trace/readout while keeping that
            // rendered hit surface inside the 197pt viewport.
            .frame(maxWidth: .infinity, minHeight: 47, maxHeight: 47)
        } else {
            forceReadout
        }

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

        // The live screen is intentionally non-scrolling so "Save now" can
        // never move out of reach mid-pull. Larger watches have room for a
        // dedicated trace; 40mm renders the same samples behind the readout.
        if !isMicroSetupSize(availableSize) {
            Sparkline(samples: sparkSamples)
                .frame(minHeight: 28, maxHeight: 50)
        }

        // #683: the old save control is demoted to "Save now" — it ends ONE
        // rep, not the session; release-to-slack still saves + re-arms.
        Button("Save now") {
            tindeq.stopAndSave(reason: .userTapped)
            // #540: a save confirmation makes a dim pull's end trustworthy.
            forceRuntimeCoordinator.acknowledge(.save)
        }
            .buttonStyle(WatchPrimaryButtonStyle(tint: WatchPalette.primary))
            .accessibilityIdentifier("force-stop-save")
    }

    /// #540: the minimal reduced-luminance Force frame.  When watchOS dims
    /// (Always On / wrist-down) we render only the essential live numbers
    /// (current force, peak, hold time, side, terse state word) and drop the
    /// decorative sparkline / header chip and the nonessential Save control.
    private func reducedLuminanceMeasuringContent() -> some View {
        let spec = forceRuntimeCoordinator.reducedLuminanceSpec
        let currentKg = fixtureVisual?.currentKg ?? tindeq.currentKg
        let peakKg = fixtureVisual?.peakKg ?? tindeq.peakKg
        let elapsedS = fixtureVisual?.elapsedS ?? tindeq.elapsedMs / 1000
        let displaySide = sideLabel(side)
        return VStack(spacing: 5) {
            Text(spec.stateWord.uppercased())
                .font(.system(.caption, design: .rounded).weight(.bold))
                .foregroundStyle(WatchPalette.textSecondary)
            if spec.showsCurrentForce {
                (Text(String(format: "%.1f", currentKg))
                    .font(.system(size: 46, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(WatchPalette.foreground(WatchDesignTokens.primary))
                + Text(" kg").font(.footnote).foregroundStyle(WatchPalette.textSecondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            if spec.showsPeakForce {
                Text("peak \(String(format: "%.1f", peakKg))")
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .foregroundStyle(WatchPalette.textSecondary)
            }
            if spec.showsPhaseCountdown {
                (Text(String(format: "%.1f", elapsedS))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                + Text(" s").font(.footnote).foregroundStyle(.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            if spec.showsSide, !displaySide.isEmpty, displaySide != "—" {
                Text(displaySide)
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(WatchPalette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("force-reduced-luminance")
    }
}
