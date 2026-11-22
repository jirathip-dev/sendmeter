import BlocksUI
import SwiftUI

enum Ink {
    static let primary = Color(hex: "#5B5FC7")
    static let optimal = Color(hex: "#2E96F0")
    static let caution = Color(hex: "#DDB13A")
    static let danger = Color(hex: "#F07A3A")
    static let chalk = Color(hex: "#F3F3F7")
    static let slate = Color(hex: "#0B0C12")
    static let holdStart = Color(hex: "#3CCB6B")
    static let holdHand = Color(hex: "#2E96F0")
    static let holdFinish = Color(hex: "#D64FD0")
    static let holdFoot = Color(hex: "#F0A23A")
}

extension Color {
    init(hex: String) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        self.init(
            .sRGB, red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255)
    }
}

enum Sendmeter {
    static let light = Palette(
        background: Color(hex: "#F3F3F7"), card: Color(hex: "#FFFFFF"), edge: Color(hex: "#D8D8DE"),
        line: Color(hex: "#E2E2E6"), foreground: Color(hex: "#15161C"), mute: Color(hex: "#52525C"),
        lead: Color(hex: "#5B5FC7"), link: Color(hex: "#4A4EAC"), green: Color(hex: "#216CAD"),
        amber: Color(hex: "#7E6521"), red: Color(hex: "#A35229"), purple: Color(hex: "#5C62B0"),
        cyan: Color(hex: "#216CAD"), dark: false)

    static let dark = Palette(
        background: Color(hex: "#0B0C12"), card: Color(hex: "#17181F"), edge: Color(hex: "#363743"),
        line: Color(hex: "#30313B"), foreground: Color(hex: "#F4F4F8"), mute: Color(hex: "#B9BAC6"),
        lead: Color(hex: "#9296EE"), link: Color(hex: "#A9ADE3"), green: Color(hex: "#4FB0FF"),
        amber: Color(hex: "#E8C24E"), red: Color(hex: "#F0864C"), purple: Color(hex: "#9296EE"),
        cyan: Color(hex: "#4FB0FF"), dark: true)

    static let tiles = Tiles(tokens: [
        "--radius": "18px", "--seam": "10px", "--dot-size": "0px", "--dot-gap": "16px", "--dot": "var(--edge)",
        "--settle": "160ms", "--rise": "8px", "--stagger": "40ms", "--build": "200ms", "--enter": "160ms",
        "--ease": "cubic-bezier(0.2, 0, 0, 1)",
    ])

    static func look(dark: Bool) -> Look {
        Look(palette: dark ? Self.dark : Self.light, still: true, tiles: tiles)
    }
}
