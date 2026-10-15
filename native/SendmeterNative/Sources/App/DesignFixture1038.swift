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
/// `force-free-hold-saved`, `force-picker`, `force-picker-side`,
/// `force-zone-armed`, `force-free-hold-armed-last-pull` (scrolled to the
/// Progressor card's last-pull summary).
///
/// The guided full screen keeps its own #938 harness
/// (`--guided-force-fixture=work|rest|complete`), which this round reuses
/// rather than duplicating.
enum DesignFixture1038 {
    enum State: String, CaseIterable {
        case forceDisconnected = "force-disconnected"
        case forceGuidedArmed = "force-guided-armed"
        case forceFreeHoldArmed = "force-free-hold-armed"
        /// G6: the same state scrolled to the Progressor card — the last-pull summary
        /// that replaces the gauge card sits below the protocol grid.
        case forceFreeHoldArmedLastPull = "force-free-hold-armed-last-pull"
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
        /// G5: a movement tapped with no usable side history — the sheet
        /// stays open until the side is set, then closes.
        case forcePickerSide = "force-picker-side"
        /// H1 + H proposals: a SUGGESTED zone armed — the target row, its
        /// basis line and the intensity dial with value-placed ticks.
        case forceZoneArmed = "force-zone-armed"
        /// The face of the guided full screen is its own harness; this state
        /// only exists so the matrix has one entry per captured surface.
        case guidedFullscreen = "guided-fullscreen"

        var tab: AppTab { .force }

