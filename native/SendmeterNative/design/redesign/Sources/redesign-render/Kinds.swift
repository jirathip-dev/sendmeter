import Blocks
import BlocksUI
import SwiftUI

enum HoldRole: String {
    case start, hand, finish, foot

    var color: Color {
        switch self {
        case .start: Ink.holdStart
        case .hand: Ink.holdHand
        case .finish: Ink.holdFinish
        case .foot: Ink.holdFoot
        }
    }
}

struct BoardKind: View {
    @Environment(\.look) private var look
    let block: JSONValue

    var body: some View {
        let columns = Int(block["columns"]?.number ?? 11)
        let rows = Int(block["rows"]?.number ?? 12)
        let lit = block["lit"]?.bool ?? false
        let height = block["height"]?.number ?? 360
        let holds = block.list("holds").compactMap { hold -> (Int, Int, HoldRole)? in
            guard let at = hold["at"]?.items, at.count == 2, let role = hold.string("role").flatMap(HoldRole.init)
            else { return nil }
            return (Int(at[0].number ?? 0), Int(at[1].number ?? 0), role)
        }
        GeometryReader { proxy in
            let cell = min(proxy.size.width / CGFloat(columns), proxy.size.height / CGFloat(rows))
            let origin = CGPoint(
                x: (proxy.size.width - cell * CGFloat(columns)) / 2, y: (proxy.size.height - cell * CGFloat(rows)) / 2)
            ZStack(alignment: .topLeading) {
                ForEach(0..<(columns * rows), id: \.self) { index in
                    let (c, r) = (index % columns, index / columns)
                    let wobble = CGFloat((c * 7 + r * 13) % 5) / 10 + 0.35
                    Circle().fill(Color.white.opacity(0.10))
                        .frame(width: cell * wobble, height: cell * wobble)
                        .position(x: origin.x + (CGFloat(c) + 0.5) * cell, y: origin.y + (CGFloat(r) + 0.5) * cell)
                }
                ForEach(Array(holds.enumerated()), id: \.offset) { _, hold in
                    let point = CGPoint(
                        x: origin.x + (CGFloat(hold.0) + 0.5) * cell, y: origin.y + (CGFloat(hold.1) + 0.5) * cell)
                    Circle().strokeBorder(hold.2.color.opacity(lit ? 1 : 0.55), lineWidth: lit ? 3 : 2)
                        .frame(width: cell * 0.86, height: cell * 0.86)
                        .shadow(color: lit ? hold.2.color.opacity(0.9) : .clear, radius: lit ? 8 : 0)
                        .position(point)
                }
            }
        }
        .frame(maxWidth: height * CGFloat(columns) / CGFloat(rows), minHeight: height, maxHeight: height)
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(Color(hex: "#1B1A1F"), in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(look.palette.edge, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            if let label = block.string("label") {
                Text(label).font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.white.opacity(0.10), in: .capsule).padding(18)
            }
        }
        .accessibilityLabel(block.string("label") ?? "Board")
    }
}

struct MascotKind: View {
    let block: JSONValue

    var body: some View {
        let size = block["size"]?.number ?? 120
        let image = block.string("name") == "force" ? Asset.forceLarge : Asset.workoutLarge
        image.resizable().scaledToFit().frame(width: size, height: size)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(block.string("name") ?? "mascot")
    }
}

enum Kinds {
    @MainActor static let all: AppBlocks = {
        do {
            return try AppBlocks([
                "board": { AnyView(BoardKind(block: $0)) },
                "mascot": { AnyView(MascotKind(block: $0)) },
            ])
        } catch {
            fatalError("app kinds: \(error)")
        }
    }()
}
