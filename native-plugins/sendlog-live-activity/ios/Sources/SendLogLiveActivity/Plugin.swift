import Capacitor
import Foundation

/// JS bridge for the lock-screen Live Activities. All methods no-op below
/// iOS 17 (`isSupported` tells JS). Also relays the "an intent just ran"
/// signal to the WebView so it can drain the pending-action queue promptly
/// when it's alive.
@objc(SendLogLiveActivity)
public class SendLogLiveActivity: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "SendLogLiveActivity"
    public let jsName = "SendLogLiveActivity"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "isSupported", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestNotificationPermission", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startWorkoutActivity", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "updateWorkoutActivity", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "endWorkoutActivity", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startTindeqActivity", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "updateTindeqStats", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "endTindeqActivity", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getPendingActions", returnType: CAPPluginReturnPromise)
    ]

    private var observer: NSObjectProtocol?

    override public func load() {
        if #available(iOS 17.0, *) {
            observer = NotificationCenter.default.addObserver(
                forName: .sendlogLiveActivityAction, object: nil, queue: .main
            ) { [weak self] _ in
                self?.notifyListeners("liveActivityAction", data: [:])
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    @objc func isSupported(_ call: CAPPluginCall) {
        if #available(iOS 17.0, *) {
            call.resolve(["supported": true])
        } else {
            call.resolve(["supported": false])
        }
    }

    @objc func requestNotificationPermission(_ call: CAPPluginCall) {
        guard #available(iOS 17.0, *) else { return call.resolve(["granted": false]) }
        Task {
            let granted = await LiveActivityManager.shared.requestNotificationPermission()
            call.resolve(["granted": granted])
        }
    }

    @objc func startWorkoutActivity(_ call: CAPPluginCall) {
        guard #available(iOS 17.0, *) else { return call.resolve() }
        let startedAt = date(call, "startedAtMs") ?? Date()
        let phaseStartedAt = date(call, "phaseStartedAtMs") ?? startedAt
        let phase = call.getString("phase") ?? "resting"
        let restTargetS = call.getInt("restTargetS")
        let boulderCount = call.getInt("boulderCount") ?? 0
        Task {
            await LiveActivityManager.shared.startWorkout(
                startedAt: startedAt, phase: phase, phaseStartedAt: phaseStartedAt,
                restTargetS: restTargetS, boulderCount: boulderCount
            )
            call.resolve()
        }
    }

    @objc func updateWorkoutActivity(_ call: CAPPluginCall) {
        guard #available(iOS 17.0, *) else { return call.resolve() }
        let phase = call.getString("phase") ?? "resting"
        let phaseStartedAt = date(call, "phaseStartedAtMs") ?? Date()
        let restTargetS = call.getInt("restTargetS")
        let boulderCount = call.getInt("boulderCount") ?? 0
        Task {
            await LiveActivityManager.shared.updateWorkout(
                phase: phase, phaseStartedAt: phaseStartedAt,
                restTargetS: restTargetS, boulderCount: boulderCount
            )
            call.resolve()
        }
    }

    @objc func endWorkoutActivity(_ call: CAPPluginCall) {
        guard #available(iOS 17.0, *) else { return call.resolve() }
        let immediate = call.getBool("immediate") ?? false
        Task {
            await LiveActivityManager.shared.endWorkout(immediate: immediate)
            call.resolve()
        }
    }

    @objc func startTindeqActivity(_ call: CAPPluginCall) {
        guard #available(iOS 17.0, *) else { return call.resolve() }
        let title = call.getString("title") ?? "Force"
        let targetKg = call.getDouble("targetKg")
        let startEpochMs = call.getDouble("startEpochMs") ?? Date().timeIntervalSince1970 * 1000
        let segments = (call.getArray("segments") as? [[String: Any]]) ?? []
        Task {
            await LiveActivityManager.shared.startTindeq(
                title: title, targetKg: targetKg,
                startEpochMs: startEpochMs, segments: segments
            )
            call.resolve()
        }
    }

    @objc func updateTindeqStats(_ call: CAPPluginCall) {
        guard #available(iOS 17.0, *) else { return call.resolve() }
        guard let peakKg = call.getDouble("peakKg") else { return call.resolve() }
        Task {
            await LiveActivityManager.shared.updateTindeqStats(peakKg: peakKg)
            call.resolve()
        }
    }

    @objc func endTindeqActivity(_ call: CAPPluginCall) {
        guard #available(iOS 17.0, *) else { return call.resolve() }
        Task {
            await LiveActivityManager.shared.endTindeq()
            call.resolve()
        }
    }

    @objc func getPendingActions(_ call: CAPPluginCall) {
        guard #available(iOS 17.0, *) else { return call.resolve(["actions": []]) }
        let actions = LiveActivityManager.shared.drainPendingActions()
        call.resolve(["actions": actions])
    }

    private func date(_ call: CAPPluginCall, _ key: String) -> Date? {
        guard let ms = call.getDouble(key) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}
