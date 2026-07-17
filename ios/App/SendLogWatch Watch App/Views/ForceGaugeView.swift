import Combine
import SwiftUI

private let SIDE_OPTIONS: [(value: String, label: String)] = [
    ("", "—"),
    ("left", "Left"),
    ("right", "Right"),
    ("both", "Both"),
]

struct ForceGaugeView: View {
    @State private var tindeq = TindeqManager()
    @State private var saving = false
    @State private var savedMsg: String?
    @State private var sparkSamples: [(t: Double, kg: Double)] = []

    // Exercise setup — set once before the first rep, tweak side between reps.
    // Hidden while measuring so the live gauge fits one screen; Stop always
    // saves with whatever tag/side is set (no post-stop decision).
    @State private var tag = ""
    @State private var side = ""
    @State private var recentTags: [String] = []

    // Gauge session: recordings saved while active share a group_id
    @State private var session: (id: UUID, startedAt: Date)?
    @State private var sessionCount = 0
    @State private var showEndSheet = false
    @State private var endDurationMin = 30
    @State private var endRPE = 5
    @State private var loggingSession = false

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
        .onDisappear { tindeq.disconnect() }
        .sheet(isPresented: $showEndSheet) { endSessionSheet }
    }

    // MARK: Session bar

    @ViewBuilder
    private var sessionBar: some View {
        if let _ = session {
            HStack {
                Circle().fill(.blue).frame(width: 6, height: 6)
                Text("Session · \(sessionCount)")
                    .font(.footnote)
                Spacer()
                Button("End") { endSession() }
                    .font(.footnote)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
        } else {
            Button {
                session = (id: UUID(), startedAt: Date())
                sessionCount = 0
            } label: {
                Label("Start Session", systemImage: "square.stack.3d.up")
                    .font(.footnote)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func endSession() {
        guard let s = session else { return }
        if sessionCount > 0 {
            // Duration is the actual session wall-clock time — not editable;
            // the sheet only asks for RPE.
            endDurationMin = max(1, Int((Date().timeIntervalSince(s.startedAt) / 60).rounded()))
            endRPE = 5
            showEndSheet = true
        } else {
            session = nil
        }
    }

    @ViewBuilder
    private var endSessionSheet: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Log session")
                    .font(.headline)
                HStack {
                    VStack(alignment: .leading) {
                        Text("DURATION").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text("\(endDurationMin) min").monospacedDigit()
                    }
                    Spacer()
                    Text("actual time")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Stepper(value: $endRPE, in: 1...10) {
                    VStack(alignment: .leading) {
                        Text("RPE").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text("\(endRPE)").monospacedDigit()
                    }
                }
                Button(loggingSession ? "Logging…" : "Log Session") {
                    guard let s = session else { return }
                    loggingSession = true
                    Task {
                        let note = "\(sessionCount) recording\(sessionCount == 1 ? "" : "s")"
                        try? await Repo.logTindeqSession(
                            durationMin: endDurationMin,
                            rpe: endRPE,
                            note: note,
                            groupId: s.id
                        )
                        loggingSession = false
                        session = nil
                        showEndSheet = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(loggingSession)
                Button("Skip") {
                    session = nil
                    showEndSheet = false
                }
                .font(.footnote)
            }
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
        Task {
            do {
                try await Repo.insertTindeqRecording(
                    rec,
                    note: "",
                    tag: tag.trimmingCharacters(in: .whitespaces),
                    side: side,
                    groupId: session?.id
                )
                let tagLabel = tag.isEmpty ? "" : " · \(tag)"
                savedMsg = String(format: "Saved · %.1f kg%@", rec.peakKg, tagLabel)
                if session != nil { sessionCount += 1 }
            } catch {
                savedMsg = ErrorText.friendly(error)
            }
            saving = false
        }
    }
}
