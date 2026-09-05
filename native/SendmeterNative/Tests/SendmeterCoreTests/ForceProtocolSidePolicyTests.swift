import Foundation
import SendmeterCore
import XCTest

/// #901: the SELECTED side decides the guided schedule — Left/Right run that
/// side only (no alternation, no switch-hands stages, explicit side stamps),
/// the preset's `alternateSides` flag only governs Both-mode (and the legacy
/// unspecified path). The same rule must mirror into the target-plan side set
/// (`ForceProtocolSidePolicy.planWorkSides`), which `resolveForceTargetPlan`
/// consumes.
final class ForceProtocolSidePolicyTests: XCTestCase {
    // MARK: - Alternate-side preset (alternateSides: true)

    func testAlternatingPresetWithLeftSelectionRunsLeftOnly() {
        let preset = Self.alternatingPreset()
        // `startingSide` must be irrelevant: a single-side selection never
        // alternates, whichever hand would have led the pair.
        for startingSide: TindeqSide in [.left, .right] {
            let stages = ForceProtocolSchedule.stages(
                preset: preset,
                startingSide: startingSide,
                selectedSide: .left
            )
            let work = stages.filter { $0.kind == .work }
            XCTAssertFalse(work.isEmpty, "a guided preset must produce work stages")
            XCTAssertTrue(
                work.allSatisfy { $0.side == .left },
                "every work stage must be .left for a Left selection; got \(work.map(\.side))"
            )
            XCTAssertFalse(
                stages.contains { $0.side == .right },
                "a Left selection must never produce an opposite-side stage"
            )
            XCTAssertFalse(
                stages.contains { $0.kind == .switchSide },
                "a Left selection must never produce a switch-hands stage"
            )
        }
    }

    func testAlternatingPresetWithRightSelectionRunsRightOnly() {
        let preset = Self.alternatingPreset()
        for startingSide: TindeqSide in [.left, .right] {
            let stages = ForceProtocolSchedule.stages(
                preset: preset,
                startingSide: startingSide,
                selectedSide: .right
            )
            let work = stages.filter { $0.kind == .work }
            XCTAssertFalse(work.isEmpty)
            XCTAssertTrue(work.allSatisfy { $0.side == .right })
            XCTAssertFalse(stages.contains { $0.side == .left })
            XCTAssertFalse(stages.contains { $0.kind == .switchSide })
        }
    }

    func testAlternatingPresetWithBothSelectionStillAlternatesHonoringStartingSide() {
        let preset = Self.alternatingPreset()
        let stagesLeftFirst = ForceProtocolSchedule.stages(
            preset: preset,
            startingSide: .left,
            selectedSide: .both
        )
        let workLeftFirst = stagesLeftFirst.filter { $0.kind == .work }
        XCTAssertEqual(workLeftFirst.first?.side, .left)
        XCTAssertTrue(workLeftFirst.contains { $0.side == .right })
        XCTAssertTrue(
            stagesLeftFirst.contains { $0.kind == .switchSide },
            "Both-mode alternation keeps its switch-hands stages"
        )

        // Starting side honored: a right-starting pair leads with Right.
        let stagesRightFirst = ForceProtocolSchedule.stages(
            preset: preset,
            startingSide: .right,
            selectedSide: .both
        )
        let workRightFirst = stagesRightFirst.filter { $0.kind == .work }
        XCTAssertEqual(workRightFirst.first?.side, .right)
        XCTAssertTrue(workRightFirst.contains { $0.side == .left })
    }

    func testUnspecifiedSelectionKeepsCurrentBehavior() {
        let preset = Self.alternatingPreset()
        // `selectedSide: .unspecified` (and the API default) must reproduce
        // the pre-#901 schedule exactly: alternation driven by the preset
        // flag alone. Stages carry random ids, so compare the executed
        // timeline (kind + side), not whole-stage equality.
        let legacy = ForceProtocolSchedule.stages(preset: preset, startingSide: .left)
        let explicit = ForceProtocolSchedule.stages(
            preset: preset,
            startingSide: .left,
            selectedSide: .unspecified
        )
        XCTAssertEqual(Self.timeline(legacy), Self.timeline(explicit))
        let work = explicit.filter { $0.kind == .work }
        XCTAssertTrue(work.contains { $0.side == .left })
        XCTAssertTrue(work.contains { $0.side == .right })
    }

