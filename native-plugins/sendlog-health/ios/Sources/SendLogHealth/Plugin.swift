import Foundation
import Capacitor
import SendLogHealthCore

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
        CAPPluginMethod(name: "clearSession", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "syncNow", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearAndResync", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startBackgroundSync", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getLatestReadiness", returnType: CAPPluginReturnPromise),
    ]

    private let manager = HealthSyncManager.shared
    /// App Store screenshot UI tests launch with fastlane's standard argument.
    /// HealthKit's authorization controller is a separate full-screen process,
    /// so it cannot be dismissed reliably from the app's UI-test tree. Fixture
    /// readiness already comes from local Supabase; keep screenshot runs out of
    /// HealthKit entirely without changing any normal app launch.
    private var isScreenshotRun: Bool {
        UserDefaults.standard.bool(forKey: "FASTLANE_SNAPSHOT")
    }

    override public func load() {
        // No rotating credential may survive on this device — including one
        // left in the Keychain by a build that predates #265.
        HealthSessionStore.shared.purgeLegacySupabaseKeychain()
        manager.installReadinessBridge()
        manager.setReadinessResultHandler { [weak self] result in
            self?.notifyListeners("readinessRefresh", data: result.message())
        }
    }

    @objc func requestAuthorization(_ call: CAPPluginCall) {
        guard !isScreenshotRun else { call.resolve(); return }
        Task {
            do { try await manager.requestAuthorization(); call.resolve() }
            catch { call.reject(error.localizedDescription) }
        }
    }

    /// Access token only (#265) — this plugin never holds a refresh token, so
    /// it can never present one to `/token` and trip Supabase's reuse
    /// detection. Synchronous now: storing a token is a Keychain write.
    @objc func setSession(_ call: CAPPluginCall) {
        guard let accessToken = call.getString("accessToken") else {
            call.reject("Missing accessToken")
            return
        }
        manager.setSession(accessToken: accessToken)
        call.resolve()
    }

    @objc func clearSession(_ call: CAPPluginCall) {
        manager.clearSession()
        call.resolve()
    }

    /// Returns the latest compact native result so a phone UI opened after a
    /// background HealthKit wake can re-read without making a duplicate fetch.
    @objc func getLatestReadiness(_ call: CAPPluginCall) {
        if let result = manager.latestReadinessResult() {
            call.resolve(result.message())
        } else {
            call.resolve([:])
        }
    }

    // #109: `trigger` is read from the JS-facing call, NOT assumed —
    // `syncHealthNow`/`startHealthBackgroundSync` (visibilitychange foreground
    // and cold-launch respectively) are app-driven, not a user gesture, and
    // pass "automatic" explicitly. There's no user-refresh gesture in the app
    // today, so a missing/unrecognized `trigger` fails safe as `.automatic`
    // (respects ReadinessWritePolicy's after-noon lock) rather than the unsafe
    // `.manual` (always overwrites) — see HealthSyncManager.syncNow.
    @objc func syncNow(_ call: CAPPluginCall) {
        guard !isScreenshotRun else { call.resolve(); return }
        let trigger: SyncTrigger = call.getString("trigger") == "manual" ? .manual : .automatic
        Task {
            do { try await manager.syncNow(trigger: trigger); call.resolve() }
            catch { call.reject(error.localizedDescription) }
        }
    }

    @objc func clearAndResync(_ call: CAPPluginCall) {
        guard !isScreenshotRun else { call.resolve(); return }
        Task {
            do { try await manager.clearAndResync(); call.resolve() }
            catch { call.reject(error.localizedDescription) }
        }
    }

    @objc func startBackgroundSync(_ call: CAPPluginCall) {
        guard !isScreenshotRun else { call.resolve(); return }
        manager.startBackgroundSync()
        call.resolve()
    }
}
