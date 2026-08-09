import Foundation
@testable import SendLogWatchCore
import XCTest

final class HeartRateTimelineTests: XCTestCase {
    func testFreshValueIsNilBeforeAnySampleAccepted() {
        let timeline = HeartRateTimeline()
        XCTAssertNil(timeline.freshValue(at: Date(), maxAgeS: 30))
    }

    func testAcceptsAStrictlyNewerSample() {
        var timeline = HeartRateTimeline()
        let t0 = Date(timeIntervalSince1970: 1000)
        let t1 = t0.addingTimeInterval(1)
        XCTAssertTrue(timeline.accept(HeartRateSample(value: 120, sampleAt: t0)))
        XCTAssertTrue(timeline.accept(HeartRateSample(value: 130, sampleAt: t1)))
        XCTAssertEqual(timeline.current?.value, 130)
    }

    /// The load-bearing case (#477 finding 2): collapsing the per-type `Task`
    /// hop reduces reordering but a candidate whose OWN sample interval is
    /// older than the one already stored must still be rejected — the
    /// timeline is the last line of defence against out-of-order delivery.
    func testRejectsAnOlderSampleArrivingLate() {
        var timeline = HeartRateTimeline()
        let t0 = Date(timeIntervalSince1970: 1000)
        let older = t0.addingTimeInterval(-5)
        XCTAssertTrue(timeline.accept(HeartRateSample(value: 150, sampleAt: t0)))
        let accepted = timeline.accept(HeartRateSample(value: 90, sampleAt: older))
        XCTAssertFalse(accepted, "a sample older than the stored one must be rejected")
        XCTAssertEqual(timeline.current?.value, 150, "the newer sample must survive an out-of-order older arrival")
    }

    func testRejectsASampleWithTheExactSameTimestamp() {
        var timeline = HeartRateTimeline()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(timeline.accept(HeartRateSample(value: 150, sampleAt: t0)))
        XCTAssertFalse(timeline.accept(HeartRateSample(value: 999, sampleAt: t0)))
        XCTAssertEqual(timeline.current?.value, 150)
    }

    func testFreshValueReturnsTheLatestValueWithinTheAgeBound() {
        var timeline = HeartRateTimeline()
        let t0 = Date(timeIntervalSince1970: 1000)
        timeline.accept(HeartRateSample(value: 140, sampleAt: t0))
        XCTAssertEqual(timeline.freshValue(at: t0.addingTimeInterval(29), maxAgeS: 30), 140)
    }

    /// The load-bearing case (#477 finding 1/3): a held value must read as
    /// ABSENT once it ages past the bound, not keep returning the last
    /// number forever.
    func testFreshValueGoesAbsentPastTheAgeBound() {
        var timeline = HeartRateTimeline()
        let t0 = Date(timeIntervalSince1970: 1000)
        timeline.accept(HeartRateSample(value: 140, sampleAt: t0))
        XCTAssertNil(timeline.freshValue(at: t0.addingTimeInterval(31), maxAgeS: 30))
    }

    func testFreshValueAtExactlyTheAgeBoundIsStillFresh() {
        var timeline = HeartRateTimeline()
        let t0 = Date(timeIntervalSince1970: 1000)
        timeline.accept(HeartRateSample(value: 140, sampleAt: t0))
        XCTAssertEqual(timeline.freshValue(at: t0.addingTimeInterval(30), maxAgeS: 30), 140)
    }
}
