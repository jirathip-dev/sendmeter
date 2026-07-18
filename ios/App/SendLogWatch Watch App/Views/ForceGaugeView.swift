import Combine
import SwiftUI

private let SIDE_OPTIONS: [(value: String, label: String)] = [
    ("", "—"),
    ("left", "Left"),
    ("right", "Right"),
    ("both", "Both"),
]

struct ForceGaugeView: View {
    // App-level so the connection + gauge session survive leaving this screen
    // (SL-58 #5). The finish prompt is presented from RootView.
    @Environment(TindeqManager.self) private var tindeq
    @State private var saving = false
    @State private var savedMsg: String?
    @State private var sparkSamples: [(t: Double, kg: Double)] = []

    // Exercise setup — set once before the first rep, tweak side between reps.
    // Hidden while measuring so the live gauge fits one screen; Stop always
    // saves with whatever tag/side is set (no post-stop decision).
    @State private var tag = ""
    @State private var side = ""
    @State private var recentTags: [String] = []

    private let sparkTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 8) {
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

                case .connected, .measuring:
                    gaugeContent
                }

                if let savedMsg {
                    Text(savedMsg)
                        .font(.footnote)
                        .foregroundStyle(saving ? Color.secondary : Color.green)
                }
            }
        }
        .onChange(of: tindeq.status) { _, _ in
            // Controls show/hide on start/stop, shifting layout — snap back to
            // the top so the live gauge stays in view instead of a blank scroll.
            withAnimation { proxy.scrollTo("gaugeTop", anchor: .top) }
        }
        }
        .navigationTitle("Force")
        .onReceive(sparkTimer) { _ in
            if tindeq.status == .measuring {
                sparkSamples = tindeq.recentSamples()
            }
        }
        .task {
            recentTags = (try? await Repo.fetchRecentTindeqTags()) ?? []
            // Pick-only tag: default to the most-recent exercise so Start
            // works immediately (mirror of the web tab's default).
            if tag.isEmpty, let first = recentTags.first { tag = first }
        }
        // No .onDisappear disconnect — the connection persists across navigation
        // (SL-58 #5); it drops only on a real BLE loss, which prompts to finish.
    }

    // MARK: Session bar

    @ViewBuilder
    private var sessionBar: some View {
        // Only shown once a rep has minted the session (auto-group). Before the
        // first save there's nothing to end, so no bar — the gauge just records.
        if tindeq.sessionId != nil {
            HStack {
                Circle().fill(.blue).frame(width: 6, height: 6)
                Text("Session · \(tindeq.sessionCount)")
                    .font(.footnote)
                Spacer()
                Button("Finish") { finish() }
                    .font(.footnote)
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

    // MARK: Gauge

    @ViewBuilder
    private var gaugeContent: some View {
        HStack {
            Circle()
                .fill(tindeq.status == .measuring ? .green : .blue)
                .frame(width: 8, height: 8)
            Text(tindeq.status == .measuring ? "measuring" : "connected")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            if tindeq.lowBattery {
                Image(systemName: "battery.25")
                    .foregroundStyle(.yellow)
            }
        }

        // Exercise setup (hidden while measuring to keep the gauge one-screen).
        // Tag is PICK-ONLY on the watch — typing on a watch is miserable and
        // free text drifts from the app's tag set. New tags are created in the
        // iPhone/web Force tab; the watch selects from what already exists.
        if tindeq.status == .connected {
            if recentTags.isEmpty {
                Text("No exercise tags yet — record once in the iPhone app to create one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Exercise", selection: $tag) {
                    ForEach(recentTags, id: \.self) { t in
                        Text(t).tag(t)
                    }
                }
                .pickerStyle(.navigationLink)
                .font(.footnote)
            }
            Picker("Side", selection: $side) {
                ForEach(SIDE_OPTIONS, id: \.value) { o in
                    Text(o.label).tag(o.value)
                }
            }
            .pickerStyle(.navigationLink)
            .font(.footnote)
        }

        Text(String(format: "%.1f", tindeq.currentKg))
            .font(.system(size: 42, weight: .heavy, design: .rounded))
            .monospacedDigit()
        + Text(" kg").font(.footnote).foregroundStyle(.secondary)

        // Hold time — the primary live number after force, so it reads at a
        // glance mid-hang (much larger than the old footnote).
        HStack(alignment: .firstTextBaseline) {
            Text("peak \(String(format: "%.1f", tindeq.peakKg))")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%.1f", tindeq.elapsedMs / 1000))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tindeq.status == .measuring ? .primary : .secondary)
            + Text(" s").font(.footnote).foregroundStyle(.secondary)
        }

        Sparkline(samples: sparkSamples)
            .frame(height: 50)

        if tindeq.status == .measuring {
            Button(saving ? "Saving…" : "Stop & Save") { saveStop() }
                .buttonStyle(.borderedProminent)
                .disabled(saving)
        } else {
            Button("Start") {
                savedMsg = nil
                tindeq.start()
            }
            .buttonStyle(.borderedProminent)
            .disabled(saving)
        }
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
        Task {
            do {
                try await Repo.insertTindeqRecording(
                    rec,
                    note: "",
                    tag: tag.trimmingCharacters(in: .whitespaces),
                    side: side,
                    groupId: groupId
                )
                let tagLabel = tag.isEmpty ? "" : " · \(tag)"
                savedMsg = String(format: "Saved · %.1f kg%@", rec.peakKg, tagLabel)
                tindeq.sessionCount += 1
            } catch {
                savedMsg = ErrorText.friendly(error)
            }
            saving = false
        }
    }
}
