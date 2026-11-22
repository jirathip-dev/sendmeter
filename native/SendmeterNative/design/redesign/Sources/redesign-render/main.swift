import AppKit
import Blocks
import BlocksUI
import Foundation
import SwiftUI

let here = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
Asset.root = here.appendingPathComponent("../..").standardizedFileURL
let out = here.appendingPathComponent("png")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func screen(_ name: String) -> Block {
    let url = here.appendingPathComponent("screens/\(name).json")
    do {
        return try JSONDecoder().decode(Block.self, from: Data(contentsOf: url))
    } catch {
        fatalError("\(name).json: \(error)")
    }
}

@MainActor
func save(_ name: String, _ width: CGFloat, _ view: some View) {
    let host = NSHostingView(rootView: view)
    let size = host.fittingSize
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("rep \(name)") }
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png \(name)") }
    let file = out.appendingPathComponent("\(name)-\(Int(width)).png")
    do { try png.write(to: file) } catch { fatalError("write \(file.path): \(error)") }
    print(file.lastPathComponent, rep.pixelsWide, rep.pixelsHigh)
}

@MainActor
func blocks(_ name: String, beside: String? = nil, wide: Bool) -> some View {
    BlocksView(screen(name), source: nil, beside: wide ? beside.map(screen) : nil)
        .appBlocks(Kinds.all)
        .padding(BlocksView.inset)
        .frame(maxWidth: wide ? (beside == nil ? 760 : 1160) : .infinity, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.top, wide ? 24 : 52)
}

let only = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
for shot in Shots.all where only == nil || shot.name == only {
    for width in [CGFloat(390), 1440] {
        save(shot.name, width, shot.draw(width))
    }
}
