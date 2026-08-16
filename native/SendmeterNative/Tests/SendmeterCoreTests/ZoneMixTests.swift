import XCTest
@testable import SendmeterCore

final class ZoneMixTests: XCTestCase {
    private func recording(
        id: String,
        durationMs: Int,
        zone: RecordedZone? = nil,
        side: TindeqSide = .unspecified
    ) -> TindeqRecording {
        TindeqRecording(
            id: UUID(uuidString: id)!,
            recordedAt: Date(timeIntervalSince1970: 0),
            durationMilliseconds: durationMs,
            peakKilograms: 20,
            averageKilograms: 18,
            sampleCount: 10,
            note: "",
            tag: "Crimps",
            side: side,
            groupID: nil,
            zone: zone
        )
    }

    // MARK: classifyZone

    func testClassifyZoneBucketsByHoldLength() {
        XCTAssertEqual(ZoneMix.classifyZone(durationSeconds: 1), .power)
        XCTAssertEqual(ZoneMix.classifyZone(durationSeconds: 6), .power)
        XCTAssertEqual(ZoneMix.classifyZone(durationSeconds: 6.5), .powerEndurance)
        XCTAssertEqual(ZoneMix.classifyZone(durationSeconds: 8.5), .powerEndurance)
        XCTAssertEqual(ZoneMix.classifyZone(durationSeconds: 9), .strength)
        XCTAssertEqual(ZoneMix.classifyZone(durationSeconds: 20), .strength)
        XCTAssertEqual(ZoneMix.classifyZone(durationSeconds: 21), .endurance)
    }

    func testClassifyZoneRejectsSubSecondBlips() {
        XCTAssertNil(ZoneMix.classifyZone(durationSeconds: 0.9))
    }

    // MARK: zoneSetDurationSeconds

    func testZoneSetDurationSecondsUsesProtocolReps() {
        XCTAssertEqual(ZoneMix.zoneSetDurationSeconds(.power), 30)
        XCTAssertEqual(ZoneMix.zoneSetDurationSeconds(.strength), 50)
        XCTAssertEqual(ZoneMix.zoneSetDurationSeconds(.powerEndurance), 42)
        // Endurance: holdS × reps × sets (the whole 8-hold protocol, #320).
        XCTAssertEqual(ZoneMix.zoneSetDurationSeconds(.endurance), 240)
    }

    // MARK: zone(for:) — recorded wins, maintenance excluded

    func testRecordedZoneWinsOverDuration() {
        // A 30s hold recorded as Power stays Power (it's a fact about how the
        // hold was performed, not a guess).
        let rec = recording(id: "00000000-0000-0000-0000-00000000000A", durationMs: 30_000, zone: .power)
        XCTAssertEqual(ZoneMix.zone(for: rec), .power)
    }

    func testUnrecordedZoneIsInferredFromDuration() {
        let rec = recording(id: "00000000-0000-0000-0000-00000000000A", durationMs: 10_000)
        XCTAssertEqual(ZoneMix.zone(for: rec), .strength)
    }

    func testMaintenanceZonesAreExcluded() {
        for zone in [RecordedZone.warmup, .prehab] {
            let rec = recording(id: "00000000-0000-0000-0000-00000000000A", durationMs: 10_000, zone: zone)
            XCTAssertNil(ZoneMix.zone(for: rec), "\(zone) must not count toward training balance")
        }
    }

    func testNativeCapacityZoneReadsAsEndurance() {
        let rec = recording(id: "00000000-0000-0000-0000-00000000000A", durationMs: 10_000, zone: .capacity)
        XCTAssertEqual(ZoneMix.zone(for: rec), .endurance)
    }

    // MARK: zoneSets

    func testZoneSetsNormaliseByProtocolSetDuration() {
        // 10s strength → 10/50 = 0.2 sets; 5s power → 5/30 sets.
        let sets = ZoneMix.zoneSets([
            recording(id: "00000000-0000-0000-0000-00000000000A", durationMs: 10_000, zone: .strength),
            recording(id: "00000000-0000-0000-0000-00000000000B", durationMs: 5_000, zone: .power),
        ])
        XCTAssertEqual(sets[.strength], 0.2)
        XCTAssertEqual(sets[.power] ?? 0, 5.0 / 30.0, accuracy: 1e-12)
        XCTAssertEqual(sets[.powerEndurance] ?? 0, 0)
        XCTAssertEqual(sets[.endurance] ?? 0, 0)
    }

    func testZoneSetsExcludesMaintenanceRecordings() {
        let sets = ZoneMix.zoneSets([
            recording(id: "00000000-0000-0000-0000-00000000000A", durationMs: 60_000, zone: .warmup),
        ])
        XCTAssertEqual(sets.values.reduce(0, +), 0)
    }

    // MARK: dominantZone

    func testDominantZonePicksHighestSetCount() {
        let sets: [ZoneQuality: Double] = [.power: 0.1, .strength: 0.8, .powerEndurance: 0.3, .endurance: 0.2]
        XCTAssertEqual(ZoneMix.dominantZone(sets), .strength)
    }

    func testDominantZoneBreaksTiesDeterministically() {
        let sets: [ZoneQuality: Double] = [.power: 0.5, .strength: 0.5, .powerEndurance: 0.1, .endurance: 0.1]
        // zoneOrder is [power, strength, power-endurance, endurance].
        XCTAssertEqual(ZoneMix.dominantZone(sets), .power)
    }

    func testDominantZoneIsNilWhenAllZonesEmpty() {
        XCTAssertNil(ZoneMix.dominantZone([:]))
        XCTAssertNil(ZoneMix.dominantZone([.power: 0, .strength: 0]))
    }
}
