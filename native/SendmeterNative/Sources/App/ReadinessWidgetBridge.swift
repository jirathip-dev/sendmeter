import Foundation
import SendLogHealthCore
import WidgetKit

/// App-process owner of the phone readiness widget. The widget only reads the
/// App Group payload; every write is fenced by the same account/epoch contract
/// as AppModel so a suspended old-account refresh cannot overwrite a newer
/// account's glanceable data.
enum ReadinessWidgetBridge {
    static let kind = "SendmeterReadiness"
    private static var lastPublishedSnapshot: ReadinessWidgetSnapshot?
    private static var reloadScheduled = false

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

        let shouldReload = ReadinessWidgetPublicationPolicy.shouldReload(
            previous: lastPublishedSnapshot,
            next: snapshot
        )
        store.save(snapshot)
        lastPublishedSnapshot = snapshot
        if shouldReload {
            requestReload()
        }
    }

    static func clear() {
        let store = ReadinessWidgetStore.appGroupStore
        let hadSnapshot = lastPublishedSnapshot != nil || store?.load() != nil
        store?.clear()
        lastPublishedSnapshot = nil
        if hadSnapshot {
            requestReload()
        }
    }

    static func reset(for currentUserID: UUID?) {
        let store = ReadinessWidgetStore.appGroupStore
        let snapshotOwner = store?.load()?.accountUserID
        let shouldClear = ReadinessWidgetOwnershipPolicy.shouldClearOnReset(
            snapshotOwner: snapshotOwner,
            currentUserID: currentUserID
        )
        if shouldClear {
            let hadSnapshot = lastPublishedSnapshot != nil || snapshotOwner != nil
            store?.clear()
            lastPublishedSnapshot = nil
            if hadSnapshot {
                requestReload()
            }
        }
    }

    private static func requestReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { @MainActor in
            reloadScheduled = false
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    }
}
