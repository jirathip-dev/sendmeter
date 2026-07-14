import Combine
import SwiftUI

struct ForceGaugeView: View {
    @State private var tindeq = TindeqManager()
    @State private var saving = false
    @State private var savedMsg: String?
    @State private var sparkSamples: [(t: Double, kg: Double)] = []

    // The watch is a minimal one-tap capture: no tag/side/tare here (add those
    // on the phone). A rep saves untagged the moment you stop; group it into a
    // session for the phone to reconcile.

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

                if let savedMsg {
                    Text(savedMsg)
                        .font(.footnote)
                        .foregroundStyle(saving ? Color.secondary : Color.green)
                }
            }
        }
        .navigationTitle("Force")
        .onReceive(sparkTimer) { _ in
            if tindeq.status == .measuring {
                sparkSamples = tindeq.recentSamples()
            }
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

    // Stop always saves — untagged, the moment you stop. A failure keeps the
    // rep recoverable by reconnecting and pulling again (nothing is queued on
    // the watch), and surfaces a friendly message instead of a DB error.
    private func saveStop() {
        guard let rec = tindeq.stop() else { return }
        saving = true
        savedMsg = "Saving…"
        Task {
            do {
                try await Repo.insertTindeqRecording(
                    rec, note: "", tag: "", side: "", groupId: session?.id
                )
                savedMsg = String(format: "Saved · %.1f kg", rec.peakKg)
                if session != nil { sessionCount += 1 }
            } catch {
                savedMsg = ErrorText.friendly(error)
            }
            saving = false
        }
    }
}
