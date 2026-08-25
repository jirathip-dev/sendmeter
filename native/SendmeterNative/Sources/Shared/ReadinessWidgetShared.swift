import Foundation
#if SENDMETER_APP
import SendLogHealthCore
#endif

/// The phone app and its WidgetKit extension compile this small store from the
/// same source. It is intentionally App Group-only: falling back to
/// `UserDefaults.standard` would allow a stale process-local value to cross an
/// account boundary or disappear from the extension.
enum ReadinessWidgetStore {
    static let appGroup = "group.com.jirathip.sendlog"
    static let snapshotKey = "sendmeter.readiness-widget.snapshot"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    static func load() -> ReadinessWidgetSnapshot? {
        guard let data = defaults?.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(
                ReadinessWidgetSnapshot.self,
                from: data
              ),
              snapshot.isValid
        else { return nil }
        return snapshot
    }

    static func save(_ snapshot: ReadinessWidgetSnapshot) {
        guard snapshot.isValid,
              let data = try? JSONEncoder().encode(snapshot)
        else { return }
        defaults?.set(data, forKey: snapshotKey)
    }

    static func clear() {
        defaults?.removeObject(forKey: snapshotKey)
    }
}