    // MARK: - Non-alternating preset (alternateSides: false)

    func testNonAlternatingPresetStillStampsSingleSideExplicitly() {
        let preset = Self.nonAlternatingPreset()
        for selectedSide: TindeqSide in [.left, .right] {
            let stages = ForceProtocolSchedule.stages(
                preset: preset,
                startingSide: .left,
                selectedSide: selectedSide
            )
            let work = stages.filter { $0.kind == .work }
            XCTAssertFalse(work.isEmpty)
            XCTAssertTrue(
                work.allSatisfy { $0.side == selectedSide },
                "work stages must carry the selected side explicitly, not .unspecified; got \(work.map(\.side))"
            )
            XCTAssertFalse(stages.contains { $0.kind == .switchSide })
        }
    }

    func testNonAlternatingPresetWithBothKeepsLegacyUnspecifiedWorkStages() {
        let preset = Self.nonAlternatingPreset()
        let legacy = ForceProtocolSchedule.stages(preset: preset, startingSide: .left)
        let both = ForceProtocolSchedule.stages(
            preset: preset,
            startingSide: .left,
            selectedSide: .both
        )
        XCTAssertEqual(
            Self.timeline(legacy),
            Self.timeline(both),
            "Both on a non-alternating preset keeps today's schedule"
        )
        let work = both.filter { $0.kind == .work }
        XCTAssertTrue(work.allSatisfy { $0.side == .unspecified })
        XCTAssertFalse(both.contains { $0.kind == .switchSide })
    }

    // MARK: - ZoneMix recommended presets matrix

    func testZoneMixZonePresetsMatrix() {
        // Power/Strength/Power Endurance/Endurance ship via
        // `ZoneMix.zonePreset` with alternateSides: false — a single-side
        // selection must stamp that side explicitly and never alternate.
        let zones: [ZoneQuality] = [.power, .strength, .powerEndurance, .endurance]
        for zone in zones {
            let preset = ZoneMix.zonePreset(for: zone)
            XCTAssertFalse(preset.alternateSides)
            for selectedSide: TindeqSide in [.left, .right] {
                let stages = ForceProtocolSchedule.stages(
                    preset: preset,
                    startingSide: .left,
                    selectedSide: selectedSide
                )
                let work = stages.filter { $0.kind == .work }
                XCTAssertFalse(work.isEmpty, "zone \(zone) preset must produce work stages")
                XCTAssertTrue(work.allSatisfy { $0.side == selectedSide })
                XCTAssertFalse(stages.contains { $0.kind == .switchSide })
                XCTAssertFalse(stages.contains { $0.side == (selectedSide == .left ? .right : .left) })
            }
        }
    }

    func testZoneMixMaintenancePresetsMatrix() {
        // Warm-up/Prehab ship via `ZoneMix.maintenancePreset` with
        // alternateSides: true — THE #901 trap: a single-side selection must
        // override the flag and run that side only, while Both alternates.
        let references = ZoneCurveInput(cf: 40, maxForce: 60, wPrime: 100)
        let warmup = try? XCTUnwrap(
            ZoneMix.maintenancePreset(for: .warmup, personalRecord: 50)
        )
        let prehab = try? XCTUnwrap(
            ZoneMix.maintenancePreset(for: .prehab, model: references)
        )
        guard let warmup, let prehab else { return }
        for preset in [warmup, prehab] {
            XCTAssertTrue(preset.alternateSides)
            for selectedSide: TindeqSide in [.left, .right] {
                let stages = ForceProtocolSchedule.stages(
                    preset: preset,
                    startingSide: .left,
                    selectedSide: selectedSide
                )
                let work = stages.filter { $0.kind == .work }
                XCTAssertFalse(work.isEmpty)
                XCTAssertTrue(
                    work.allSatisfy { $0.side == selectedSide },
                    "\(preset.name): every work stage must be \(selectedSide); got \(work.map(\.side))"
                )
                XCTAssertFalse(
                    stages.contains { $0.side == (selectedSide == .left ? .right : .left) },
                    "\(preset.name): single-side selection must have zero opposite-side stages"
                )
                XCTAssertFalse(
                    stages.contains { $0.kind == .switchSide },
                    "\(preset.name): single-side selection must have zero switch-hands stages"
                )
            }
            // Both still alternates, starting side honored.
            let stages = ForceProtocolSchedule.stages(
                preset: preset,
                startingSide: .right,
                selectedSide: .both
            )
            let work = stages.filter { $0.kind == .work }
            XCTAssertEqual(work.first?.side, .right)
            XCTAssertTrue(work.contains { $0.side == .left })
            XCTAssertTrue(stages.contains { $0.kind == .switchSide })
        }
    }

