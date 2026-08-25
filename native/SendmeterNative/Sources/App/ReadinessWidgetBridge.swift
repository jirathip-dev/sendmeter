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
        guard ReadinessWidgetOwnershipPolicy.canPublish(
            snapshot,
            currentUserID: scope.userID,
            currentEpoch: scope.epoch
        ),
        let store = ReadinessWidgetStore.appGroupStore
        else { return }

        store.save(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }

    static func clear() {
        ReadinessWidgetStore.appGroupStore?.clear()
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }

    static func reset(for currentUserID: UUID?) {
        let store = ReadinessWidgetStore.appGroupStore
        let snapshotOwner = store?.load()?.accountUserID
        if ReadinessWidgetOwnershipPolicy.shouldClearOnReset(
            snapshotOwner: snapshotOwner,
            currentUserID: currentUserID
        ) {
            store?.clear()
        }
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }
}
