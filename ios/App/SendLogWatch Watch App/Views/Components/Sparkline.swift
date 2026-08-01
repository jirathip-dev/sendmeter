import SwiftUI

/// Cheap Canvas sparkline for the force trace (10 Hz refresh via parent).
struct Sparkline: View {
    let samples: [(t: Double, kg: Double)]

    var body: some View {
        Canvas { context, size in
            guard samples.count >= 2 else { return }
            let tMin = samples.first!.t
            let tMax = max(samples.last!.t, tMin + 1)
            let kgMax = max(samples.map(\.kg).max() ?? 1, 10) * 1.15

            var path = Path()
            for (i, s) in samples.enumerated() {
                let x = (s.t - tMin) / (tMax - tMin) * size.width
                let y = size.height - (s.kg / kgMax) * size.height
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            // Purple is the app-wide live-force signal (`--primary` on web).
            context.stroke(path, with: .color(SendmeterColor.primary), lineWidth: 2)
        }
    }
}
