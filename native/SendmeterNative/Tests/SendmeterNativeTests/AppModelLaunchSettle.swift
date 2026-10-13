import Foundation
import XCTest
@testable import Sendmeter

/// #1015: the launch-pass settle gate shared by the app-target suites.
///
/// Every app-target test builds a REAL `AppModel` from a seeded auth session,
/// and every such model starts its own account bootstrap the moment the
/// `.initialSession` event lands: `prepareCacheIfNeeded` → `refreshAll`
/// (hydrate → launch repair → reconcile → legacy residue recovery) →
/// `drainQueue` → realtime join → live-workout fetch (`AppModel.swift:2002-2048`).
/// The harnesses used to return as soon as `currentUserID` was set, i.e. while
/// that pass was still running, and nothing ever waited for it to end. Two
/// channels follow from the ONE simulator / ONE app container the suite runs in:
///
/// * **in-test overlap** — the bootstrap's own refresh publishes its (older)
///   snapshot DURING the test's next `await`, so a value asserted right after
///   that await can be the bootstrap's, not the test's;
/// * **cross-test overlap** — the bootstrap tail outlives the test that
///   created it. The model is never released (`authObservationTask` holds it
///   for the stream's lifetime), so its `DurableQueue` actor — with its own
///   in-memory copy of the ONE shared `pending-writes.json` — can persist a
///   stale whole-file snapshot over a LATER test's intent, and its requests go
///   to whichever fake server the protocol's static slot names by then.
///
/// `settle` closes both: it presents the splash with no floor left (the
/// test-hosted model has no view hierarchy, so `bootState` would otherwise be
/// held at `.loading` for ever), then waits — against a wall-clock deadline —
/// until the bootstrap has published `.signedIn` with no refresh in flight.
/// Only after that does the test drive anything. The gate decides only WHEN a
/// test proceeds; nothing it asserts changes, and an expiry fails the test with
/// the state actually observed.
@MainActor
enum AppModelLaunchSettle {
    static let deadline: Duration = .seconds(90)

    static func isSettled(_ model: AppModel) -> Bool {
        model.currentUserID != nil
            && model.bootState == .signedIn
            && !model.isLoadingData
            && !model.isRefreshing
    }

    static func state(_ model: AppModel) -> String {
        [
            "currentUserID=\(model.currentUserID?.uuidString ?? "nil")",
            "bootState=\(String(describing: model.bootState))",
            "isLoadingData=\(model.isLoadingData)",
            "isRefreshing=\(model.isRefreshing)",
            "queuedWriteCount=\(model.queuedWriteCount)"
        ].joined(separator: ", ")
    }

    /// #1015 sweep (item 6): the same condition the old harness loops polled
    /// (`currentUserID != nil`), bounded by WALL CLOCK instead of a
    /// `Task.yield()` count — a yield budget can expire in ~0 s on a contended
    /// runner without the state ever having had a chance to change. It does
    /// not settle the bootstrap (those suites' timing is otherwise unchanged).
    static func waitForAccount(
        _ model: AppModel,
        timeout: Duration = AppModelLaunchSettle.deadline
    ) async {
        let started = ContinuousClock.now
        while model.currentUserID == nil, ContinuousClock.now - started < timeout {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    static func settle(
        _ model: AppModel,
        timeout: Duration = AppModelLaunchSettle.deadline,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        model.splashPresented(at: .distantPast)
        let started = ContinuousClock.now
        while ContinuousClock.now - started < timeout {
            if isSettled(model) { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        guard isSettled(model) else {
            XCTFail(
                "timed out after \(ContinuousClock.now - started) waiting for the account bootstrap to settle; observed \(state(model))",
                file: file,
                line: line
            )
            return
        }
    }
}
