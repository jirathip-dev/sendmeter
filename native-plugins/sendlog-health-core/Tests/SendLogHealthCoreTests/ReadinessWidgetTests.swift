import Foundation
import XCTest
@testable import SendLogHealthCore

final class ReadinessWidgetTests: XCTestCase {
    private let userID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private func snapshot(
        day: String = "2026-08-26",
        capturedAt: Date = Date(timeIntervalSince1970: 1_756_000_000),
        readiness: Int? = 82,
        zone: String? = "push",
        acute: Double? = 210,
        chronic: Double? = 180,
        acwr: Double? = 1.17,
        phaseID: String? = "capacity",
        phaseName: String? = "Capacity",
        phaseColorHex: String? = "#2E96F0",
        phaseWeek: Int? = 2,
        phaseDay: Int? = 8
    ) -> ReadinessWidgetSnapshot {
        ReadinessWidgetSnapshot(
            accountUserID: userID,
            accountEpoch: 7,
            day: day,
            capturedAt: capturedAt,
            readiness: readiness,
            readinessZone: zone,
            readinessComputedAt: readiness.map { _ in Date(timeIntervalSince1970: 1_755_999_000) },
            acute: acute,
            chronic: chronic,
            acwr: acwr,
            phaseID: phaseID,
            phaseName: phaseName,
            phaseColorHex: phaseColorHex,
            phaseWeek: phaseWeek,
            phaseDay: phaseDay
        )
    }

    private func decodedSnapshot(
        mutating: (inout [String: Any]) -> Void
    ) throws -> ReadinessWidgetSnapshot {
        let data = try JSONEncoder().encode(snapshot())
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        mutating(&object)
        let mutatedData = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(ReadinessWidgetSnapshot.self, from: mutatedData)
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

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
    func testAppGroupDefaultsRoundTripThroughAnExplicitCurrentUserDomain() throws {
        // #991: the production App Group accessor reads and writes the domain
        // through an explicit CurrentUser CFPreferences access — the only user
        // axis a containerized process may hold. A test domain (never the real
        // App Group) exercises the same read/write/remove trio.
        let domain = "com.jirathip.sendlog.contract-test.\(UUID().uuidString)"
        let defaults = ReadinessWidgetAppGroupDefaults(appGroup: domain)
        let store = ReadinessWidgetStore(defaults: defaults)
        defer { defaults.removeObject(forKey: ReadinessWidgetStore.snapshotKey) }
        let original = snapshot()

        XCTAssertNil(store.load())

        store.save(original)
        XCTAssertEqual(store.load(), original)
        let stored = try XCTUnwrap(
            defaults.data(forKey: ReadinessWidgetStore.snapshotKey)
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ReadinessWidgetSnapshot.self, from: stored),
            original
        )

        store.clear()
        XCTAssertNil(store.load())
    }
#endif

    func testAppGroupStoreSelectsThePlatformAccessor() {
        // #991 fix round 2: prove the SELECTION on this host, not just the
        // source text. On an Apple build `appGroupStore` must carry the
        // CoreFoundation accessor; a non-Apple build (Linux) must carry the
        // fallback. (On Linux the os() guard also enforces this at compile
        // time; this test asserts the running platform's branch.)
        let store = ReadinessWidgetStore.appGroupStore
        XCTAssertFalse(store.defaults is UserDefaults)
        #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        XCTAssertTrue(store.defaults is ReadinessWidgetAppGroupDefaults)
        XCTAssertFalse(store.defaults is ReadinessWidgetFallbackDefaults)
        #else
        XCTAssertTrue(store.defaults is ReadinessWidgetFallbackDefaults)
        #endif
    }

