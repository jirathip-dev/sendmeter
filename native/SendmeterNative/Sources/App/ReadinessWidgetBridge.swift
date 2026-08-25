import SendLogHealthCore
import WidgetKit

/// App-process owner of the phone readiness widget. The widget only reads the
/// App Group payload; every write is fenced by the same account/epoch contract
/// as AppModel so a suspended old-account refresh cannot overwrite a newer
/// account's glanceable data.
enum ReadinessWidgetBridge {
    static let kind = "SendmeterReadiness"

    static func publish(
        _ snapshot: ReadinessWidgetSnapshot,
        for scope: NativeAccountScope
    ) {
        guard let userID = scope.userID,
              snapshot.accountUserID == userID,
              snapshot.accountEpoch == scope.epoch,
              snapshot.isValid
        else { return }

        ReadinessWidgetStore.save(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }

    static func clear() {
        ReadinessWidgetStore.clear()
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }
}
