import Foundation
import Capacitor

/// Bridges the web layer to the native iPhone health pipeline: HealthKit read
/// + readiness compute + Supabase upsert (see HealthSyncManager). The heavy
/// lifting is self-contained natively so background wakes work without the
/// WebView being alive.
@objc(SendLogHealth)
public class SendLogHealth: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "SendLogHealth"
    public let jsName = "SendLogHealth"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "requestAuthorization", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setSession", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "syncNow", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearAndResync", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startBackgroundSync", returnType: CAPPluginReturnPromise),
    ]

    private let manager = HealthSyncManager.shared

    @objc func requestAuthorization(_ call: CAPPluginCall) {
        Task {
            do { try await manager.requestAuthorization(); call.resolve() }
            catch { call.reject(error.localizedDescription) }
        }
    }

    @objc func setSession(_ call: CAPPluginCall) {
        guard
            let accessToken = call.getString("accessToken"),
            let refreshToken = call.getString("refreshToken")
        else {
            call.reject("Missing accessToken/refreshToken")
            return
        }
        Task {
            do {
                try await manager.setSession(accessToken: accessToken, refreshToken: refreshToken)
                call.resolve()
            } catch { call.reject(error.localizedDescription) }
        }
    }

    @objc func syncNow(_ call: CAPPluginCall) {
        Task {
            do { try await manager.syncNow(); call.resolve() }
            catch { call.reject(error.localizedDescription) }
        }
    }

    @objc func clearAndResync(_ call: CAPPluginCall) {
        Task {
            do { try await manager.clearAndResync(); call.resolve() }
            catch { call.reject(error.localizedDescription) }
        }
    }

    @objc func startBackgroundSync(_ call: CAPPluginCall) {
        manager.startBackgroundSync()
        call.resolve()
    }
}