    // MARK: - Target-plan mirror (resolveForceTargetPlan's side set)

    func testPlanWorkSidesMirrorsScheduleRule() {
        // Left/Right: selected side only, regardless of the preset flag.
        XCTAssertEqual(
            ForceProtocolSidePolicy.planWorkSides(
                selectedSide: .left,
                presetAlternates: true,
                startingSide: .right
            ),
            [.left]
        )
        XCTAssertEqual(
            ForceProtocolSidePolicy.planWorkSides(
                selectedSide: .right,
                presetAlternates: true,
                startingSide: .left
            ),
            [.right]
        )
        // Both/unspecified with an alternating preset: the per-side pair,
        // starting side honored.
        XCTAssertEqual(
            ForceProtocolSidePolicy.planWorkSides(
                selectedSide: .both,
                presetAlternates: true,
                startingSide: .left
            ),
            [.left, .right]
        )
        XCTAssertEqual(
            ForceProtocolSidePolicy.planWorkSides(
                selectedSide: .unspecified,
                presetAlternates: true,
                startingSide: .right
            ),
            [.right, .left]
        )
        // Non-alternating preset: the selected side's own band.
        for selectedSide: TindeqSide in [.left, .right, .both, .unspecified] {
            XCTAssertEqual(
                ForceProtocolSidePolicy.planWorkSides(
                    selectedSide: selectedSide,
                    presetAlternates: false,
                    startingSide: .left
                ),
                [selectedSide]
            )
        }
    }

    func testRunConstructionThreadsSelectedSideLikeTheSession() {
        // GuidedForceProtocolSession.init builds its run with
        // `selectedSide: fallbackSide` — a Left session run over an
        // alternating preset must be LEFT ONLY, end to end.
        let run = ForceProtocolRun(
            preset: Self.alternatingPreset(),
            startingSide: .left,
            selectedSide: .left
        )
        let work = run.stages.filter { $0.kind == .work }
        XCTAssertFalse(work.isEmpty)
        XCTAssertTrue(work.allSatisfy { $0.side == .left })
        XCTAssertFalse(run.stages.contains { $0.side == .right })
        XCTAssertFalse(run.stages.contains { $0.kind == .switchSide })
    }

    // MARK: - Fixtures

    /// The executable timeline (stage kind + side) — ids are random per
    /// construction, so cross-run schedule comparisons ignore them.
    private static func timeline(_ stages: [ForceProtocolStage]) -> [String] {
        stages.map { stage in "\\(stage.kind.rawValue)/\\(stage.side.rawValue)" }
    }

    private static func alternatingPreset() -> TindeqPreset {
        TindeqPreset(
            name: "Alternating Test",
            holdSeconds: 10,
            repetitions: 2,
            sets: 2,
            restBetweenRepetitionsSeconds: 60,
            restBetweenSetsSeconds: 120,
            alternateSides: true,
            prepareSeconds: 5
        )
    }

    private static func nonAlternatingPreset() -> TindeqPreset {
        TindeqPreset(
            name: "Single Side Test",
            holdSeconds: 10,
            repetitions: 2,
            sets: 2,
            restBetweenRepetitionsSeconds: 60,
            restBetweenSetsSeconds: 120,
            alternateSides: false,
            prepareSeconds: 5
        )
    }
}