        /// Free hold or Guided on the bar's switch.
        var handsFreeMode: Bool {
            switch self {
            case .forceFreeHoldArmed, .forceFreeHoldArmedLastPull, .forceBarSession, .forceAfterFinish,
                 .forceHeldPull, .forceFreeHoldWaiting, .forceFreeHoldRecording,
                 .forceFreeHoldSaved, .forcePicker, .forcePickerSide:
                return true
            case .forceDisconnected, .forceGuidedArmed, .guidedFullscreen, .forceZoneArmed:
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
            // Free hold: two pulls already saved this session; the third is
            // recording, or has just saved.
            case .forceFreeHoldRecording: return 2
            case .forceFreeHoldSaved: return 3
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

    /// `force-zone-armed` arms the suggested Strength zone at 100 %.
    static var armedZoneQuality: ZoneQuality? {
        state == .forceZoneArmed ? .strength : nil
    }

    /// The FDP static fit the suggested zones are computed from (CF 10.1 kg,
    /// W′ 210 kg·s — the owner's build-58 screenshot numbers). Without it a
    /// zone tile is disabled, exactly as on a fresh account.
    static let fdpCurve = TagForceCurve(
        tag: "FDP",
        modality: "static",
        cf: 10.1,
        wPrime: 210,
        maxForceKilograms: 31.5
    )

    static var presentsMovementPicker: Bool {
        state == .forcePicker || state == .forcePickerSide
    }

    /// `force-picker-side`: Lock-off — one side at a time, and its only
    /// pulls predate side tracking, so there is no side to default to.
    static var pickerPendingMovement: String? {
        state == .forcePickerSide ? "Lock-off" : nil
    }

    /// The movement catalog's side policies (device-local, #720). Only the
    /// movements that DIFFER from "either side or both" are listed — the
    /// rest read as the default, exactly like a real account.
    static let sideModes: [(String, ExerciseSideMode)] = [
        ("Pinch", .unilateralOnly),
        ("Lock-off", .unilateralOnly),
        ("Edge block", .bilateralOnly),
        ("Pull-up", .bilateralOnly),
        ("Core", .notApplicable)
    ]

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
        model.designFixtureSetTagCurves([fdpCurve])
        for (name, mode) in sideModes {
            model.setTagSideMode(name: name, mode: mode)
        }

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
        case .forceGuidedArmed, .guidedFullscreen, .forcePicker, .forcePickerSide, .forceZoneArmed:
            model.tindeq.designFixtureSet(status: .connected)
        case .forceFreeHoldArmed, .forceFreeHoldArmedLastPull:
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
            model.designFixtureActivateGaugeSession(count: state.gaugeSessionCount, recordings: model.recordings)
            model.tindeq.designFixtureSet(status: .measuring, samples: holdSamples())
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                model.handsFree.arm()
                for sample in holdSamples() {
                    model.handsFree.feed(atMs: sample.milliseconds, kg: sample.kilograms)
                }
            }
        case .forceFreeHoldSaved:
            model.designFixtureActivateGaugeSession(count: state.gaugeSessionCount, recordings: model.recordings)
            // The machine re-armed for the next pull: the live buffer is
            // empty, exactly as after a real auto re-arm.
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

    /// Twelve FDP pulls over three weeks at 10.2 s each, alternating sides,
    /// plus one or two older pulls on each of eight other movements — the
    /// nine-movement catalog the owner's build-58 picker showed. FDP stays
    /// the newest movement; Half crimp and Pinch are the next most recent.
    static func recordings(reference: Date) -> [TindeqRecording] {
        fdpRecordings(reference: reference) + otherMovementRecordings(reference: reference)
    }

    static func otherMovementRecordings(reference: Date) -> [TindeqRecording] {
        let pulls: [(String, Double, TindeqSide, Double)] = [
            ("Half crimp", 2, .right, 27.8),
            ("Half crimp", 9, .left, 27.1),
            ("Pinch", 4, .left, 14.6),
            ("Edge block", 6, .both, 52.0),
            ("Open hand", 12, .right, 24.9),
            ("Pull-up", 15, .both, 38.5),
            // Logged before side tracking: no side to default to (G5).
            ("Lock-off", 20, .unspecified, 21.0),
            ("Wrist", 26, .left, 11.2),
            ("Core", 30, .unspecified, 18.4)
        ]
        return pulls.enumerated().map { index, pull in
            TindeqRecording(
                id: UUID(uuidString: String(format: "10380000-0000-0000-0005-%012d", index))!,
                recordedAt: reference.addingTimeInterval(-(pull.1 + 0.5) * 86_400),
                durationMilliseconds: 10_200,
                peakKilograms: pull.3,
                averageKilograms: pull.3 - 1.8,
                sampleCount: 820,
                note: "",
                tag: pull.0,
                side: pull.2,
                groupID: nil
            )
        }
    }

    static func fdpRecordings(reference: Date) -> [TindeqRecording] {
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

    /// The pull the SAVED panel and the held-pull states show. Its peak and
    /// average are DERIVED from the trace, so the hero, the card and the
    /// chart can never disagree (the WIP fixture claimed 31.2 kg over a
    /// trace that peaked at 31.9).
    static func holdSummary() -> ForceSummary {
        let samples = holdSamples()
        let values = samples.map(\.kilograms)
        return ForceSummary(
            durationMilliseconds: Int(samples.last?.milliseconds ?? 0),
            peakKilograms: values.max() ?? 0,
            averageKilograms: values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count),
            samples: samples
        )
    }

    /// A 24.0 s hold around 29 kg (80 Hz): ramp, hold with a slow fade and a
    /// little tremor; it stays under the seeded FDP best (31.5 kg), the
    /// usual case. Deterministic — no randomness.
    static func holdSamples() -> [TindeqSample] {
        stride(from: 0.0, through: 24_000.0, by: 12.5).map { ms in
            let t = ms / 1_000
            let ramp = min(1, t / 0.9)
            let fade = 1 - max(0, t - 14) * 0.012
            // Slow sway only: high-frequency tremor aliases into a sawtooth
            // when 24 s is drawn across one phone width.
            let tremor = 0.45 * sin(t * 1.7) + 0.2 * sin(t * 4.3)
            return TindeqSample(milliseconds: ms, kilograms: max(0, ramp * (29.6 * fade) + ramp * tremor))
        }
    }

    // MARK: G6 capture

    /// `force-free-hold-armed-last-pull` scrolls the Force tab so the
    /// Progressor card — the last-pull summary that replaces the gauge —
    /// is centred in frame (ForceView owns the scroll, via its proxy).
    static var scrollsToProgressorCard: Bool {
        state == .forceFreeHoldArmedLastPull
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
