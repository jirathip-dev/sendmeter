#if DEBUG
import SendmeterCore
import SwiftUI
import UIKit

/// #1038 design-round harness (DEBUG only, launch-argument gated).
///
/// `--design-1038 <state>` renders the REAL `MainTabView` — real Force,
/// Guided full screen, picker and tab bar — from deterministic seeded data,
/// without a signed-in session or a Progressor, so the design round can be
/// captured and clicked through on a simulator. The app's normal signed-in
/// flow never reaches this view and Release builds do not contain it.
///
/// States (see `design-output/1038/README.md` for the capture matrix):
/// `force-disconnected`, `force-guided-armed`, `force-free-hold-armed`,
/// `force-bar-session`, `force-after-finish`, `force-held-pull`,
/// `force-free-hold-waiting`, `force-free-hold-recording`,
/// `force-free-hold-saved`, `force-picker`.
///
/// The guided full screen keeps its own #938 harness
/// (`--guided-force-fixture=work|rest|complete`), which this round reuses
/// rather than duplicating.
enum DesignFixture1038 {
    enum State: String, CaseIterable {
        case forceDisconnected = "force-disconnected"
        case forceGuidedArmed = "force-guided-armed"
        case forceFreeHoldArmed = "force-free-hold-armed"
        /// Amendment I: the sticky bar owning the session count + Finish.
        case forceBarSession = "force-bar-session"
        /// Amendment I: after Finish — session logged, Progressor
        /// disconnected, no auto-reconnect.
        case forceAfterFinish = "force-after-finish"
        /// I3: a held pull blocks Finish, and the bar says why.
        case forceHeldPull = "force-held-pull"
        case forceFreeHoldWaiting = "force-free-hold-waiting"
        case forceFreeHoldRecording = "force-free-hold-recording"
        case forceFreeHoldSaved = "force-free-hold-saved"
        case forcePicker = "force-picker"
        /// The face of the guided full screen is its own harness; this state
        /// only exists so the matrix has one entry per captured surface.
        case guidedFullscreen = "guided-fullscreen"

        var tab: AppTab { .force }

        /// Free hold or Guided on the bar's switch.
        var handsFreeMode: Bool {
            switch self {
            case .forceFreeHoldArmed, .forceBarSession, .forceAfterFinish,
                 .forceHeldPull, .forceFreeHoldWaiting, .forceFreeHoldRecording,
                 .forceFreeHoldSaved, .forcePicker:
                return true
            case .forceDisconnected, .forceGuidedArmed, .guidedFullscreen:
                return false
            }
        }

        /// Guided states arm the saved preset so the bar reads "Max Hangs 10 s"
        /// with Start as its action.
        var armsSavedPreset: Bool {
            switch self {
            case .forceGuidedArmed, .guidedFullscreen: return true
            default: return false
            }
        }

        /// Amendment I: how many recordings the active gauge session holds.
        var gaugeSessionCount: Int {
            switch self {
            case .forceBarSession, .forceHeldPull: return 3
            default: return 0
            }
        }

        /// The Free hold full screen opens in this state.
        var freeHoldScreen: FreeHoldScreen? {
            switch self {
            case .forceFreeHoldWaiting: return .waiting
            case .forceFreeHoldRecording: return .recording
            case .forceFreeHoldSaved: return .saved
            default: return nil
            }
        }
    }

    enum FreeHoldScreen: String {
        case waiting
        case recording
        case saved
    }

    static let state: State? = {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--design-1038"),
              args.indices.contains(index + 1)
        else { return nil }
        return State(rawValue: args[index + 1])
    }()

    /// The saved preset the guided states select (fixed id so ForceView's
    /// DEBUG hook can arm it on appear).
    static let presetID = UUID(uuidString: "10380000-0000-0000-0000-000000000001")!

    static var armedPresetID: UUID? {
        guard let state, state.armsSavedPreset else { return nil }
        return presetID
    }

    /// Presentation requests the Force screen honours on appear — the same
    /// DEBUG-hook shape #1028 used, so no production path changes.
    static var presentsFreeHoldScreen: FreeHoldScreen? {
        state?.freeHoldScreen
    }