    func testFallbackDefaultsPreserveReadWriteAndNilSemantics() throws {
        // #991 fix round 1: the non-CoreFoundation accessor Linux uses
        // (`ReadinessWidgetFallbackDefaults`) is injected through the same
        // protocol/store API, so the fallback is exercised here, not merely
        // compiled. Guards: an empty domain reads as nil (no crash, no
        // fabricated value), save -> load round-trips domain-wide (a second
        // store over the same domain sees the same bytes), and clear returns
        // the domain to nil.
        let domain = "com.jirathip.sendlog.fallback-test.\(UUID().uuidString)"
        let defaults = ReadinessWidgetFallbackDefaults(appGroup: domain)
        let store = ReadinessWidgetStore(defaults: defaults)
        defer {
            defaults.removeObject(forKey: ReadinessWidgetStore.snapshotKey)
            UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
        }
        let original = snapshot()

        XCTAssertNil(store.load())

        store.save(original)
        XCTAssertEqual(store.load(), original)
        XCTAssertEqual(
            ReadinessWidgetStore(
                defaults: ReadinessWidgetFallbackDefaults(appGroup: domain)
            ).load(),
            original
        )

        store.clear()
        XCTAssertNil(store.load())
    }

    func testFallbackDefaultsWithoutASuiteDegradeToNilReadsAndNoOpWrites() {
        // The missing-container seat: a suite that could not be created must
        // read as nil and swallow writes — never crash, never fabricate.
        let defaults = ReadinessWidgetFallbackDefaults(defaults: nil)
        let store = ReadinessWidgetStore(defaults: defaults)

        XCTAssertNil(defaults.data(forKey: ReadinessWidgetStore.snapshotKey))
        XCTAssertNil(store.load())

        store.save(snapshot())
        defaults.set(Data([0x01]), forKey: ReadinessWidgetStore.snapshotKey)
        defaults.removeObject(forKey: ReadinessWidgetStore.snapshotKey)
        store.clear()

        XCTAssertNil(defaults.data(forKey: ReadinessWidgetStore.snapshotKey))
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

    func testSnapshotInitializerNormalisesInvalidDisplayValues() {
        let scoreWithoutKnownZone = snapshot(zone: "unknown")
        XCTAssertEqual(scoreWithoutKnownZone.readiness, 82)
        XCTAssertNil(scoreWithoutKnownZone.readinessZone)
        XCTAssertNotNil(scoreWithoutKnownZone.readinessComputedAt)
        XCTAssertTrue(scoreWithoutKnownZone.isValid)

        for score in [-1, 101] {
            let invalid = snapshot(readiness: score)
            XCTAssertNil(invalid.readiness)
            XCTAssertNil(invalid.readinessZone)
            XCTAssertNil(invalid.readinessComputedAt)
        }

        let invalidPhase = snapshot(
            phaseID: " \n",
            phaseName: " ",
            phaseColorHex: "",
            phaseWeek: 0,
            phaseDay: -1
        )
        XCTAssertNil(invalidPhase.phaseID)
        XCTAssertNil(invalidPhase.phaseName)
        XCTAssertNil(invalidPhase.phaseColorHex)
        XCTAssertNil(invalidPhase.phaseWeek)
        XCTAssertNil(invalidPhase.phaseDay)

        let negativeLoad = snapshot(acute: -1, chronic: 180, acwr: 1.17)
        XCTAssertNil(negativeLoad.acute)
        XCTAssertNil(negativeLoad.chronic)
        XCTAssertNil(negativeLoad.acwr)
    }

    func testSnapshotAllowsOptionalPhaseContext() {
        let withoutPhase = snapshot(
            phaseID: nil,
            phaseName: nil,
            phaseColorHex: nil,
            phaseWeek: nil,
            phaseDay: nil
        )

        XCTAssertTrue(withoutPhase.isValid)
        XCTAssertNil(withoutPhase.phaseID)
        XCTAssertNil(withoutPhase.phaseName)
        XCTAssertNil(withoutPhase.phaseColorHex)
        XCTAssertNil(withoutPhase.phaseWeek)
        XCTAssertNil(withoutPhase.phaseDay)
    }

    func testDecodedValidationRejectsCorruptPayloads() throws {
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("old schema", { $0["schemaVersion"] = 0 }),
            ("empty day", { $0["day"] = "" }),
            ("out-of-range readiness", { $0["readiness"] = 101 }),
            ("unknown readiness zone", { $0["readinessZone"] = "unknown" }),
            ("zone without readiness", {
                $0["readiness"] = NSNull()
                $0["readinessZone"] = "push"
            }),
            ("blank phase id", { $0["phaseID"] = "\t" }),
            ("blank phase name", { $0["phaseName"] = " \n" }),
            ("blank phase color", { $0["phaseColorHex"] = "" }),
            ("non-positive phase week", { $0["phaseWeek"] = 0 }),
            ("non-positive phase day", { $0["phaseDay"] = 0 }),
            ("partial load", { $0["chronic"] = NSNull() }),
            ("negative load", { $0["acwr"] = -0.1 }),
        ]

        for (label, mutation) in mutations {
            let decoded = try decodedSnapshot(mutating: mutation)
            XCTAssertFalse(decoded.isValid, label)
            XCTAssertEqual(
                decoded.freshness(on: "2026-08-26"),
                .invalid,
                label
            )
        }

        let invalid = try decodedSnapshot { $0["phaseName"] = " " }
        XCTAssertNil(
            ReadinessWidgetTimelinePolicy.boundarySnapshot(
                from: invalid,
                at: Date(timeIntervalSince1970: 1_756_000_000)
            )
        )
    }

