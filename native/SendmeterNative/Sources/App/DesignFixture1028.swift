#if DEBUG
import SendmeterCore
import SwiftUI
import UIKit

/// #1028 design-round harness (DEBUG only, launch-argument gated).
///
/// `--design-1028 <state>` renders the REAL `MainTabView` — real Force,
/// Dashboard and tab bar — from deterministic seeded data, without a
/// signed-in session or a Progressor, so the design round can be captured
/// and clicked through on a simulator. The app's normal signed-in flow never
/// reaches this view and Release builds do not contain it.
///
/// States (see `design-output/1028/README.md` for the capture matrix):
/// `force-disconnected`, `force-guided-idle`, `force-guided-armed`,
/// `force-recording`, `force-handsfree-armed`, `force-interrupted`,
/// `dashboard`. `--design-1028-scroll bottom` scrolls the tab's content to
/// its end (the F5 "nothing under the bars" evidence).
enum DesignFixture1028 {
    enum State: String, CaseIterable {
        case forceDisconnected = "force-disconnected"
        case forceGuidedIdle = "force-guided-idle"
        case forceGuidedArmed = "force-guided-armed"
        case forceRecording = "force-recording"
        case forceHandsFreeArmed = "force-handsfree-armed"
        case forceInterrupted = "force-interrupted"
        case dashboard
        /// F5 evidence only: the other tabs, for the scroll-to-end check.
        case workout
        case history
        case settings

        var tab: AppTab {
            switch self {
            case .dashboard: return .dashboard
            case .workout: return .workout
            case .history: return .history
            case .settings: return .settings
            default: return .force
            }
        }

        var armsSavedPreset: Bool {
            switch self {
            case .forceDisconnected, .forceGuidedArmed, .forceInterrupted: return true
            default: return false
            }
        }

        var handsFreeMode: Bool {
            self == .forceRecording || self == .forceHandsFreeArmed
        }
    }

    static let state: State? = {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--design-1028"),
              args.indices.contains(index + 1)
        else { return nil }
        return State(rawValue: args[index + 1])
    }()

    /// `--design-1028-mascots refined`: the C1/C2 candidates (crisper
    /// outlines + a carabiner) replace the approved masters in this run only.
    /// The shipped imagesets stay byte-identical until the owner approves.
    static var refinedMascots: Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--design-1028-mascots"),
              args.indices.contains(index + 1)
        else { return false }
        return args[index + 1] == "refined"
    }

    /// `--design-1028-scroll progressor`: Force scrolls its Progressor card
    /// (the C3 Force mascot's home) to the top — mascot evidence below the
    /// fold. ForceView owns the scroll, via its ScrollViewReader.
    static var scrollsToProgressor: Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--design-1028-scroll"),
              args.indices.contains(index + 1)
        else { return false }
        return args[index + 1] == "progressor"
    }

    static var scrollsToBottom: Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--design-1028-scroll"),
              args.indices.contains(index + 1)
        else { return false }
        return args[index + 1] == "bottom"
    }

    /// The saved preset the armed states select (fixed id so ForceView's
    /// DEBUG hook can arm it on appear).
    static let presetID = UUID(uuidString: "10280000-0000-0000-0000-000000000001")!

    static var armedPresetID: UUID? {
        guard let state, state.armsSavedPreset else { return nil }
        return presetID
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

        switch state {
        case .forceDisconnected:
            model.tindeq.designFixtureSet(status: .idle)
        case .forceGuidedIdle, .forceGuidedArmed:
            model.tindeq.designFixtureSet(status: .connected)
        case .forceHandsFreeArmed:
            model.tindeq.designFixtureSet(status: .connected)
            // The arm stream needs a live Progressor; the fixture keeps the
            // real state machine and swaps only the BLE side effect.
            model.handsFree.onArmStream = {}
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                model.handsFree.arm()
            }
        case .forceRecording:
            model.tindeq.designFixtureSet(status: .measuring, samples: holdSamples())
        case .forceInterrupted:
            model.tindeq.designFixtureSet(status: .interrupted("Progressor disconnected"))
        case .dashboard, .workout, .history, .settings:
            break
        }

        if scrollsToBottom {
            for delay in [1.0, 1.8, 2.6] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { scrollKeyWindowToBottom() }
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

    /// The owner's build-57 load state: an EWMA load ratio of 0.66 (#1022).
    /// Four ~490-load days a week for twelve weeks, then a light week
    /// (330 + 665) — `TrainingMetrics.computeACWR` resolves this to 0.66.
    static func sessions() -> [Session] {
        var built: [Session] = []
        func add(_ offset: Int, _ type: String, _ label: String, _ minutes: Int, _ rpe: Double) {
            let id = UUID(uuidString: String(format: "10280000-0000-0000-0001-%012d", offset))!
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

    /// The owner's readiness: 38 today, one other scored day 13 days ago
    /// (~18) — the 2-point trend of #1023. Unscored days still carry their
    /// recovery inputs, the way a partial HealthKit sync does.
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

    static func recordings(reference: Date) -> [TindeqRecording] {
        let zones: [RecordedZone] = [.strength, .power, .capacity, .strength, .endurance, .strength]
        return (0..<12).map { index in
            let daysBack = Double(index * 2 + 1)
            let peak = 31.5 - Double(index % 4) * 0.8
            return TindeqRecording(
                id: UUID(uuidString: String(format: "10280000-0000-0000-0002-%012d", index))!,
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

    // MARK: Scroll helper

    @MainActor
    private static func mainScrollView() -> (UIScrollView, UIWindow)? {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else { return nil }
        // The visible tab's main scroll view: on screen, vertically
        // scrollable, and covering the most window area.
        var best: (scroll: UIScrollView, area: CGFloat)?
        var queue: [UIView] = [window]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let scroll = view as? UIScrollView,
               !scroll.isHidden, scroll.alpha > 0.01, scroll.window != nil,
               scroll.contentSize.height > scroll.bounds.height {
                let frame = scroll.convert(scroll.bounds, to: window).intersection(window.bounds)
                let area = frame.isNull ? 0 : frame.width * frame.height
                if area > (best?.area ?? 0) { best = (scroll, area) }
            }
            queue.append(contentsOf: view.subviews)
        }
        return best.map { ($0.scroll, window) }
    }

    @MainActor
    private static func maxOffset(_ scroll: UIScrollView) -> CGFloat {
        max(
            scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom,
            -scroll.adjustedContentInset.top
        )
    }

    @MainActor
    private static func scrollKeyWindowToBottom() {
        guard let (scroll, _) = mainScrollView() else { return }
        scroll.setContentOffset(CGPoint(x: 0, y: maxOffset(scroll)), animated: false)
    }
}

/// Root of the #1028 harness: the real tab shell over seeded state.
struct DesignFixture1028View: View {
    @Environment(AppModel.self) private var model
    @State private var applied = false

    init() {
        DesignFixture1028.writePreferences()
    }

    var body: some View {
        MainTabView()
            .onAppear {
                guard !applied else { return }
                applied = true
                DesignFixture1028.apply(to: model)
            }
    }
}
#endif
