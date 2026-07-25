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
    @State private var saving = false
    @State private var savedMsg: String?
    // Bumped every time savedMsg is finalized (issue #149 follow-up) so the
    // delayed auto-clear below only fires for the message it was scheduled
    // for — a fast next rep that overwrites savedMsg before the old timer
    // fires must not have its fresh message wiped by the stale one.
    @State private var savedMsgGeneration = 0
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

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                // Measuring owns the whole screen in a plain, non-scrolling
                // VStack (issue #149) — the live gauge, peak/timer, and Stop
                // & Save must all be visible at once without hunting for a
                // scroll position mid-hang. Every other state keeps the
                // ScrollView (loading/empty/error states legitimately may
                // need it).
                if tindeq.status == .measuring {
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
                            if tindeq.status != .unsupported && tindeq.status != .measuring {
                                sessionBar
                            }

                            switch tindeq.status {
                            case .unsupported:
                                Text(tindeq.errorMsg ?? "Bluetooth unavailable")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)

                            case .idle:
                                Button("Connect Progressor") { tindeq.connect() }
                                    .buttonStyle(.borderedProminent)
                                if let msg = tindeq.errorMsg {
                                    Text(msg).font(.footnote).foregroundStyle(.red)
                                }

                            case .scanning, .connecting:
                                ProgressView()
                                Text(tindeq.status == .scanning ? "Scanning…" : "Connecting…")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)

                            case .connected:
                                setupContent

                            case .measuring:
                                // Unreachable — measuring renders in the non-scrolling
                                // branch above; kept only for switch exhaustiveness.
                                EmptyView()
                            }

                            if let savedMsg {
                                // Least essential line in the stack (issue #149
                                // follow-up) — kept last so it's the first thing
                                // to scroll off if the combo still overflows the
                                // smallest watch, and capped to one line so a
                                // long tag name can't silently wrap into a
                                // second line and blow the budget.
                                Text(savedMsg)
                                    .font(.caption2)
                                    .foregroundStyle(saving ? Color.secondary : Color.green)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .truncationMode(.tail)
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
                    withAnimation { proxy.scrollTo("gaugeTop", anchor: .top) }
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
        .toolbar(tindeq.status == .measuring ? .hidden : .visible, for: .navigationBar)
        .onReceive(sparkTimer) { _ in
            if tindeq.status == .measuring {
                sparkSamples = tindeq.recentSamples()
            }
        }
        .task {
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
                    fetched = tags
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
        if tindeq.sessionId != nil {
            HStack {
                Circle().fill(.blue).frame(width: 5, height: 5)
                Text("Session · \(tindeq.sessionCount)")
                    .font(.caption2)
                Spacer()
                Button("Finish") { finish() }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
        }
    }

    private func finish() {
        // A session only exists after ≥1 saved rep, so there's always something
        // to log — hand off to the root-level GaugeFinishSheet via the manager.
        if tindeq.sessionCount > 0 {
            tindeq.pendingFinish = true
        } else {
            tindeq.clearSession()
        }
    }

    /// Deliberate disconnect (SL-75: there was no button). With saved reps it
    /// first surfaces the finish prompt so the session gets logged instead of
    /// orphaned; the sheet doesn't need the BLE link, so disconnect right away.
    private func disconnectTapped() {
        if tindeq.sessionCount > 0 { tindeq.pendingFinish = true }
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
        VStack(spacing: 3) {
            HStack {
                Circle().fill(.blue).frame(width: 6, height: 6)
                Text("connected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if tindeq.lowBattery {
                    Image(systemName: "battery.25")
                        .foregroundStyle(.yellow)
                }
                Button {
                    disconnectTapped()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.red)
            }

            // Tag is PICK-ONLY on the watch — typing on a watch is miserable and
            // free text drifts from the app's tag set. New tags are created in the
            // iPhone/web Force tab; the watch selects from what already exists.
            if tagsLoading && recentTags.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Loading exercises…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if recentTags.isEmpty {
                Text("No exercise tags found — record once in the iPhone app, or check the phone app is signed in.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Retry") { loadTags() }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            } else {
                Picker("Exercise", selection: $tag) {
                    // Explicit empty choice — a rep is never silently mislabeled.
                    Text("pick…").tag("")
                    ForEach(recentTags, id: \.self) { t in
                        Text(t).tag(t)
                    }
                }
                .pickerStyle(.navigationLink)
                .font(.caption2)
                .controlSize(.small)
            }
            Picker("Side", selection: $side) {
                ForEach(SIDE_OPTIONS, id: \.value) { o in
                    Text(o.label).tag(o.value)
                }
            }
            .pickerStyle(.navigationLink)
            .font(.caption2)
            .controlSize(.small)

            Button("Start") {
                savedMsg = nil
                tindeq.start()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(saving || tag.trimmingCharacters(in: .whitespaces).isEmpty)
            if tag.trimmingCharacters(in: .whitespaces).isEmpty && !recentTags.isEmpty {
                Text("Pick an exercise to start.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Measuring — the live gauge owns the whole screen.

    @ViewBuilder
    private var measuringContent: some View {
        HStack {
            Circle().fill(.green).frame(width: 8, height: 8)
            Text(tag)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }

        (Text(String(format: "%.1f", tindeq.currentKg))
            .font(.system(size: 42, weight: .heavy, design: .rounded))
            .monospacedDigit()
        + Text(" kg").font(.footnote).foregroundStyle(.secondary))
            .lineLimit(1)
            .minimumScaleFactor(0.7)

        // Hold time — the primary live number after force, so it reads at a
        // glance mid-hang.
        HStack(alignment: .firstTextBaseline) {
            Text("peak \(String(format: "%.1f", tindeq.peakKg))")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
            (Text(String(format: "%.1f", tindeq.elapsedMs / 1000))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
            + Text(" s").font(.footnote).foregroundStyle(.secondary))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }

        Sparkline(samples: sparkSamples)
            .frame(minHeight: 28, maxHeight: 50)

        Button(saving ? "Saving…" : "Stop & Save") { saveStop() }
            .buttonStyle(.borderedProminent)
            .disabled(saving)
    }

    // Stop always saves — with the tag/side set before the rep. A failure keeps
    // the rep recoverable by pulling again, and surfaces a friendly message
    // instead of a DB error.
    private func saveStop() {
        guard let rec = tindeq.stop() else { return }
        saving = true
        savedMsg = "Saving…"
        // Auto-group: the first saved rep mints the session so every rep of this
        // connect shares a group_id (SL-58 #5). Mint synchronously before the
        // async insert so the group id is stable for this and later reps.
        let groupId = tindeq.ensureSession()
        let savedTag = tag.trimmingCharacters(in: .whitespaces)
        let savedSide = side
        Task {
            do {
                try await Repo.insertTindeqRecording(
                    rec,
                    note: "",
                    tag: savedTag,
                    side: savedSide,
                    groupId: groupId
                )
                let tagLabel = savedTag.isEmpty ? "" : " · \(savedTag)"
                savedMsg = String(format: "Saved · %.1f kg%@", rec.peakKg, tagLabel)
                tindeq.sessionCount += 1
                // Remember for next launch (SL-75: instant, correct defaults).
                UserDefaults.standard.set(savedTag, forKey: LAST_TAG_KEY)
                UserDefaults.standard.set(savedSide, forKey: LAST_SIDE_KEY)
            } catch {
                savedMsg = ErrorText.friendly(error)
            }
            saving = false
            scheduleSavedMsgDismiss()
        }
    }

    /// Auto-clears the save confirmation a couple seconds after it lands
    /// (issue #149 follow-up). `savedMsg` used to sit on screen indefinitely
    /// — until the *next* Start tap set it back to nil — which meant it was
    /// routinely still showing once the user was back in `setupContent` for
    /// the next rep, stacked under the session bar. It's harmless
    /// UX-wise (nothing reads `savedMsg` besides this display and the
    /// explicit clear on Start), so letting it fade on its own keeps the
    /// setup screen's normal state as uncluttered as its first render.
    /// Generation-guarded like `loadTags()`'s fetch tracking: a fast next
    /// rep that overwrites `savedMsg` with a new confirmation before this
    /// timer fires must not have the old timer wipe the new message.
    private func scheduleSavedMsgDismiss() {
        savedMsgGeneration += 1
        let generation = savedMsgGeneration
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if generation == savedMsgGeneration { savedMsg = nil }
        }
    }
}
