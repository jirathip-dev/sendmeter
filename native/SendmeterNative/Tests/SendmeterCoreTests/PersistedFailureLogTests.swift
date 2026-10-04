import Foundation
import XCTest
@testable import SendmeterCore

/// #992: the persisted failure line's composed fields. The app-target suite
/// (`PersistedFailureLogAppTests`) drives the real launch/sync funnels through
/// the injectable sink; this suite pins the line shape itself: domain and code
/// come from the bridged error, the class from the same taxonomy the
/// user-facing copy uses, and the level is the persisted `.notice` — never
/// `.debug`, which `log show` without `--debug` cannot see.
final class PersistedFailureLogTests: XCTestCase {
    func testSyncReplayLineCarriesDomainCodeClassAndUnsurfaced() {
        let line = PersistedFailureLog.line(
            channel: .syncReplayFailure,
            operation: "queue-upload:preset",
            error: URLError(.notConnectedToInternet),
            surfaced: false
        )

        XCTAssertEqual(
            line.level,
            .notice,
            "the line must be raised at the level that persists by default"
        )
        XCTAssertEqual(line.channel, .syncReplayFailure)
        XCTAssertEqual(line.domain, NSURLErrorDomain)
        XCTAssertEqual(line.code, URLError.Code.notConnectedToInternet.rawValue)
        XCTAssertEqual(line.classification, "offline")
        XCTAssertFalse(line.surfaced)
        XCTAssertTrue(
            line.message.hasPrefix("sync/replay failure op=queue-upload:preset "),
            "the log text must name the channel and the operation: \(line.message)"
        )
        XCTAssertTrue(line.message.contains("domain=NSURLErrorDomain"))
        XCTAssertTrue(
            line.message.contains("code=\(URLError.Code.notConnectedToInternet.rawValue)")
        )
        XCTAssertTrue(line.message.contains("class=offline"))
        XCTAssertTrue(line.message.contains("surfaced=false"))
    }

    func testLaunchLineKeepsThe964StepVocabularyAndCarriesSurfaced() {
        let line = PersistedFailureLog.line(
            channel: .launchFailure,
            operation: "refresh",
            error: NSError(domain: "Fixture.Domain", code: 7),
            surfaced: true
        )

        XCTAssertEqual(line.channel, .launchFailure)
        XCTAssertEqual(line.level, .notice)
        XCTAssertEqual(line.domain, "Fixture.Domain")
        XCTAssertEqual(line.code, 7)
        XCTAssertEqual(line.classification, "unknown")
        XCTAssertTrue(line.surfaced)
        XCTAssertTrue(
            line.message.hasPrefix("launch failure step=refresh "),
            "#964's device-grep vocabulary is kept: \(line.message)"
        )
        XCTAssertTrue(line.message.contains("surfaced=true"))
    }

    func testEmissionRunsForBothChannelsAndLevels() {
        // Exercises the production sink path (the switch over channel/level)
        // without asserting on the process log — the app-target suite and the
        // simulator log run prove the persisted side.
        PersistedFailureLog.emit(
            PersistedFailureLog.line(
                channel: .launchFailure,
                operation: "test-launch",
                error: URLError(.timedOut),
                surfaced: false
            )
        )
        PersistedFailureLog.emit(
            PersistedFailureLog.line(
                channel: .syncReplayFailure,
                operation: "test-sync",
                error: URLError(.timedOut),
                surfaced: true
            )
        )
    }
}
