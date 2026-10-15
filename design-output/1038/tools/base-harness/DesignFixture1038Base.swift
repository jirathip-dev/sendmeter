#if DEBUG
import SendmeterCore
import SwiftUI
import UIKit

/// #1038 design round — the BEFORE harness: the same states captured on the
/// pristine base (`2ee391e`, build 58) with ONLY this harness added, so the
/// before/after pair differs by the design alone.
///
/// States that exist on the base:
/// `force-disconnected`, `force-guided-armed`, `force-handsfree-armed`,
/// `force-recording`, `force-zone-armed`, `force-picker`.
/// The seed data (recordings, side modes, FDP curve) is copied verbatim from
/// the after harness, so before/after differ by design only.
enum DesignFixture1038Base {
    enum State: String, CaseIterable {
        case forceDisconnected = "force-disconnected"
        case forceGuidedArmed = "force-guided-armed"
        case forceHandsFreeArmed = "force-handsfree-armed"
        case forceRecording = "force-recording"
        case forceZoneArmed = "force-zone-armed"
        case forcePicker = "force-picker"

        var tab: AppTab { .force }

        var handsFreeMode: Bool {
            self == .forceHandsFreeArmed || self == .forceRecording
        }

        var armsSavedPreset: Bool { self == .forceGuidedArmed }
    }

    static let state: State? = {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--design-1038"),
              args.indices.contains(index + 1)
        else { return nil }
        return State(rawValue: args[index + 1])
    }()

    static let presetID = UUID(uuidString: "10380000-0000-0000-0000-000000000001")!

    static var armedPresetID: UUID? {
        guard let state, state.armsSavedPreset else { return nil }
        return presetID
    }

    static var armedZoneQuality: ZoneQuality? {
        state == .forceZoneArmed ? .strength : nil
    }

    static var presentsMovementPicker: Bool { state == .forcePicker }

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

    static let sideModes: [(String, ExerciseSideMode)] = [
        ("Pinch", .unilateralOnly),
        ("Lock-off", .unilateralOnly),
        ("Edge block", .bilateralOnly),
        ("Pull-up", .bilateralOnly),
        ("Core", .notApplicable)
    ]

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

        switch state {
        case .forceDisconnected:
            model.tindeq.designFixtureSet(status: .idle)
        case .forceGuidedArmed, .forceZoneArmed, .forcePicker:
            model.tindeq.designFixtureSet(status: .connected)
        case .forceHandsFreeArmed:
            model.tindeq.designFixtureSet(status: .connected)
            model.handsFree.onArmStream = {}
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                model.handsFree.arm()
            }
        case .forceRecording:
            model.tindeq.designFixtureSet(status: .measuring, samples: holdSamples())
        }
    }

    // MARK: Seed data (identical to the after round, so only design differs)

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

    /// (Copied from the after harness.) Twelve FDP pulls over three weeks at 10.2 s each, alternating sides,
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

struct DesignFixture1038BaseView: View {
    @Environment(AppModel.self) private var model
    @State private var applied = false

    init() {
        DesignFixture1038Base.writePreferences()
    }

    var body: some View {
        MainTabView()
            .onAppear {
                guard !applied else { return }
                applied = true
                DesignFixture1038Base.apply(to: model)
            }
    }
}
#endif
