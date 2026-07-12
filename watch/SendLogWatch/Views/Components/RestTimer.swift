import SwiftUI
import WatchKit

/// Rest countdown between efforts. Purely additive: it never pauses the
/// workout or gauge-session clocks — those keep running while you rest.
struct RestTimer: View {
    @State private var endsAt: Date?
    @State private var alarmTask: Task<Void, Never>?

    private let minutes = [1, 3, 5]

    var body: some View {
        if let endsAt {
            HStack(spacing: 6) {
                Image(systemName: "timer")
                    .foregroundStyle(.orange)
                Text(timerInterval: Date.now...endsAt, countsDown: true)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                Spacer()
                Button {
                    cancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        } else {
            HStack(spacing: 6) {
                Text("REST")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                ForEach(minutes, id: \.self) { m in
                    Button("\(m)m") { start(minutes: m) }
                        .font(.footnote)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
            }
        }
    }

    private func start(minutes m: Int) {
        let end = Date().addingTimeInterval(Double(m) * 60)
        endsAt = end
        WKInterfaceDevice.current().play(.start)
        alarmTask = Task {
            let interval = end.timeIntervalSinceNow
            if interval > 0 {
                try? await Task.sleep(for: .seconds(interval))
            }
            guard !Task.isCancelled else { return }
            // double haptic so it cuts through gym noise
            WKInterfaceDevice.current().play(.notification)
            try? await Task.sleep(for: .seconds(0.6))
            WKInterfaceDevice.current().play(.notification)
            endsAt = nil
        }
    }

    private func cancel() {
        alarmTask?.cancel()
        alarmTask = nil
        endsAt = nil
    }
}
