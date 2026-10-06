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
        XCTAssertNil(line.detail, "a transport error has no schema detail")
        XCTAssertTrue(line.message.hasSuffix("surfaced=true"), "no detail field without a detail")
    }

    // MARK: - #1020: the line names the decode path / delta case by itself

    /// The real decode error a refresh slice raises when a row's
    /// `updated_at` is unreadable: the line must carry the decode kind and
    /// the codingPath KEYS (array index collapsed), never the value.
    func testDecodeFailureLineCarriesTheCodingPathKeysAndNoValue() throws {
        struct Row: Decodable {
            let updatedAt: Date
            enum CodingKeys: String, CodingKey { case updatedAt = "updated_at" }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 timestamp: \(value)"
            )
        }
        let secretValue = "owner-private-value-1020"
        let error: Error
        do {
            _ = try decoder.decode([Row].self, from: Data(#"[{"updated_at":"\#(secretValue)"}]"#.utf8))
            return XCTFail("fixture: the row must not decode")
        } catch let thrown {
            error = thrown
        }

        let line = PersistedFailureLog.line(
            channel: .launchFailure,
            operation: "refresh-slice:presets",
            error: error,
            surfaced: true
        )

        XCTAssertEqual(line.detail, "decode=dataCorrupted path=*.updated_at")
        XCTAssertEqual(line.classification, "dataUnreadable")
        XCTAssertTrue(line.message.hasPrefix("launch failure step=refresh-slice:presets "))
        XCTAssertTrue(line.message.hasSuffix(" surfaced=true decode=dataCorrupted path=*.updated_at"))
        XCTAssertFalse(line.message.contains(secretValue), "a value never reaches the log")
    }

    func testMissingKeyLineNamesTheMissingKey() throws {
        struct Row: Decodable {
            let steps: [Step]
            struct Step: Decodable { let kind: String }
        }
        let error: Error
        do {
            _ = try JSONDecoder().decode(Row.self, from: Data(#"{"steps":[{"kind":"hang"},{}]}"#.utf8))
            return XCTFail("fixture: the second step must not decode")
        } catch let thrown {
            error = thrown
        }

        XCTAssertEqual(PersistedFailureLog.detail(for: error), "decode=keyNotFound path=steps.*.kind")
    }

    /// A dictionary-keyed payload puts USER content in the codingPath (a tag
    /// name, a date string). Only plain identifiers may pass.
    func testUserContentInACodingPathKeyIsRedacted() throws {
        let error: Error
        do {
            _ = try JSONDecoder().decode(
                [String: Int].self,
                from: Data(#"{"Owner's crimp tag":"seven"}"#.utf8)
            )
            return XCTFail("fixture: the value must not decode")
        } catch let thrown {
            error = thrown
        }

        let detail = try XCTUnwrap(PersistedFailureLog.detail(for: error))
        XCTAssertEqual(detail, "decode=typeMismatch path=?")
        XCTAssertFalse(detail.contains("crimp"))
    }

    func testDeltaReaderFailureLineNamesTheCase() {
        XCTAssertEqual(
            PersistedFailureLog.detail(for: DeltaReadError.cursorDidNotAdvance),
            "delta=cursorDidNotAdvance"
        )
        XCTAssertEqual(PersistedFailureLog.detail(for: DeltaReadError.outOfOrderPage), "delta=outOfOrderPage")
        XCTAssertEqual(
            PersistedFailureLog.detail(for: DeltaReadError.pageBudgetExhausted(pageLimit: 3)),
            "delta=pageBudgetExhausted"
        )
        let line = PersistedFailureLog.line(
            channel: .launchFailure,
            operation: "refresh-slice:tagMetadata",
            error: DeltaReadError.outOfOrderPage,
            surfaced: false
        )
        XCTAssertTrue(line.message.hasSuffix(" surfaced=false delta=outOfOrderPage"), line.message)
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

    /// #992 F2: the binding carries its own production identity, so a test can
    /// tell the real emitter from a substituted capture or a no-op — the exact
    /// mutation that killed the old bare-closure default while everything
    /// stayed green.
    @MainActor
    func testProductionSinkReportsItselfAndStubsDoNot() {
        XCTAssertTrue(
            PersistedFailureSink.production.isProduction,
            "the shipped default must identify as the production binding"
        )
        var captured: [PersistedFailureLine] = []
        let stub = PersistedFailureSink { captured.append($0) }
        XCTAssertFalse(stub.isProduction, "a test capture must never claim production")
        let silent = PersistedFailureSink { _ in }
        XCTAssertFalse(silent.isProduction, "a no-op must never claim production")

        let line = PersistedFailureLog.line(
            channel: .syncReplayFailure,
            operation: "probe",
            error: URLError(.timedOut),
            surfaced: false
        )
        stub(line)
        XCTAssertEqual(captured.map(\.operation), ["probe"])
    }

    /// #992 round 2: the production path's EMISSION must be observable. The
    /// round-2 review's M2 mutation (`.production`'s emitter replaced by
    /// `{ _ in }` while `isProduction` stays `true`) satisfied both earlier
    /// witnesses; this one drives the production binding itself and asserts
    /// the line reached the emitter's audit — a dead emitter cannot satisfy it.
    @MainActor
    func testProductionSinkEmissionReachesTheAuditRing() {
        let before = PersistedFailureLog.emissionCount()
        let line = PersistedFailureLog.line(
            channel: .syncReplayFailure,
            operation: "production-emit-witness",
            error: URLError(.timedOut),
            surfaced: false
        )

        PersistedFailureSink.production(line)

        XCTAssertEqual(
            PersistedFailureLog.emissionCount(),
            before + 1,
            "the production binding must reach `PersistedFailureLog.emit`; an emitter that stays silent while reporting isProduction=true (M2) must fail here"
        )
        XCTAssertTrue(
            PersistedFailureLog.recentEmissions().contains(where: {
                $0.operation == "production-emit-witness"
            }),
            "the emitted line must be visible in the emission audit"
        )
    }
}
