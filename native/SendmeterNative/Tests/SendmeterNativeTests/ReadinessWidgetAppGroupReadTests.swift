import Foundation
import SendLogHealthCore
import XCTest
@testable import Sendmeter

/// #964 round 2 / #991 — the App Group read qualification.
///
/// The device capture's only app-specific failure was Apple's defaults
/// machinery reading `group.com.jirathip.sendlog` on 4/4 cold launches, ~80 ms
/// after process start, and #991 re-derived the ordering: the failing read is
/// our own `ReadinessWidgetStore.appGroupStore` use on the launch chain
/// (`resetAccountState` → `ReadinessWidgetBridge.reset`), where
/// `UserDefaults(suiteName:)` registers AnyUser suite domains that a
/// containerized process may not read, so cfprefsd refuses the source and the
/// read detaches from cfprefsd. These tests run in the real app process and
/// measure what the (now explicit CurrentUser `CFPreferences`) read does:
///
/// * the read returns the stored payload (save → load round-trips through the
///   real App Group container, and a second store instance sees the same
///   bytes),
/// * `clear()` → `load()` is nil, so the read reflects the container rather
///   than a cached value,
/// * the app's own publication path (`ReadinessWidgetBridge.publish`) lands in
///   that same container,
/// * and the failure mode is a NIL READ, never a throw: a suite with nothing
///   stored simply reads as nil. There is no thrown error anywhere on this
///   path for a banner to catch.
///
/// A simulator cannot exercise the device's containerized-preferences gate
/// (there is no App Group container here — `containerURL(forSecurityApplicationGroupIdentifier:)`
/// returns nil while the group domain still round-trips as an ordinary
/// suite), so the detached-cfprefsd symptom itself is owner-gated in
/// `docs/evidence/issue-991/`.
final class ReadinessWidgetAppGroupReadTests: XCTestCase {
    private let userID = UUID()

    private func snapshot(epoch: UInt64) -> ReadinessWidgetSnapshot {
        ReadinessWidgetSnapshot(
            accountUserID: userID,
            accountEpoch: epoch,
            day: "2026-09-21",
            capturedAt: Date(timeIntervalSince1970: 1_789_000_000),
            readiness: 68,
            readinessZone: "maintain",
            readinessComputedAt: Date(timeIntervalSince1970: 1_788_999_000),
            acute: 110,
            chronic: 100,
            acwr: 1.1,
            phaseID: "capacity",
            phaseName: "Capacity",
            phaseColorHex: "#5B5FC7",
            phaseWeek: 2,
            phaseDay: 4
        )
    }

    func testAppGroupReadReturnsTheStoredPayload() throws {
        let store = try XCTUnwrap(
            ReadinessWidgetStore.appGroupStore,
            "the app process must be able to open the App Group store"
        )
        let seeded = snapshot(epoch: 7)

        store.save(seeded)
        XCTAssertEqual(
            store.load(),
            seeded,
            "the App Group read must return the stored payload"
        )

        // The widget process's view: a second store over the same suite.
        let reader = try XCTUnwrap(ReadinessWidgetStore.appGroupStore)
        XCTAssertEqual(
            reader.load(),
            seeded,
            "a second reader of the App Group sees the same payload"
        )

        store.clear()
        XCTAssertNil(
            store.load(),
            "the read reflects the container's content, not a cached value"
        )
        XCTAssertNil(reader.load())
    }

    func testAppGroupPublicationPathLandsInTheReadableContainer() throws {
        let store = try XCTUnwrap(ReadinessWidgetStore.appGroupStore)
        store.clear()
        defer { store.clear() }

        let scope = NativeAccountScope(userID: userID, epoch: 12)
        let published = snapshot(epoch: 12)
        ReadinessWidgetBridge.publish(published, for: scope)

        XCTAssertEqual(
            try XCTUnwrap(ReadinessWidgetStore.appGroupStore).load(),
            published,
            "the app's launch/foreground publication must be readable back from the App Group"
        )

        ReadinessWidgetBridge.clear()
        XCTAssertNil(ReadinessWidgetStore.appGroupStore.load())
    }

    func testAppGroupReadOfAnUnavailableSuiteIsANilReadNotAnError() throws {
        // A different app group: this process holds no entitlement for it —
        // the shape of an unavailable or detached container.
        let foreignSuite = "group.com.jirathip.sendlog.unentitled.\(UUID().uuidString)"
        let foreignDefaults = try XCTUnwrap(UserDefaults(suiteName: foreignSuite))
        defer { foreignDefaults.removePersistentDomain(forName: foreignSuite) }
        let foreignStore = ReadinessWidgetStore(defaults: foreignDefaults)
        let seeded = snapshot(epoch: 11)

        foreignStore.save(seeded)
        XCTAssertEqual(
            foreignStore.load(),
            seeded,
            "an unentitled suite still round-trips inside the process — no throw"
        )
        let appGroup = try XCTUnwrap(ReadinessWidgetStore.appGroupStore)
        XCTAssertNotEqual(
            appGroup.load(),
            seeded,
            "an unentitled suite must not share storage with the App Group"
        )

        // A suite with nothing stored reads as nil. That nil IS the failure
        // mode: `load()` is non-throwing by signature, so a container the app
        // cannot reach degrades to "no snapshot" — a silent no-publish, not an
        // error that could reach `AppModel.surface(_:)` and the banner.
        let emptySuite = "group.com.jirathip.sendlog.empty.\(UUID().uuidString)"
        let emptyDefaults = try XCTUnwrap(UserDefaults(suiteName: emptySuite))
        defer { emptyDefaults.removePersistentDomain(forName: emptySuite) }
        XCTAssertNil(ReadinessWidgetStore(defaults: emptyDefaults).load())
    }

    func testAppGroupPayloadLivesInTheCurrentUserDomainTheStoreReads() throws {
        // #991: the store reads and writes the App Group domain through
        // CFPreferences with an explicit CurrentUser — the only user axis a
        // sandboxed process may hold for a container. Failure mode this
        // guards: the payload ends up somewhere that read cannot see it
        // (per-process storage, a different container, the refused AnyUser
        // axis), which would show as "no data yet" in the widget while the
        // app believes it published.
        let store = ReadinessWidgetStore.appGroupStore
        let seeded = snapshot(epoch: 21)
        defer { store.clear() }

        store.save(seeded)
        let stored = try XCTUnwrap(
            CFPreferencesCopyValue(
                ReadinessWidgetStore.snapshotKey as CFString,
                ReadinessWidgetStore.appGroup as CFString,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            ) as? Data
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ReadinessWidgetSnapshot.self, from: stored),
            seeded
        )
        XCTAssertEqual(store.load(), seeded)

        store.clear()
        XCTAssertNil(
            CFPreferencesCopyValue(
                ReadinessWidgetStore.snapshotKey as CFString,
                ReadinessWidgetStore.appGroup as CFString,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
        )
    }
}
