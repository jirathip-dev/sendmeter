import XCTest
@testable import SendmeterCore

final class LostRecordingNoticeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "lost-recording-notice-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRecordsLossAndHandsItBackExactlyOnce() {
        let at = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(LostRecordingStore.note(reason: "recording", in: defaults, now: at))
        let notice = LostRecordingStore.take(in: defaults)
        XCTAssertEqual(notice?.count, 1)
        XCTAssertEqual(notice?.lastAt, at)
        XCTAssertEqual(notice?.reasons, ["recording"])
        // Cleared on read — the user is told once, not on every foreground.
        XCTAssertNil(LostRecordingStore.take(in: defaults))
    }

    func testAccumulatesAcrossLosses() {
        let first = Date(timeIntervalSince1970: 1_000)
        let second = Date(timeIntervalSince1970: 1_060)
        let third = Date(timeIntervalSince1970: 1_120)
        LostRecordingStore.note(reason: "recording", in: defaults, now: first)
        LostRecordingStore.note(reason: "recording", in: defaults, now: second)
        LostRecordingStore.note(reason: "recording", in: defaults, now: third)
        let notice = LostRecordingStore.take(in: defaults)
        XCTAssertEqual(notice?.count, 3)
        XCTAssertEqual(notice?.lastAt, third)
    }

    func testDedupesReasonsAcrossSources() {
        LostRecordingStore.note(reason: "recording", in: defaults)
        LostRecordingStore.note(reason: "workout", in: defaults)
        LostRecordingStore.note(reason: "workout", in: defaults)
        let notice = LostRecordingStore.take(in: defaults)
        XCTAssertEqual(notice?.count, 3)
        XCTAssertEqual(notice?.reasons, ["recording", "workout"])
    }

    func testRefusesZeroCountAndMissingStorage() {
        XCTAssertFalse(LostRecordingStore.note(count: 0, reason: "recording", in: defaults))
        XCTAssertNil(LostRecordingStore.take(in: nil))
        XCTAssertFalse(LostRecordingStore.note(reason: "recording", in: nil))
    }

    func testCorruptRecordReadsAsNothingAndStartsFresh() {
        defaults.set(Data("not json".utf8), forKey: LostRecordingStore.defaultsKey)
        XCTAssertNil(LostRecordingStore.take(in: defaults))
        // …and starts a fresh count rather than inheriting the garbage.
        LostRecordingStore.note(reason: "recording", in: defaults)
        XCTAssertEqual(LostRecordingStore.take(in: defaults)?.count, 1)
    }

    func testNoteSurvivesStoreRecreation() {
        // Durability: a second store instance (a relaunch) still sees the notice.
        LostRecordingStore.note(reason: "recording", in: defaults)
        let fresh = UserDefaults(suiteName: suiteName)
        defer { fresh?.removePersistentDomain(forName: suiteName) }
        XCTAssertEqual(LostRecordingStore.take(in: fresh)?.count, 1)
    }
}
