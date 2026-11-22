import Blocks
import BlocksUI
import SwiftUI

@MainActor
func kit(_ json: String) -> some View {
    let block: Block
    do { block = try JSONDecoder().decode(Block.self, from: Data(json.utf8)) } catch { fatalError("kit: \(error)") }
    return BlocksView(block, source: nil).appBlocks(Kinds.all)
}

struct Tally: View {
    let tries: Int
    let color: Color

    var body: some View {
        Canvas { context, size in
            let h = size.height
            var x: CGFloat = 2
            for group in stride(from: 0, to: tries, by: 5) {
                let count = min(5, tries - group)
                let start = x
                for index in 0..<min(count, 4) {
                    var stroke = Path()
                    let lean = CGFloat((index * 3) % 2)
                    stroke.move(to: CGPoint(x: x + lean, y: 2))
                    stroke.addLine(to: CGPoint(x: x - lean, y: h - 2))
                    context.stroke(stroke, with: .color(color), style: .init(lineWidth: 3, lineCap: .round))
                    x += 9
                }
                if count == 5 {
                    var slash = Path()
                    slash.move(to: CGPoint(x: start - 5, y: h - 5))
                    slash.addLine(to: CGPoint(x: x - 3, y: 5))
                    context.stroke(slash, with: .color(color), style: .init(lineWidth: 3, lineCap: .round))
                }
                x += 10
            }
        }
        .accessibilityLabel("\(tries) tries")
    }
}

struct BigButton: View {
    let label: String
    let symbol: String
    let fill: Color
    let ink: Color

    var body: some View {
        VStack(spacing: 6) {
            SwiftUI.Image(systemName: symbol).font(.system(size: 30, weight: .bold))
            Text(label).font(.system(size: 17, weight: .bold, design: .rounded))
        }
        .foregroundStyle(ink)
        .frame(maxWidth: .infinity).frame(height: 128)
        .background(fill, in: .rect(cornerRadius: 24))
    }
}

struct SessionLive: View {
    @Environment(\.look) private var look

    var body: some View {
        let p = look.palette
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Asset.workoutLarge.resizable().scaledToFit().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Board · Kilter 40°").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.mute)
                    Text("42:18").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(p.foreground)
                }
                Spacer()
                Text("End").font(.system(size: 15, weight: .semibold)).foregroundStyle(p.red)
                    .padding(.horizontal, 18).frame(height: 44).background(p.card, in: .capsule)
                    .overlay(Capsule().strokeBorder(p.edge))
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Cobra Crack").font(.system(size: 22, weight: .bold)).foregroundStyle(p.foreground)
                    Text("V6").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(p.lead)
                    Spacer()
                    Label("Lit", systemImage: "lightbulb.fill").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Ink.holdStart)
                }
                HStack {
                    Tally(tries: 3, color: p.foreground).frame(width: 120, height: 30)
                    Spacer()
                    Text("Next").font(.system(size: 15, weight: .semibold)).foregroundStyle(p.link)
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
            .padding(16).background(p.card, in: .rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(p.edge))
            HStack(spacing: 12) {
                BigButton(label: "Fell", symbol: "arrow.down", fill: p.card, ink: p.foreground)
                    .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(p.edge))
                BigButton(label: "Sent", symbol: "checkmark", fill: p.lead, ink: .white)
            }
            HStack(spacing: 10) {
                SwiftUI.Image(systemName: "timer").foregroundStyle(p.amber)
                Text("Rest").font(.system(size: 15, weight: .semibold)).foregroundStyle(p.foreground)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(p.line)
                        Capsule().fill(Ink.caution).frame(width: proxy.size.width * 0.62)
                    }
                }
                .frame(height: 8)
                Text("1:52").font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(p.foreground)
            }
            .padding(.horizontal, 16).frame(height: 52).background(p.card, in: .rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(p.edge))
            kit(
                #"{"type": "stat", "id": "live", "items": [{"label": "HR", "value": 142, "unit": "bpm", "spark": [118, 131, 150, 122, 139, 156, 142]}, {"label": "Tries", "value": 14}, {"label": "Sends", "value": 4, "tone": "ok"}]}"#
            )
        }
        .padding(16).padding(.top, 36)
    }
}

struct WatchLive: View {
    let state: String

    var body: some View {
        let dark = Sendmeter.dark
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("42:18").font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Ink.optimal)
                Spacer()
                Label("142", systemImage: "heart.fill").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Ink.danger)
            }
            switch state {
            case "rest":
                Text("Rest").font(.system(size: 15, weight: .semibold)).foregroundStyle(dark.mute)
                Text("1:52").font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Ink.caution)
                Spacer(minLength: 0)
                Text("Climb").font(.system(size: 17, weight: .bold)).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).frame(height: 48).background(Ink.caution, in: .capsule)
            case "sent":
                Spacer(minLength: 0)
                SwiftUI.Image(systemName: "bolt.fill").font(.system(size: 40, weight: .bold)).foregroundStyle(Ink.caution)
                    .frame(maxWidth: .infinity)
                Text("Flash").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(dark.foreground)
                    .frame(maxWidth: .infinity)
                Text("Cobra Crack · V6").font(.system(size: 13, weight: .semibold)).foregroundStyle(dark.mute)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            default:
                Text("Cobra Crack").font(.system(size: 17, weight: .bold)).foregroundStyle(dark.foreground)
                    .lineLimit(1)
                HStack {
                    Text("V6").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(dark.lead)
                    Tally(tries: 3, color: dark.foreground).frame(width: 60, height: 20)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Text("Fell").font(.system(size: 17, weight: .bold)).foregroundStyle(dark.foreground)
                        .frame(maxWidth: .infinity).frame(height: 64).background(dark.card, in: .rect(cornerRadius: 20))
                    Text("Sent").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 64)
                        .background(SendmeterHue.primary, in: .rect(cornerRadius: 20))
                }
            }
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 10)
        .frame(width: 198, height: 242)
        .background(Ink.slate)
        .clipShape(.rect(cornerRadius: 40))
        .padding(10)
        .background(Color(hex: "#2A2B30"), in: .rect(cornerRadius: 50))
    }
}

