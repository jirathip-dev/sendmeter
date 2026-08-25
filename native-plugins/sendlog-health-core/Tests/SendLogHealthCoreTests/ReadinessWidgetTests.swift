import Foundation
import XCTest
@testable import SendLogHealthCore

final class ReadinessWidgetTests: XCTestCase {
    private let userID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private func snapshot(
        day: String = "2026-08-26",
        readiness: Int? = 82,
        zone: String? = "push",
        acute: Double? = 210,
        chronic: Double? = 180,
        acwr: Double? = 1.17
    ) -> ReadinessWidgetSnapshot {
        ReadinessWidgetSnapshot(
            accountUserID: userID,
            accountEpoch: 7,
            day: day,
            capturedAt: Date(timeIntervalSince1970: 1_756_000_000),
            readiness: readiness,
            readinessZone: zone,
            readinessComputedAt: readiness.map { _ in Date(timeIntervalSince1970: 1_755_999_000) },
            acute: acute,
            chronic: chronic,
            acwr: acwr,
            phaseID: "capacity",
            phaseName: "Capacity",
            phaseColorHex: "#2E96F0",
            phaseWeek: 2,
            phaseDay: 8
        )
    }

    func testRoundTripPreservesOwnerAndOptionalData() throws {
        let original = snapshot()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReadinessWidgetSnapshot.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.accountUserID, userID)
        XCTAssertEqual(decoded.accountEpoch, 7)
        XCTAssertEqual(decoded.readiness, 82)
        XCTAssertEqual(decoded.acwr, 1.17)
        XCTAssertTrue(decoded.isValid)
    }

    func testStoreRoundTripAndClear() throws {
        let suiteName = "ReadinessWidgetTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ReadinessWidgetStore(defaults: defaults)
        let original = snapshot()

        store.save(original)
        XCTAssertEqual(store.load(), original)

        store.clear()
        XCTAssertNil(store.load())
    }

    func testNoDataDoesNotBecomeZeroOrRetainAZone() {
        let noData = snapshot(
            readiness: nil,
            zone: "push",
            acute: 0,
            chronic: 0,
            acwr: nil
        )

        XCTAssertNil(noData.readiness)
        XCTAssertNil(noData.readinessZone)
        XCTAssertNil(noData.readinessComputedAt)
        XCTAssertNil(noData.acute)
        XCTAssertNil(noData.chronic)
        XCTAssertNil(noData.acwr)
        XCTAssertTrue(noData.isValid)
    }

    func testOnlyCurrentGregorianDayIsRenderable() {
        XCTAssertEqual(snapshot().freshness(on: "2026-08-26"), .current)
        XCTAssertEqual(snapshot(day: "2026-08-25").freshness(on: "2026-08-26"), .stale)
    }

    func testDecodedInvalidZoneAndPhaseAreRejected() throws {
        let data = try JSONEncoder().encode(snapshot())
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        object["readinessZone"] = "unknown"
        let invalidZone = try JSONSerialization.data(withJSONObject: object)
        let decodedZone = try JSONDecoder().decode(
            ReadinessWidgetSnapshot.self,
            from: invalidZone
        )
        XCTAssertFalse(decodedZone.isValid)

        object["readinessZone"] = "push"
        object["phaseName"] = "   "
        let invalidPhase = try JSONSerialization.data(withJSONObject: object)
        let decodedPhase = try JSONDecoder().decode(
            ReadinessWidgetSnapshot.self,
            from: invalidPhase
        )
        XCTAssertFalse(decodedPhase.isValid)

        object["phaseName"] = "Capacity"
        object["phaseColorHex"] = "\t"
        let invalidPhaseColor = try JSONSerialization.data(withJSONObject: object)
        let decodedPhaseColor = try JSONDecoder().decode(
            ReadinessWidgetSnapshot.self,
            from: invalidPhaseColor
        )
        XCTAssertFalse(decodedPhaseColor.isValid)
    }

    func testOwnershipAndResetPoliciesFenceAccountsAndEpochs() {
        let original = snapshot()
        XCTAssertTrue(
            ReadinessWidgetOwnershipPolicy.canPublish(
                original,
                currentUserID: userID,
                currentEpoch: 7
            )
        )
        XCTAssertFalse(
            ReadinessWidgetOwnershipPolicy.canPublish(
                original,
                currentUserID: UUID(),
                currentEpoch: 7
            )
        )
        XCTAssertFalse(
            ReadinessWidgetOwnershipPolicy.canPublish(
                original,
                currentUserID: userID,
                currentEpoch: 8
            )
        )
        XCTAssertTrue(
            ReadinessWidgetOwnershipPolicy.shouldClearOnReset(
                snapshotOwner: userID,
                currentUserID: UUID()
            )
        )
        XCTAssertFalse(
            ReadinessWidgetOwnershipPolicy.shouldClearOnReset(
                snapshotOwner: userID,
                currentUserID: userID
            )
        )
        XCTAssertTrue(
            ReadinessWidgetOwnershipPolicy.shouldClearOnReset(
                snapshotOwner: userID,
                currentUserID: nil
            )
        )
    }

    func testPartialOrImpossibleACWRIsDropped() {
        let partial = snapshot(acute: 100, chronic: nil, acwr: nil)
        let impossible = snapshot(acute: 100, chronic: 80, acwr: .infinity)

        XCTAssertNil(partial.acute)
        XCTAssertNil(partial.chronic)
        XCTAssertNil(partial.acwr)
        XCTAssertNil(impossible.acute)
        XCTAssertNil(impossible.chronic)
        XCTAssertNil(impossible.acwr)
    }

    func testPresentationThresholdsMatchDashboard() {
        XCTAssertEqual(ReadinessWidgetPresentation.readinessBand(39), .recover)
        XCTAssertEqual(ReadinessWidgetPresentation.readinessBand(40), .maintain)
        XCTAssertEqual(ReadinessWidgetPresentation.readinessBand(70), .maintain)
        XCTAssertEqual(ReadinessWidgetPresentation.readinessBand(71), .push)
        XCTAssertEqual(ReadinessWidgetPresentation.readinessBand(nil), .noData)

        XCTAssertEqual(ReadinessWidgetPresentation.acwrBand(nil), .noData)
        XCTAssertEqual(ReadinessWidgetPresentation.acwrBand(0.69), .underTraining)
        XCTAssertEqual(ReadinessWidgetPresentation.acwrBand(0.70), .low)
        XCTAssertEqual(ReadinessWidgetPresentation.acwrBand(0.80), .low)
        XCTAssertEqual(ReadinessWidgetPresentation.acwrBand(0.81), .optimal)
        XCTAssertEqual(ReadinessWidgetPresentation.acwrBand(1.30), .optimal)
        XCTAssertEqual(ReadinessWidgetPresentation.acwrBand(1.31), .caution)
        XCTAssertEqual(ReadinessWidgetPresentation.acwrBand(1.50), .caution)
        XCTAssertEqual(ReadinessWidgetPresentation.acwrBand(1.51), .danger)
    }

    func testTimelineReloadsAtTheNextGregorianLocalMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 7 * 3600)!
        let now = calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 26, hour: 16, minute: 30
        ))!
        let next = ReadinessWidgetTimelinePolicy.nextReloadDate(
            after: now,
            calendar: calendar
        )

        XCTAssertEqual(
            next,
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 27))!
        )
    }

    func testLocalDayStringForcesGregorianEvenWithABuddhistCalendar() {
        var calendar = Calendar(identifier: .buddhist)
        calendar.timeZone = TimeZone(secondsFromGMT: 7 * 3600)!
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let date = gregorian.date(from: DateComponents(
            year: 2026, month: 8, day: 26, hour: 16
        ))!

        XCTAssertEqual(
            ReadinessWidgetTimelinePolicy.localDayString(
                for: date,
                calendar: calendar
            ),
            "2026-08-26"
        )
    }

    func testWidgetTokensMatchNativeDashboardPalette() {
        XCTAssertEqual(ReadinessWidgetSemanticToken.health.lightHex, "#2E96F0")
        XCTAssertEqual(ReadinessWidgetSemanticToken.health.darkHex, "#4FB0FF")
        XCTAssertEqual(ReadinessWidgetSemanticToken.caution.lightHex, "#DDB13A")
        XCTAssertEqual(ReadinessWidgetSemanticToken.alert.lightHex, "#E5743A")
    }
}