    func testStoreRejectsMalformedAndInvalidSnapshots() throws {
        let suiteName = "ReadinessWidgetInvalidStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ReadinessWidgetStore(defaults: defaults)

        defaults.set(Data("not-json".utf8), forKey: ReadinessWidgetStore.snapshotKey)
        XCTAssertNil(store.load())

        let valid = snapshot()
        store.save(valid)
        let invalid = try decodedSnapshot { $0["day"] = "" }
        store.save(invalid)
        XCTAssertEqual(store.load(), valid)
    }

    func testAppGroupStoreFactoryUsesTheSharedDomain() {
        // #991: the factory hands back a store over the App Group *domain*,
        // read through an explicit CurrentUser CFPreferences access, rather
        // than a `UserDefaults` suite whose AnyUser domains a containerized
        // process may not read.
        XCTAssertNotNil(ReadinessWidgetStore.appGroupStore)
        XCTAssertEqual(ReadinessWidgetStore.appGroup, "group.com.jirathip.sendlog")
        XCTAssertEqual(
            ReadinessWidgetStore.snapshotKey,
            "sendmeter.readiness-widget.snapshot"
        )
    }

    func testPresentationThresholdsMatchDashboard() {
        XCTAssertEqual(ReadinessWidgetPresentation.readinessBand(39), .recover)
        XCTAssertEqual(ReadinessWidgetPresentation.readinessBand(40), .maintain)
        XCTAssertEqual(ReadinessWidgetPresentation.readinessBand(70), .maintain)
        XCTAssertEqual(ReadinessWidgetPresentation.readinessBand(71), .push)
        XCTAssertEqual(ReadinessWidgetPresentation.readinessBand(nil), .noData)

        XCTAssertEqual(
            ReadinessWidgetPresentation.readinessBand(
                zone: "maintain",
                fallbackScore: 99
            ),
            .maintain
        )
        XCTAssertEqual(
            ReadinessWidgetPresentation.readinessBand(
                zone: "recover",
                fallbackScore: 99
            ),
            .recover
        )
        XCTAssertEqual(
            ReadinessWidgetPresentation.readinessBand(
                zone: "push",
                fallbackScore: 1
            ),
            .push
        )
        XCTAssertEqual(
            ReadinessWidgetPresentation.readinessBand(
                zone: nil,
                fallbackScore: 71
            ),
            .push
        )
        XCTAssertEqual(
            ReadinessWidgetPresentation.readinessBand(
                zone: "unknown",
                fallbackScore: 71
            ),
            .noData
        )

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

    func testPublicationPolicyIgnoresCaptureTimeButReloadsVisibleChanges() {
        let original = snapshot()
        let recaptured = snapshot(
            capturedAt: original.capturedAt.addingTimeInterval(60)
        )

        XCTAssertFalse(
            ReadinessWidgetPublicationPolicy.shouldReload(
                previous: original,
                next: recaptured
            )
        )
        XCTAssertTrue(
            ReadinessWidgetPublicationPolicy.shouldReload(
                previous: original,
                next: snapshot(acwr: 1.18)
            )
        )
        XCTAssertTrue(
            ReadinessWidgetPublicationPolicy.shouldReload(
                previous: nil,
                next: original
            )
        )
    }

    func testPublishedContentIdentityIncludesEveryRenderedPhaseField() {
        let original = snapshot()
        let changedSnapshots = [
            snapshot(phaseID: "strength"),
            snapshot(phaseName: "Strength"),
            snapshot(phaseColorHex: "#E5743A"),
            snapshot(phaseWeek: 3),
            snapshot(phaseDay: 9),
        ]

        for changed in changedSnapshots {
            XCTAssertFalse(original.matchesPublishedContent(of: changed))
        }
    }

    func testBoundarySnapshotDropsReadinessButPreservesNonDailyContext() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 7 * 3600)!
        let next = calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 27
        ))!

        let boundary = try XCTUnwrap(
            ReadinessWidgetTimelinePolicy.boundarySnapshot(
                from: snapshot(),
                at: next,
                calendar: calendar
            )
        )

        XCTAssertEqual(boundary.day, "2026-08-27")
        XCTAssertNil(boundary.readiness)
        XCTAssertNil(boundary.readinessZone)
        XCTAssertNil(boundary.readinessComputedAt)
        XCTAssertEqual(boundary.acute, 210)
        XCTAssertEqual(boundary.chronic, 180)
        XCTAssertEqual(boundary.acwr, 1.17)
        XCTAssertEqual(boundary.phaseName, "Capacity")
        XCTAssertEqual(boundary.phaseWeek, 2)
        XCTAssertEqual(boundary.phaseDay, 8)
        XCTAssertEqual(boundary.freshness(on: "2026-08-27"), .current)
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

    func testEveryWidgetBandMapsToItsSemanticToken() {
        let tokenColors: [
            (ReadinessWidgetSemanticToken, light: String, dark: String)
        ] = [
            (.focus, "#5B5FC7", "#9296EE"),
            (.health, "#2E96F0", "#4FB0FF"),
            (.load, "#7B83EB", "#9296EE"),
            (.optimal, "#2E96F0", "#4FB0FF"),
            (.caution, "#DDB13A", "#E8C24E"),
            (.alert, "#E5743A", "#F0864C"),
            (.reference, "#8E8E93", "#A9A9B0"),
        ]
        for (token, light, dark) in tokenColors {
            XCTAssertEqual(token.lightHex, light, token.rawValue)
            XCTAssertEqual(token.darkHex, dark, token.rawValue)
        }

        let readinessMappings: [
            (ReadinessWidgetReadinessBand, ReadinessWidgetSemanticToken)
        ] = [
            (.noData, .reference),
            (.recover, .alert),
            (.maintain, .caution),
            (.push, .optimal),
        ]
        for (band, token) in readinessMappings {
            XCTAssertEqual(band.semanticToken.rawValue, token.rawValue, band.rawValue)
        }

        let acwrMappings: [
            (ReadinessWidgetACWRBand, ReadinessWidgetSemanticToken)
        ] = [
            (.noData, .reference),
            (.underTraining, .focus),
            (.low, .focus),
            (.optimal, .optimal),
            (.caution, .caution),
            (.danger, .alert),
        ]
        for (band, token) in acwrMappings {
            XCTAssertEqual(band.semanticToken.rawValue, token.rawValue, band.rawValue)
        }
    }

    func testDefaultTimelineCalendarIsGregorianInTheCurrentTimeZone() {
        let calendar = ReadinessWidgetTimelinePolicy.localGregorianCalendar
        XCTAssertEqual(calendar.identifier, .gregorian)
        XCTAssertEqual(calendar.timeZone, TimeZone.current)

        let instant = Date(timeIntervalSince1970: 1_756_000_000)
        XCTAssertEqual(
            ReadinessWidgetTimelinePolicy.localDayString(for: instant),
            instant.dateString(in: calendar)
        )
    }
}
