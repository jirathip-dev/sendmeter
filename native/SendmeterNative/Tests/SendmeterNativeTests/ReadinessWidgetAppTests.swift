import Foundation
import XCTest
@testable import Sendmeter
import SendLogHealthCore

/// App-module coverage for the contract/store link. The application target
/// owns the bridge and AppModel publication; these tests ensure its Xcode-only
/// module consumes the same validated App Group store as the extension.
final class ReadinessWidgetAppTests: XCTestCase {
    private let userID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func snapshot() -> ReadinessWidgetSnapshot {
        ReadinessWidgetSnapshot(
            accountUserID: userID,
            accountEpoch: 3,
            day: "2026-08-26",
            capturedAt: Date(timeIntervalSince1970: 1_756_000_001),
            readiness: 74,
            readinessZone: "push",
            readinessComputedAt: Date(timeIntervalSince1970: 1_756_000_000),
            acute: 120,
            chronic: 100,
            acwr: 1.2,
            phaseID: "capacity",
            phaseName: "Capacity",
            phaseColorHex: "#2E96F0",
            phaseWeek: 1,
            phaseDay: 3
        )
    }

    func testApplicationModuleStoreSaveLoadAndClear() throws {
        let suiteName = "ReadinessWidgetAppTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ReadinessWidgetStore(defaults: defaults)

        let original = snapshot()
        store.save(original)
        XCTAssertEqual(store.load(), original)
        store.clear()
        XCTAssertNil(store.load())
    }

    func testApplicationModuleStoreRejectsInvalidDecodedContract() throws {
        let suiteName = "ReadinessWidgetAppTests-invalid-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ReadinessWidgetStore(defaults: defaults)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(snapshot())
            ) as? [String: Any]
        )
        object["phaseID"] = ""
        defaults.set(
            try JSONSerialization.data(withJSONObject: object),
            forKey: ReadinessWidgetStore.snapshotKey
        )

        XCTAssertNil(store.load())
    }

    func testApplicationModuleUsesOwnerAndEpochFencingPolicy() {
        let valid = snapshot()
        XCTAssertTrue(
            ReadinessWidgetOwnershipPolicy.canPublish(
                valid,
                currentUserID: userID,
                currentEpoch: 3
            )
        )
        XCTAssertFalse(
            ReadinessWidgetOwnershipPolicy.canPublish(
                valid,
                currentUserID: userID,
                currentEpoch: 4
            )
        )
    }
}
