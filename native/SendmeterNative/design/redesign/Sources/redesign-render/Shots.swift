import BlocksUI
import SwiftUI

struct Shot {
    let name: String
    let draw: @MainActor (CGFloat) -> AnyView
}

@MainActor
func page(_ name: String, tab: Tab, beside: String? = nil, live: Bool = false) -> Shot {
    Shot(name: name) { width in
        AnyView(Frame(width: width, tab: tab, live: live, dark: false) { blocks(name, beside: beside, wide: width > 600) })
    }
}

@MainActor
func sheet(_ name: String, over base: String, tab: Tab) -> Shot {
    Shot(name: name) { width in
        let wide = width > 600
        return AnyView(
            Frame(width: width, tab: wide ? tab : nil, live: false, dark: false) {
                ZStack(alignment: wide ? .center : .bottom) {
                    blocks(base, wide: wide)
                    Color.black.opacity(0.3)
                    SheetCard { blocks(name, wide: false) }
                        .frame(width: wide ? 520 : nil)
                        .padding(.top, wide ? 0 : 300)
                }
            })
    }
}

enum Shots {
    @MainActor static let all: [Shot] = [
        page("today", tab: .today),
        page("board", tab: .board, beside: "route"),
        page("route", tab: .board),
        sheet("send", over: "route", tab: .board),
        page("history", tab: .log),
        page("logbook", tab: .log),
        page("settings", tab: .today),
        Shot(name: "session") { width in
            AnyView(
                Frame(width: width, tab: .session, live: true, dark: false) {
                    if width > 600 {
                        HStack(alignment: .top, spacing: 48) {
                            SessionLive().frame(width: 430)
                            WatchLive(state: "climb").padding(.top, 120)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        SessionLive()
                    }
                })
        },
        Shot(name: "watch") { width in
            AnyView(
                Frame(width: width, tab: nil, live: true, dark: true) {
                    if width > 600 {
                        HStack(spacing: 40) {
                            ForEach(["climb", "rest", "sent"], id: \.self) { WatchLive(state: $0) }
                        }
                        .padding(.top, 280)
                    } else {
                        WatchLive(state: "climb").scaleEffect(1.5).padding(.top, 260)
                    }
                })
        },
        Shot(name: "force") { width in
            AnyView(
                Frame(width: width, tab: .force, live: false, dark: false) {
                    ForceLive().frame(maxWidth: 560)
                })
        },
        Shot(name: "loading") { width in
            let size = CGSize(width: width, height: width > 600 ? 900 : 844)
            return AnyView(Splash(size: size).environment(\.colorScheme, .light))
        },
    ]
}

struct SheetCard<Content: View>: View {
    @Environment(\.look) private var look
    @ViewBuilder let content: Content

    var body: some View {
        content.padding(.top, -36)
            .background(look.palette.background, in: .rect(cornerRadius: 28))
            .overlay(alignment: .top) { Capsule().fill(look.palette.edge).frame(width: 36, height: 5).padding(.top, 8) }
    }
}
