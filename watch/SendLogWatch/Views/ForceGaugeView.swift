import SwiftUI

struct ForceGaugeView: View {
    @State private var tindeq = TindeqManager()
    @State private var pending: StoppedRecording?
    @State private var saving = false
    @State private var savedMsg: String?
    @State private var sparkSamples: [(t: Double, kg: Double)] = []

    private let sparkTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
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
            }
        }
        .navigationTitle("Force")
        .onReceive(sparkTimer) { _ in
            if tindeq.status == .measuring {
                sparkSamples = tindeq.recentSamples()
            }
        }
        .onDisappear { tindeq.disconnect() }
    }

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
            HStack {
                Button("Discard") { pending = nil }
                Button(saving ? "Saving…" : "Save") {
                    saving = true
                    Task {
                        do {
                            try await Repo.insertTindeqRecording(rec, note: "")
                            pending = nil
                            savedMsg = "Saved"
                        } catch {
                            savedMsg = "Save failed: \(error.localizedDescription)"
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
