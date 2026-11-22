import AppKit
import SwiftUI

@MainActor
enum Asset {
    static var root = URL(fileURLWithPath: ".")

    static func image(_ set: String, _ file: String) -> SwiftUI.Image {
        let url = root.appendingPathComponent("Resources/Assets.xcassets/\(set).imageset/\(file)")
        guard let image = NSImage(contentsOf: url) else { fatalError("missing asset \(url.path)") }
        return SwiftUI.Image(nsImage: image)
    }

    static var workoutLarge: SwiftUI.Image { image("WorkoutMascotLarge", "workout-r16-optical-160.svg") }
    static var workoutTab: SwiftUI.Image { image("WorkoutMascotTab", "workout-r16-exact-24.svg") }
    static var forceLarge: SwiftUI.Image { image("ForceMascotLarge", "r11-force-control-160.svg") }
    static var forceTab: SwiftUI.Image { image("ForceMascotTab", "r11-force-control-24.svg") }
    static var cave: SwiftUI.Image { image("SplashCaveBackground", "splash-cave-background@2x.png") }
    static var kangaroo: SwiftUI.Image { image("SplashKangaroo", "splash-kangaroo@2x.png") }
}