enum SendmeterHue {
    static let primary = Color(hex: "#5B5FC7")
}

struct ForceCurve: View {
    @Environment(\.look) private var look

    var body: some View {
        let p = look.palette
        let points: [Double] = (0..<80).map { i in
            let t = Double(i) / 79
            let rise = min(1, t / 0.12)
            let fall = t > 0.86 ? max(0, 1 - (t - 0.86) / 0.1) : 1
            return (36 + 3 * sin(t * 19) + 2.2 * sin(t * 7)) * rise * fall
        }
        GeometryReader { proxy in
            let (w, h) = (proxy.size.width, proxy.size.height)
            let y: (Double) -> CGFloat = { h - CGFloat($0 / 50) * h }
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Ink.optimal.opacity(0.12)).frame(height: y(34) - y(40)).offset(y: y(40))
                Path { path in
                    for (i, value) in points.enumerated() {
                        let point = CGPoint(x: w * CGFloat(i) / 79, y: y(value))
                        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
                .stroke(p.lead, style: .init(lineWidth: 3, lineCap: .round, lineJoin: .round))
                Path { path in
                    path.move(to: CGPoint(x: 0, y: y(41.6)))
                    path.addLine(to: CGPoint(x: w, y: y(41.6)))
                }
                .stroke(p.amber, style: .init(lineWidth: 1, dash: [4, 4]))
            }
        }
    }
}

struct ForceLive: View {
    @Environment(\.look) private var look

    var body: some View {
        let p = look.palette
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Asset.forceLarge.resizable().scaledToFit().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Force").font(.system(size: 34, weight: .bold)).foregroundStyle(p.foreground)
                    HStack(spacing: 6) {
                        Circle().fill(Ink.holdStart).frame(width: 8, height: 8)
                        Text("Progressor · 92%").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.mute)
                    }
                }
            }
            kit(
                #"{"type": "chips", "id": "mode", "name": "mode", "action": "mode", "selected": ["max"], "options": [{"label": "Max pull", "value": "max"}, {"label": "Repeaters", "value": "rep"}, {"label": "Peak", "value": "peak"}, {"label": "Free", "value": "free"}]}"#
            )
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("38.4").font(.system(size: 64, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(p.foreground)
                    Text("kg").font(.system(size: 20, weight: .semibold)).foregroundStyle(p.mute)
                    Spacer()
                    Text("L").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(p.lead, in: .circle)
                    Text("R").font(.system(size: 15, weight: .bold)).foregroundStyle(p.mute)
                        .frame(width: 44, height: 44).overlay(Circle().strokeBorder(p.edge))
                }
                ForceCurve().frame(height: 180)
                HStack {
                    Text("0s").font(.system(size: 11)).foregroundStyle(p.mute)
                    Spacer()
                    Text("7s").font(.system(size: 11)).foregroundStyle(p.mute)
                }
            }
            .padding(16).background(p.card, in: .rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(p.edge))
            kit(
                #"{"type": "stat", "id": "pull", "items": [{"label": "Peak", "value": "41.6", "unit": "kg", "tone": "warn"}, {"label": "Body", "value": "58", "unit": "%"}, {"label": "Best", "value": "43.0", "unit": "kg"}]}"#
            )
            Text("Pull").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 56).background(p.lead, in: .capsule)
        }
        .padding(16).padding(.top, 36)
    }
}

struct Splash: View {
    let size: CGSize

    var body: some View {
        let stage = max(290, min(size.width * 0.8, 410))
        let aspect: CGFloat = 1080.0 / 1920.0
        let crop: CGFloat = {
            guard size.width / size.height > aspect else { return 0 }
            let p: CGFloat = size.width >= 720 ? 0.64 : 0.57
            return (0.5 - p) * (size.width / aspect - size.height)
        }()
        ZStack {
            Asset.cave.resizable().scaledToFill().frame(width: size.width, height: size.height).offset(y: crop)
                .frame(width: size.width, height: size.height).clipped()
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.168), location: 0), .init(color: .clear, location: 0.44),
                    .init(color: .black.opacity(0.346), location: 1),
                ], startPoint: .top, endPoint: .bottom)
            Asset.kangaroo.resizable().scaledToFit().frame(width: stage)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 16)
            VStack {
                Spacer()
                ProgressView().controlSize(.regular).tint(.white).padding(.bottom, 24)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}
