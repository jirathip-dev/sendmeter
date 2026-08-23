import SwiftUI
import WidgetKit

@main
struct SendmeterNativeWidgetsBundle: WidgetBundle {
    var body: some Widget {
        GuidedProtocolLiveActivity()
        ManualWorkoutLiveActivity()
    }
}
