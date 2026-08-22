import XCTest
@testable import SendmeterCore

final class ForceDisconnectSalvageTests: XCTestCase {
    // MARK: - Salvage gate (mirrors TindeqSalvagePolicy.swift)

    func testSalvageRequiresUnintentionalMeasuringAndTwoOrMoreSamples() {
        XCTAssertTrue(
            ForceDisconnectSalvage.shouldSalvage(wasIntentional: false, wasMeasuring: true, sampleCount: 2)
        )
        XCTAssertFalse(
            ForceDisconnectSalvage.shouldSalvage(wasIntentional: true, wasMeasuring: true, sampleCount: 2),
            "an intentional disconnect must not salvage"
        )
        XCTAssertFalse(
            ForceDisconnectSalvage.shouldSalvage(wasIntentional: false, wasMeasuring: false, sampleCount: 2),
            "a drop outside a recording must not salvage"
        )
        XCTAssertFalse(
            ForceDisconnectSalvage.shouldSalvage(wasIntentional: false, wasMeasuring: true, sampleCount: 1),
            "a single-sample drop is too trivial to recover"
        )
        XCTAssertFalse(
            ForceDisconnectSalvage.shouldSalvage(wasIntentional: false, wasMeasuring: true, sampleCount: 0)
        )
    }

    // MARK: - Locked tag/side attribution (web #298 "never a fallback")

    func testSalvagedRepPersistsExactlyTheLockedTagSide() {
        let locked = ForceDisconnectSalvage.Attribution(tag: "20 mm half crimp", side: .left)
        let resolved = ForceDisconnectSalvage.attribution(locked: locked)
        XCTAssertEqual(resolved.tag, "20 mm half crimp")
        XCTAssertEqual(resolved.side, .left)
    }

    func testSalvageNeverInventsTagOrSideWhenLockedIsEmpty() {
        // Locked empty (user set nothing): the rep is saved honest, untagged
        // and unspecified — never a display fallback like `allTags[0]`.
        let resolved = ForceDisconnectSalvage.attribution(
            locked: .empty,
            droppedSnapshot: .empty
        )
        XCTAssertEqual(resolved.tag, "")
        XCTAssertEqual(resolved.side, .unspecified)
    }

    func testSalvageNeverReinterpretsUnsetSideAsBoth() {
        // Engineering rule: a locked `.unspecified` (user set no side) must
        // stay `.unspecified` even when a drop-time snapshot carries `.both` —
        // a salvaged rep never reinterprets a missing side as both.
        let locked = ForceDisconnectSalvage.Attribution(tag: "pocket", side: .unspecified)
        let dropped = ForceDisconnectSalvage.Attribution(tag: "pocket", side: .both)
        let resolved = ForceDisconnectSalvage.attribution(locked: locked, droppedSnapshot: dropped)
        XCTAssertEqual(resolved.side, .unspecified)
    }

    func testLockedSideWinsOverSnapshotSide() {
        // The lock is authoritative for the side; the drop snapshot is only a
        // remount fallback for a missing TAG.
        let locked = ForceDisconnectSalvage.Attribution(tag: "", side: .left)
        let dropped = ForceDisconnectSalvage.Attribution(tag: "drift", side: .right)
        let resolved = ForceDisconnectSalvage.attribution(locked: locked, droppedSnapshot: dropped)
        XCTAssertEqual(resolved.side, .left)
        XCTAssertEqual(resolved.tag, "drift")
    }

    func testDropSnapshotFillsMissingTagForRemountRecovery() {
        // A fresh ForceView remount has not seeded its own pendingTag (web
        // #117), so the drop-time snapshot supplies the missing TAG. The SIDE
        // is never taken from the snapshot.
        let locked = ForceDisconnectSalvage.Attribution(tag: "", side: .unspecified)
        let dropped = ForceDisconnectSalvage.Attribution(tag: "warmup", side: .right)
        let resolved = ForceDisconnectSalvage.attribution(locked: locked, droppedSnapshot: dropped)
        XCTAssertEqual(resolved.tag, "warmup")
        XCTAssertEqual(resolved.side, .unspecified)
    }

    // MARK: - Failure is surfaced through the durable loss channel

    func testSalvageFailureReportsDurableLossNotTransientNotice() {
        let suite = "force-salvage-loss-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // The salvage failure path writes through the SAME durable one-shot
        // store the ordinary recording loss uses, under its own reason so a
        // salvage failure is distinguishable in the surfaced notice.
        XCTAssertTrue(
            LostRecordingStore.note(reason: ForceDisconnectSalvage.lossReason, in: defaults)
        )
        let notice = LostRecordingStore.take(in: defaults)
        XCTAssertEqual(notice?.count, 1)
        XCTAssertEqual(notice?.reasons, [ForceDisconnectSalvage.lossReason])
        // Cleared on read — the user is told exactly once.
        XCTAssertNil(LostRecordingStore.take(in: defaults))
    }

    func testSalvageLossesAccumulateWithOtherLossReasons() {
        let suite = "force-salvage-mixed-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        LostRecordingStore.note(reason: ForceDisconnectSalvage.lossReason, in: defaults)
        LostRecordingStore.note(reason: "recording", in: defaults)
        let notice = LostRecordingStore.take(in: defaults)
        XCTAssertEqual(notice?.count, 2)
        XCTAssertEqual(notice?.reasons, ["recording", ForceDisconnectSalvage.lossReason])
    }
}
