import BlocksUI
import SwiftUI

@MainActor
enum Tab: String, CaseIterable {
    case today = "Today"
    case session = "Session"
    case board = "Board"
    case force = "Force"
    case log = "Log"

    @ViewBuilder var icon: some View {
        switch self {
        case .today: SwiftUI.Image(systemName: "sun.max").font(.system(size: 20, weight: .medium))
        case .session: Asset.workoutTab.resizable().scaledToFit()
        case .board: SwiftUI.Image(systemName: "circle.grid.3x3").font(.system(size: 20, weight: .medium))
        case .force: Asset.forceTab.resizable().scaledToFit()
        case .log: SwiftUI.Image(systemName: "book.closed").font(.system(size: 20, weight: .medium))
        }
    }
}

struct TabBar: View {
    @Environment(\.look) private var look
    let selected: Tab
    let live: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                VStack(spacing: 3) {
                    ZStack(alignment: .topTrailing) {
                        tab.icon.frame(width: 26, height: 26)
                        if live && tab == .session {
                            Circle().fill(Ink.danger).frame(width: 8, height: 8).offset(x: 4, y: -2)
                        }
                    }
                    Text(tab.rawValue).font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(tab == selected ? look.palette.lead : look.palette.mute)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(tab == selected ? look.palette.lead.opacity(0.12) : .clear, in: .capsule)
            }
        }
        .padding(6)
        .background(look.palette.card, in: .capsule)
        .overlay(Capsule().strokeBorder(look.palette.edge, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .padding(.horizontal, 16)
    }
}

struct Sidebar: View {
    @Environment(\.look) private var look
    let selected: Tab
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sendmeter").font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(look.palette.foreground).padding(.horizontal, 12).padding(.bottom, 16)
            ForEach(Tab.allCases, id: \.self) { tab in
                HStack(spacing: 12) {
                    tab.icon.frame(width: 24, height: 24)
                    Text(tab.rawValue).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if live && tab == .session { Circle().fill(Ink.danger).frame(width: 8, height: 8) }
                }
                .foregroundStyle(tab == selected ? look.palette.lead : look.palette.foreground)
                .padding(.horizontal, 12).frame(height: 44)
                .background(tab == selected ? look.palette.lead.opacity(0.12) : .clear, in: .rect(cornerRadius: 12))
            }
            Spacer()
        }
        .padding(20).frame(width: 248).frame(maxHeight: .infinity)
        .background(look.palette.card)
        .overlay(alignment: .trailing) { Rectangle().fill(look.palette.edge).frame(width: 1) }
    }
}

struct Frame<Content: View>: View {
    let width: CGFloat
    let tab: Tab?
    let live: Bool
    let dark: Bool
    @ViewBuilder let content: Content

    var body: some View {
        let look = Sendmeter.look(dark: dark)
        Group {
            if width > 600 {
                HStack(spacing: 0) {
                    if let tab { Sidebar(selected: tab, live: live) }
                    content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(width: width).frame(minHeight: 900)
            } else {
                VStack(spacing: 0) {
                    if let tab {
                        content.frame(maxWidth: .infinity, alignment: .top)
                        Spacer(minLength: 16)
                        TabBar(selected: tab, live: live).padding(.bottom, 24)
                    } else {
                        content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
                .frame(width: width).frame(minHeight: 844)
            }
        }
        .background(look.palette.background)
        .blocksLook(look)
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}