    static var presentsMovementPicker: Bool {
        state == .forcePicker
    }

    /// Persisted Force preferences the real ForceView reads through
    /// `@AppStorage`. Written (not passed as argument-domain overrides) so a
    /// tap on the prototype's mode switch still persists.
    static func writePreferences() {
        guard let state else { return }
        let defaults = UserDefaults.standard
        defaults.set("FDP", forKey: "sendmeter.native.force.tag")
        defaults.set(TindeqSide.left.rawValue, forKey: "sendmeter.native.force.side")
        defaults.set(state.handsFreeMode, forKey: "sendmeter.native.force.hands-free")
    }

    @MainActor
    static func apply(to model: AppModel) {
        guard let state else { return }
        let now = Date()
        model.designFixtureSeed(
            sessions: sessions(),
            healthMetrics: healthMetrics(reference: now),
            presets: [preset],
            recordings: recordings(reference: now),
            healthSyncedAt: Calendar.current.date(
                bySettingHour: 6, minute: 34, second: 0, of: now
            )
        )
        model.selectedTab = state.tab

        // The free-hold arm stream needs a live Progressor; the fixture keeps
        // the real state machine and swaps only the BLE side effect.
        model.handsFree.onArmStream = {}
        model.handsFree.onBeginRecording = {}
        model.handsFree.onStopAndSave = {}
        model.handsFree.onAutoReArm = {}
        model.tindeq.onWeightSample = nil

        switch state {
        case .forceDisconnected:
            model.tindeq.designFixtureSet(status: .idle)
        case .forceGuidedArmed, .guidedFullscreen, .forcePicker:
            model.tindeq.designFixtureSet(status: .connected)
        case .forceFreeHoldArmed:
            model.tindeq.designFixtureSet(status: .connected)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                model.handsFree.arm()
                model.tindeq.designFixtureSetHandsFreeArmed(true)
            }
        case .forceBarSession, .forceAfterFinish:
            // Amendment I: a live session with recordings in it. Finish in the
            // bar logs the session and disconnects; the fixture keeps the real
            // `finishGaugeSessionAndDisconnect` path so the after-Finish
            // capture is produced by the real code, not a mock.
            model.tindeq.designFixtureSet(status: .connected)
            model.designFixtureActivateGaugeSession(
                count: state.gaugeSessionCount,
                recordings: model.recordings
            )
        case .forceHeldPull:
            // A completed pull is held unsaved: Finish must be blocked with
            // the reason, never silently drop the recording.
            model.tindeq.designFixtureSet(status: .connected)
            model.designFixtureActivateGaugeSession(
                count: state.gaugeSessionCount,
                recordings: model.recordings
            )
            model.tindeq.designFixtureHoldCompleted(holdSummary())
        case .forceFreeHoldWaiting:
            model.tindeq.designFixtureSet(status: .connected)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                model.handsFree.arm()
                model.tindeq.designFixtureSetHandsFreeArmed(true)
            }
        case .forceFreeHoldRecording:
            model.tindeq.designFixtureSet(status: .measuring, samples: holdSamples())
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                model.handsFree.arm()
                for sample in holdSamples() {
                    model.handsFree.feed(atMs: sample.milliseconds, kg: sample.kilograms)
                }
            }
        case .forceFreeHoldSaved:
            model.tindeq.designFixtureSet(status: .connected)
            model.tindeq.designFixtureHoldCompleted(holdSummary())
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                model.handsFree.arm()
                model.tindeq.designFixtureSetHandsFreeArmed(true)
            }
        }
    }

    // MARK: Seed data

    static let preset = TindeqPreset(
        id: presetID,
        name: "Max Hangs 10 s",
        holdSeconds: 10,
        repetitions: 1,
        sets: 5,
        restBetweenRepetitionsSeconds: 0,
        restBetweenSetsSeconds: 180,
        targetKilograms: 30,
        prepareSeconds: 5
    )

    /// The owner's load state (unchanged from the #1028 round, so the Force
    /// tab's context is the same in both rounds and only #1038's changes are
    /// visible in the diff).
    static func sessions() -> [Session] {
        var built: [Session] = []
        func add(_ offset: Int, _ type: String, _ label: String, _ minutes: Int, _ rpe: Double) {
            let id = UUID(uuidString: String(format: "10380000-0000-0000-0001-%012d", offset))!
            built.append(Session(
                id: id,
                date: LocalDateSupport.daysAgo(offset),
                type: type,
                typeLabel: label,
                durationMinutes: minutes,
                rpe: rpe,
                note: "",
                phase: .capacity
            ))
        }
        let plans: [(String, String)] = [
            ("board", "Board Climbing"), ("fingerboard", "Fingerboard"),
            ("gym", "Gym Session"), ("outdoor", "Outdoor Climbing")
        ]
        for offset in 7...89 where [1, 3, 5, 6].contains(offset % 7) {
            let plan = plans[offset % plans.count]
            add(offset, plan.0, plan.1, 70, 7)
        }
        add(5, "fingerboard", "Fingerboard", 55, 6)
        add(2, "board", "Board Climbing", 95, 7)
        return built.sorted { $0.date > $1.date }
    }

    static func healthMetrics(reference: Date) -> [HealthMetric] {
        (0..<21).map { offset in
            let readiness: Int? = offset == 0 ? 38 : (offset == 13 ? 18 : nil)
            let wave = sin(Double(offset) / 3)
            return HealthMetric(
                date: LocalDateSupport.daysAgo(offset, from: reference, timeZone: .current),
                readiness: readiness,
                zone: readiness == nil ? nil : "recover",
                computedAt: readiness == nil ? nil : reference,
                hrvSDNNMilliseconds: 48 + 9 * wave,
                restingHeartRate: 58 - 3 * wave,
                sleepHours: 6.4 + 0.6 * wave,
                sleepDeepHours: 1.1,
                sleepREMHours: 1.4,
                bodyMassKilograms: 68.2,
                respiratoryRate: 13.6
            )
        }
    }

    /// Twelve pulls over three weeks at 10.2 s each, alternating sides.
    static func recordings(reference: Date) -> [TindeqRecording] {
        let zones: [RecordedZone] = [.strength, .power, .capacity, .strength, .endurance, .strength]
        return (0..<12).map { index in
            let daysBack = Double(index * 2 + 1)
            let peak = 31.5 - Double(index % 4) * 0.8
            return TindeqRecording(
                id: UUID(uuidString: String(format: "10380000-0000-0000-0002-%012d", index))!,
                recordedAt: reference.addingTimeInterval(-daysBack * 86_400),
                durationMilliseconds: 10_200,
                peakKilograms: peak,
                averageKilograms: peak - 2.4,
                sampleCount: 820,
                note: "",
                tag: "FDP",
                side: index.isMultiple(of: 2) ? .left : .right,
                groupID: nil,
                zone: zones[index % zones.count]
            )
        }
    }

    /// The pull the SAVED panel and the held-pull states show: 30.3 s at
    /// 31.2 kg.
    static func holdSummary() -> ForceSummary {
        ForceSummary(
            durationMilliseconds: 30_300,
            peakKilograms: 31.2,
            averageKilograms: 29.4,
            samples: holdSamples()
        )
    }

    /// A 30.3 s hold around 30 kg (80 Hz): ramp, hold with a slow fade and a
    /// little tremor. Deterministic — no randomness.
    static func holdSamples() -> [TindeqSample] {
        stride(from: 0.0, through: 30_300.0, by: 12.5).map { ms in
            let t = ms / 1_000
            let ramp = min(1, t / 0.9)
            let fade = 1 - max(0, t - 18) * 0.012
            let tremor = 0.45 * sin(t * 9.1) + 0.25 * sin(t * 23.7)
            return TindeqSample(milliseconds: ms, kilograms: max(0, ramp * (31.2 * fade) + ramp * tremor))
        }
    }
}

/// Root of the #1038 harness: the real tab shell over seeded state.
struct DesignFixture1038View: View {
    @Environment(AppModel.self) private var model
    @State private var applied = false

    init() {
        DesignFixture1038.writePreferences()
    }

    var body: some View {
        MainTabView()
            .onAppear {
                guard !applied else { return }
                applied = true
                DesignFixture1038.apply(to: model)
            }
    }
}
#endif
