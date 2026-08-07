import Foundation
import XCTest
import SendLogWatchCore
@testable import SendLogWatch_Watch_App

/// #491 acceptance: queue-depth reporting cannot silently under-report when
/// one source fails to report. Two structural guards replace the old "all
/// four `async let`s must stay in the tuple" comment in `WatchBuild` (which
/// nearly lost a queue in the #475/#486 merge): `PendingSyncCache` refuses a
/// total until every `PendingSyncQueue` case has published (covered in
/// `SendLogWatchCoreTests`), and this test pins that the refresh registry
/// covers every case — so a queue can be neither dropped from the refresh
/// nor added without a cache slot.
final class WatchQueueReportingTests: XCTestCase {
    @MainActor
    func testReportingRegistryCoversEveryPendingSyncQueue() {
        let registered = Set(WatchBuild.reportingQueues.map { $0.syncSlot })
        XCTAssertEqual(
            registered,
            Set(PendingSyncQueue.allCases),
            "every PendingSyncQueue case needs a registered reporter — a missing one would make the cache's total stay nil (honest, but permanently) and a duplicate would mask a missing one"
        )
        XCTAssertEqual(
            WatchBuild.reportingQueues.count,
            PendingSyncQueue.allCases.count,
            "one reporter per slot — a duplicate slot would double-refresh one queue while another goes missing from the set comparison above"
        )
    }
}

/// #495 R4: `HomeView.onAppear` used to REPLACE `lossQueue` with whatever it
/// just consumed, dropping a notice that was still waiting to be presented
/// (its alert had been dismissed by navigation, not by OK). `LossNotice.merged`
/// is the pure fix; these pin its contract.
final class LossNoticeMergeTests: XCTestCase {
    func testAnUnpresentedNoticeSurvivesWhenNothingNewIsConsumed() {
        XCTAssertEqual(LossNotice.merged(existing: [.recording], consumed: []), [.recording])
    }

    func testNewlyConsumedKindsAppendBehindWhatIsStillWaiting() {
        // The waiting notice keeps its place at the front — it was consumed
        // (and owed a presentation) first.
        XCTAssertEqual(
            LossNotice.merged(existing: [.recording], consumed: [.gaugeSession]),
            [.recording, .gaugeSession]
        )
    }

    func testAKindAlreadyWaitingIsNotDuplicated() {
        // The backing flags are one-shot booleans: N losses of one kind are
        // indistinguishable from one, so presenting the notice twice would
        // claim knowledge we don't have.
        XCTAssertEqual(
            LossNotice.merged(existing: [.recording], consumed: [.recording, .gaugeSession]),
            [.recording, .gaugeSession]
        )
    }

    func testNothingWaitingAndNothingConsumedStaysEmpty() {
        XCTAssertEqual(LossNotice.merged(existing: [], consumed: []), [])
    }

    func testFreshConsumptionOntoAnEmptyQueueIsJustTheConsumedList() {
        XCTAssertEqual(
            LossNotice.merged(existing: [], consumed: [.gaugeSession, .recording]),
            [.gaugeSession, .recording]
        )
    }
}
