import Foundation
import os
import SendLogHealthCore
import WidgetKit

/// App-process owner of the phone readiness widget. The widget only reads the
/// App Group payload; every write is fenced by the same account/epoch contract
/// as AppModel so a suspended old-account refresh cannot overwrite a newer
/// account's glanceable data.
enum ReadinessWidgetBridge {
    static let kind = "SendmeterReadiness"
    private static let logger = Logger(
        subsystem: "com.jirathip.sendlog",
        category: "readiness-widget"
    )
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
        ) else { return }

        let store = ReadinessWidgetStore.appGroupStore
        let shouldReload = ReadinessWidgetPublicationPolicy.shouldReload(
            previous: lastPublishedSnapshot,
            next: snapshot
        )
        store.save(snapshot)
        lastPublishedSnapshot = snapshot
        if shouldReload {
            requestReload()
        }

        // #991: the App Group access no longer detaches from cfprefsd, but a
        // save that does not read back — unreachable container, protected
        // plist — is exactly the silent widget degradation this path can
        // still suffer. Persisted level (#992) so the device log can name it.
        if store.load() != snapshot {
            logger.notice(
                "readiness widget publish: payload did not read back after save"
            )
        }
    }

    static func clear() {
        let store = ReadinessWidgetStore.appGroupStore
        let hadSnapshot = lastPublishedSnapshot != nil || store.load() != nil
        store.clear()
        lastPublishedSnapshot = nil
        if hadSnapshot {
            requestReload()
        }
    }

    static func reset(for currentUserID: UUID?) {
        let store = ReadinessWidgetStore.appGroupStore
        // A nil read is "no stored snapshot": `load()` reports a payload it
        // cannot read exactly like an empty container. Treating it as absent
        // is the correct behaviour here — `shouldClearOnReset` then clears,
        // and clearing a snapshot that could not be read is a no-op write,
        // never data loss (the next publish rewrites it).
        let snapshotOwner = store.load()?.accountUserID
        let shouldClear = ReadinessWidgetOwnershipPolicy.shouldClearOnReset(
            snapshotOwner: snapshotOwner,
            currentUserID: currentUserID
        )
        if shouldClear {
            let hadSnapshot = lastPublishedSnapshot != nil || snapshotOwner != nil
            store.clear()
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
