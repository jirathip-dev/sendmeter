import Foundation

/// Snapshot the watch app writes to the shared App Group container for its
/// complications / Smart-Stack widgets to read. Widgets run in a SEPARATE
/// process and can't hit the network, so the app pushes everything they need
/// here and calls WidgetCenter.reloadAllTimelines() on changes.
///
/// KEEP IN SYNC with the identical copy in the SendLogWatchWidgets target —
/// the App Group serializes by Codable shape, so drift silently breaks decode.
struct WidgetSnapshot: Codable {
    // Glanceable daily status
    var readiness: Int?          // 0–100, nil until the iPhone syncs Health
    var readinessZone: String?   // recover | maintain | push
    var acwr: Double?            // acute:chronic training-load ratio
    var acwrRisk: String?        // low | optimal | caution | high

    // Live workout mirror (Music-style now-playing)
    var workoutActive: Bool
    var boulders: Int
    var climbing: Bool               // true = CLIMBING, false = RESTING
    var phaseSinceEpoch: Double?     // start of the current climb/rest phase
    var restTargetS: Int             // rest countdown target (for the timer)

    var updatedAt: Double            // epoch seconds

    static let empty = WidgetSnapshot(
        readiness: nil, readinessZone: nil, acwr: nil, acwrRisk: nil,
        workoutActive: false, boulders: 0, climbing: false,
        phaseSinceEpoch: nil, restTargetS: 180, updatedAt: 0
    )
}

enum WidgetStore {
    static let appGroup = "group.com.jirathip.sendlog"
    static let key = "widgetSnapshot"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func load() -> WidgetSnapshot {
        guard let data = defaults?.data(forKey: key),
              let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else { return .empty }
        return snap
    }

    static func save(_ snap: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snap) else { return }
        defaults?.set(data, forKey: key)
    }
}

/// Deep-link URLs the quick-launch widgets open the app to. RootView routes on
/// these (see .onOpenURL). KEEP IN SYNC across both targets.
enum WidgetRoute {
    static let scheme = "sendmeter"
    static let status = URL(string: "\(scheme)://status")!
    static let workout = URL(string: "\(scheme)://workout")!
    static let force = URL(string: "\(scheme)://force")!
}
