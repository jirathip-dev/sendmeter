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

    // MARK: - Hands-free persist verdict (#682 Guard 1, watch parity)

    func testSubThresholdHandsFreeSalvageIsDiscardedNotSaved() {
        // A hands-free rep that dies mid-pull below 3 kg / 1.5 s is discarded,
        // the same Guard 1 the watch's salvageInterruptedRecording applies.
        XCTAssertFalse(
            ForceDisconnectSalvage.shouldPersistSalvage(wasHandsFree: true, peakKg: 2.9, durationMs: 10_000)
        )
        XCTAssertFalse(
            ForceDisconnectSalvage.shouldPersistSalvage(wasHandsFree: true, peakKg: 10.0, durationMs: 1_400)
        )
        XCTAssertTrue(
            ForceDisconnectSalvage.shouldPersistSalvage(wasHandsFree: true, peakKg: 3.1, durationMs: 1_600)
        )
        // Manual interrupted reps are never gated — a real hold dying mid-pull.
        XCTAssertTrue(
            ForceDisconnectSalvage.shouldPersistSalvage(wasHandsFree: false, peakKg: 2.9, durationMs: 1_400)
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
        // and unspecified — never a display fallback like `allTags[0]` nor the
        // live pickers.
        let resolved = ForceDisconnectSalvage.attribution(locked: .empty)
        XCTAssertEqual(resolved, .empty)
    }

    func testSalvageNeverReinterpretsUnsetSideAsBoth() {
        // Engineering rule: a locked `.unspecified` (user set no side) must
        // stay `.unspecified` — a salvaged rep never reinterprets a missing
        // side as both.
        let resolved = ForceDisconnectSalvage.attribution(
            locked: ForceDisconnectSalvage.Attribution(tag: "pocket", side: .unspecified)
        )
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
