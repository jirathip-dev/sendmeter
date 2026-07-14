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
    @State private var pending: StoppedRecording?
    @State private var saving = false
    @State private var savedMsg: String?
    @State private var sparkSamples: [(t: Double, kg: Double)] = []

    // Exercise setup — set once, tweak side between reps (mirrors the web app)
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
        ScrollView {
            VStack(spacing: 8) {
                if tindeq.status != .unsupported {
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

                if let pending {
                    summaryCard(pending)
                }
                if let savedMsg {
                    Text(savedMsg).font(.footnote).foregroundStyle(.green)
                }

                // Rest timer: independent of the gauge session/workout clock
                RestTimer()
                    .padding(.top, 4)
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
                Stepper(value: $endDurationMin, in: 1...600, step: 5) {
                    VStack(alignment: .leading) {
                        Text("DURATION").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text("\(endDurationMin) min").monospacedDigit()
                    }
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

        // Exercise setup (hidden while measuring to save space)
        if tindeq.status == .connected {
            TextField("Tag (e.g. FDP)", text: $tag)
                .font(.footnote)
            if !recentTags.isEmpty {
                Picker("Recent", selection: $tag) {
                    Text("—").tag("")
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

        HStack {
            Text("peak \(String(format: "%.1f", tindeq.peakKg))")
            Spacer()
            Text(String(format: "%.1fs", tindeq.elapsedMs / 1000))
        }
        .font(.footnote)
        .foregroundStyle(.secondary)

        Sparkline(samples: sparkSamples)
            .frame(height: 50)

        HStack {
            Button("Tare") { tindeq.tare() }
                .disabled(tindeq.status == .measuring)
            if tindeq.status == .measuring {
                Button("Stop") {
                    pending = tindeq.stop()
                    savedMsg = nil
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Start") {
                    pending = nil
                    savedMsg = nil
                    tindeq.start()
                }
                .buttonStyle(.borderedProminent)
            }
        }

        Button("Disconnect") { tindeq.disconnect() }
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    // MARK: Save card

    @ViewBuilder
    private func summaryCard(_ rec: StoppedRecording) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text("Duration")
                Spacer()
                Text(String(format: "%.1fs", Double(rec.durationMs) / 1000))
            }
            HStack {
                Text("Peak")
                Spacer()
                Text(String(format: "%.1f kg", rec.peakKg)).foregroundStyle(.green)
            }
            HStack {
                Text("Average")
                Spacer()
                Text(String(format: "%.1f kg", rec.avgKg))
            }
            if !tag.isEmpty || !side.isEmpty {
                HStack {
                    Text("Tag")
                    Spacer()
                    Text("\(tag)\(side.isEmpty ? "" : " · \(side)")")
                        .foregroundStyle(.blue)
                }
            }
            HStack {
                Button("Discard") { pending = nil }
                Button(saving ? "Saving…" : "Save") {
                    saving = true
                    Task {
                        do {
                            try await Repo.insertTindeqRecording(
                                rec,
                                note: "",
                                tag: tag.trimmingCharacters(in: .whitespaces),
                                side: side,
                                groupId: session?.id
                            )
                            pending = nil
                            savedMsg = "Saved"
                            if session != nil { sessionCount += 1 }
                        } catch {
                            // Keep `pending` set so the recording isn't lost —
                            // the user can retry (e.g. after reconnecting).
                            savedMsg = ErrorText.friendly(error)
                        }
                        saving = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(saving)
            }
        }
        .font(.footnote)
    }
}
