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

    var body: some View {
        GeometryReader { geometry in
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
                                setupContent()
                                if let msg = fixtureVisual?.errorMessage ?? tindeq.errorMsg {
                                    WatchStateBanner(state: .danger, title: "Could not connect", message: msg)
                                }

                            case .scanning, .connecting:
                                WatchLoadingState(
                                    title: tindeq.status == .scanning ? "Scanning for Progressor…" : "Connecting…",
                                    message: "Keep the gauge nearby."
                                )

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
                .onChange(of: tag) { _, t in tindeq.liveTag = t }
                .onChange(of: side) { _, s in tindeq.liveSide = s }
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
        .watchFinishConfirmation(
            isPresented: $showingFinishConfirmation,
            title: "Finish session?",
            message: "Logs your session to History.",
            confirmIdentifier: "force-finish-confirm",
            confirmHint: "Logs the session and ends it",
            cancelIdentifier: "force-finish-cancel"
        ) {
            tindeq.logSessionNow()
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
            // Last-used tag/side restore instantly — no network needed to start.
            if tag.isEmpty { tag = UserDefaults.standard.string(forKey: LAST_TAG_KEY) ?? "" }
            if side.isEmpty { side = UserDefaults.standard.string(forKey: LAST_SIDE_KEY) ?? "" }
            tindeq.liveTag = tag
            tindeq.liveSide = side
            loadTags()
            await protocolCatalog.refresh()
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
                // The compact icon finish fits beside the chip on every
                // current size — the old 44pt text pill was wider than the
                // inner 40mm card, which made the stacked fallback read
                // enormous there (SL-580 follow-up). The ViewThatFits
                // fallback itself stays (#588 review F7): if the chip's
                // copy ever grows or starts scaling, the row degrades to a
                // stack instead of compressing either essential control.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 7) {
                        sessionChip
                        Spacer(minLength: 0)
                        finishButton
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        sessionChip
                        finishButton
                            .frame(maxWidth: .infinity, alignment: .trailing)
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

    /// Compact icon-only finish — the same `WatchIconButton` treatment as
    /// the live Workout's finish control (SL-580 follow-up), so "finish this
    /// activity" reads identically on both screens: same glyph, same tint,
    /// same ask-first behavior (#588 review F6 — see the shared
    /// `watchFinishConfirmation` attachment in `body`). The confirm still
    /// auto-logs with the predicted RPE, exactly the #280 semantics the old
    /// unconfirmed text pill had.
    private var finishButton: some View {
        WatchIconButton(
            systemImage: tindeq.saving ? "ellipsis" : WatchIconSymbol.finishWorkout,
            accessibilityLabel: tindeq.saving ? "Finishing session" : "Finish session",
            accessibilityHint: tindeq.saving
                ? "Logging the session"
                : "Shows a confirmation before logging this force session",
            accessibilityIdentifier: "force-session-finish",
            tint: WatchDesignTokens.danger,
            usesTintWhenUnselected: true,
            isDisabled: tindeq.saving
        ) {
            showingFinishConfirmation = true
        }
    }

    /// Deliberate disconnect (SL-75: there was no button). Logs any saved reps
    /// on the way out so the session isn't orphaned; logging doesn't need the
    /// BLE link, so disconnect right away.
    private func disconnectTapped() {
        tindeq.logSessionNow()
        tindeq.disconnect()
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
    // move. Hands-free arming keeps its exact behavior (TindeqManager owns
    // it untouched); only its position and the "Free hold" fallback's
    // visual weight change here.
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
    // descendant's own identifier (Free hold, Arm hands-free, disconnect
    // all reported back as this container's ID during this redesign's own
    // testing). Every control below already carries its own unique
    // `force-*` identifier, so no container ID is needed.
    @ViewBuilder
    private func setupContent() -> some View {
        VStack(spacing: 5) {
            primaryReadyPath
                // The primary path (ready card + Free hold) is the no-scroll
                // guarantee: cap Dynamic Type here exactly like the old
                // micro rows did, so an accessibility text size cannot push
                // Free hold below the fold. Everything below stays free to
                // scale and may scroll, same as before this redesign.
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

    /// The no-scroll guarantee: the ready card (with the compact context
    /// action layered in its corner, not spent as its own row) plus Free
    /// hold, the one manual fallback the issue calls out as needing to stay
    /// reachable without competing for equal weight.
    @ViewBuilder
    private var primaryReadyPath: some View {
        ZStack(alignment: .topTrailing) {
            readyCard
            contextButton
                .padding(.top, 3)
                .padding(.trailing, 3)
        }
        if visibleStatus == .connected && !tindeq.handsFreeRequested {
            freeHoldButton
        }
    }

    /// One top-right entry point (#537 AC-1) for exercise, side and protocol
    /// — Suggested and Custom both live in `ForceProtocolChooserView`. A
    /// sibling of the ready card (via the `ZStack` above), never nested
    /// inside its Button, so the two tap targets never conflict.
    private var contextButton: some View {
        NavigationLink {
            ForceProtocolChooserView(
                catalog: protocolCatalog,
                tag: $tag,
                side: $side,
                recentTags: recentTags,
                tagsLoading: tagsLoading,
                onRetryTags: loadTags
            )
        } label: {
            WatchIconGlyph(systemImage: WatchIconSymbol.forceContext)
        }
        .buttonStyle(WatchSecondaryButtonStyle(tint: WatchPalette.textPrimary))
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
        if visibleStatus == .connected && tindeq.handsFreeRequested {
            armedReadyCard
        } else if visibleStatus == .connected || selectedStartEligibility == .allowed {
            startReadyCard
        } else {
            connectReadyCard
        }
    }

    private var startReadyCard: some View {
        let eligible = !tindeq.saving
            && !guidedForceRunner.isActive
            && !tag.trimmingCharacters(in: .whitespaces).isEmpty
            && selectedStartEligibility == .allowed
        return Button { startSelectedProtocol() } label: {
            readyCardBody(token: WatchDesignTokens.primary, status: readyStatusText)
        }
        .buttonStyle(.plain)
        .disabled(!eligible)
        .opacity(eligible ? 1 : 0.52)
        .accessibilityLabel("Start selected protocol")
        .accessibilityHint(startHint)
        .accessibilityIdentifier("force-start-selected")
    }

    private var armedReadyCard: some View {
        Button { tindeq.cancelHandsFree() } label: {
            readyCardBody(
                token: WatchDesignTokens.success,
                status: tindeq.saving ? "Saving…" : "Armed — pull to start"
            )
        }
        .buttonStyle(.plain)
        .disabled(tindeq.saving)
        .accessibilityLabel("Hands-free mode")
        .accessibilityHint("Tap to disarm hands-free mode")
        .accessibilityIdentifier("force-hands-free-armed")
    }

    private var connectReadyCard: some View {
        Button { tindeq.connect() } label: {
            readyCardBody(token: WatchDesignTokens.secondary, status: "Connect Progressor")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connect Progressor")
        .accessibilityHint("Connect a Progressor to measure force, or start a movement cadence without one")
        .accessibilityIdentifier("force-connect-progressor")
    }

    /// The context button overlays this card's top-trailing corner (see
    /// `primaryReadyPath`) rather than spending its own row. Round-1 review
    /// finding 2 (HIGH): on 40mm at normal Dynamic Type the centered readout
    /// and status line rendered UNDER that icon. Reserve real trailing space
    /// for exactly those two lines — sized to clear the icon's 44pt frame
    /// plus its 3pt inset — rather than trusting the two siblings not to
    /// overlap; the context line stays fully centered since it sits below
    /// the icon's vertical extent.
    private static let contextIconReservedWidth: CGFloat = 40

    /// Shared visual shape for every ready-state card: the live/placeholder
    /// force reading, a status line, and the selected exercise/side/protocol
    /// context — the "one primary ready state" the setup screen centers on.
    /// Never itself a `Button`; callers wrap it so each state carries its own
    /// accessibility label/hint/identifier.
    private func readyCardBody(token: PhaseRGB, status: String) -> some View {
        WatchCard(accent: WatchPalette.color(token)) {
            VStack(spacing: 2) {
                VStack(spacing: 1) {
                    readyForceReadout(token: token)
                    Text(status)
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(WatchPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .padding(.trailing, Self.contextIconReservedWidth)
                readyContextLine(token: token)
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

    /// Round-1 review finding 3(a) (HIGH): Side is sticky across reps
    /// (`lastTindeqSide`) and drives per-side PR/curve comparisons, so
    /// hiding it here removed the user's only pre-recording confirmation of
    /// which side a rep will be attributed to. Always show it — `lineLimit`
    /// stays 1 (not 2) so a long exercise/protocol name shrinks via
    /// `minimumScaleFactor` instead of wrapping into a second line, which is
    /// what the 40mm no-scroll budget actually depends on, not which facts
    /// are present.
    private func readyContextLine(token: PhaseRGB) -> some View {
        let exercise = tag.isEmpty ? "No exercise" : tag
        let sideText = side.isEmpty ? nil : sideLabel(side)
        let pieces = [exercise, sideText, protocolCatalog.selected.name].compactMap { $0 }
        return Text(pieces.joined(separator: " · "))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(WatchPalette.foregroundOnAccentCard(token, accent: token))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .multilineTextAlignment(.center)
    }

    private var readyStatusText: String {
        if tag.trimmingCharacters(in: .whitespaces).isEmpty { return "Pick an exercise" }
        switch selectedStartEligibility {
        case .allowed:
            return visibleStatus == .connected ? "Ready to pull" : "Ready · cadence only"
        case .requiresProgressor: return "Connect Progressor"
        case .alternatingSidesUnsupported: return "Unsupported on watch"
        }
    }

    /// The clear, explicit manual fallback (#537 AC-3) — same action and
    /// identifier as before, just no longer sharing a row with Arm
    /// hands-free so it isn't visually paired as an equal-weight peer.
    private var freeHoldButton: some View {
        Button("Free hold") { tindeq.start() }
            .buttonStyle(WatchSecondaryButtonStyle(tint: WatchPalette.textSecondary))
            .disabled(tindeq.saving || tag.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Free hold")
            .accessibilityHint("Starts one untimed force hold")
            .accessibilityIdentifier("force-free-hold")
    }

    private func startSelectedProtocol() {
        guidedForceRunner.start(
            protocolValue: protocolCatalog.selected,
            tag: tag,
            side: side,
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

    /// Everything below the no-scroll primary path: Arm hands-free
    /// (repositioned per #537 #2 — behavior is untouched), warnings, and the
    /// passive connection/disconnect footer. Reachable by scrolling, same
    /// acceptance the pre-#537 design already gave its secondary controls.
    @ViewBuilder
    private var secondaryContent: some View {
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

        if visibleStatus != .connected {
            noSensorRow
        }

        if visibleStatus == .connected && !tindeq.handsFreeRequested {
            Button("Arm hands-free") { tindeq.armHandsFree() }
                // Neutral ink, matching "Free hold": the two remain peer
                // ways to start a measurement, so one may not read louder
                // than the other even after moving below the fold.
                .buttonStyle(WatchSecondaryButtonStyle(tint: WatchPalette.textSecondary))
                .disabled(tindeq.saving || tag.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityHint("Arms the gauge to start when you pull")
                .accessibilityIdentifier("force-arm-hands-free")
        }

        if visibleStatus == .connected {
            passiveConnectionFooter
        }

        if tag.trimmingCharacters(in: .whitespaces).isEmpty && !recentTags.isEmpty {
            Text("Pick an exercise to start.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHint("Exercise is required before starting")
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

    /// Connection state, deliberately not a `WatchCard`: it reads as passive
    /// chrome (#537 #4), not another card competing with the ready state
    /// above it. Disconnect keeps its full 44pt icon-only target, demoted
    /// here as the secondary action the issue asks for.
    private var passiveConnectionFooter: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(WatchPalette.foreground(WatchDesignTokens.success))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text("Connected")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(WatchPalette.textSecondary)
            if tindeq.lowBattery {
                Image(systemName: "battery.25")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(WatchPalette.foreground(WatchDesignTokens.warning))
                    .accessibilityLabel("Low battery")
            }
            Spacer(minLength: 4)
            disconnectButton
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("force-connection-status")
    }

    private var disconnectButton: some View {
        WatchIconButton(
            systemImage: WatchIconSymbol.disconnect,
            accessibilityLabel: "Disconnect Progressor",
            accessibilityHint: "Ends the session and disconnects the Progressor",
            tint: WatchDesignTokens.danger,
            usesTintWhenUnselected: true,
            action: disconnectTapped
        )
        .accessibilityIdentifier("disconnect-progressor")
    }

    // MARK: Measuring — the live gauge owns the whole screen.

    @ViewBuilder
    private func measuringContent(availableSize: CGSize) -> some View {
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

        // The live screen is intentionally non-scrolling so Stop & Save can
        // never move out of reach mid-pull. Larger watches have room for a
        // dedicated trace; 40mm renders the same samples behind the readout.
        if !isMicroSetupSize(availableSize) {
            Sparkline(samples: sparkSamples)
                .frame(minHeight: 28, maxHeight: 50)
        }

        Button("Stop & Save") { tindeq.stopAndSave(reason: .userTapped) }
            .buttonStyle(WatchPrimaryButtonStyle(tint: WatchPalette.primary))
            .accessibilityIdentifier("force-stop-save")
    }
}
