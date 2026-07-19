import SwiftUI
import WidgetKit

/// The watch's WidgetKit extension: watch-face complications + Smart-Stack
/// widgets. Data comes from the shared App Group snapshot the watch app writes
/// (WidgetStore) — widgets can't hit the network, so the app pushes state and
/// reloads timelines on change.
@main
struct SendLogWatchWidgetsBundle: WidgetBundle {
    var body: some Widget {
        StatusWidget()        // readiness + ACWR (glanceable status)
        LiveWorkoutWidget()   // live boulders + climb/rest timer (Music-style)
        StartWorkoutWidget()  // quick-launch → Workout
        ForceGaugeWidget()    // quick-launch → Force gauge
    }
}
