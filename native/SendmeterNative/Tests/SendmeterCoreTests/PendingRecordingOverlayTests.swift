import XCTest
@testable import SendmeterCore

final class PendingRecordingOverlayTests: XCTestCase {
    private let accountA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let accountB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    private func recording(id: String) -> TindeqRecording {
        TindeqRecording(
            id: UUID(uuidString: id)!,
            recordedAt: Date(timeIntervalSince1970: 1_000),
            durationMilliseconds: 10_000,
            peakKilograms: 20,
            averageKilograms: 15,
            sampleCount: 2,
            note: "",
            tag: "Crimp",
            side: .unspecified,
            groupID: nil
        )
    }

    func testRestoreReadForAccountAIsRejectedAfterSwitchToAccountB() {
        var overlay = PendingRecordingOverlay()
        let existingB = recording(id: "00000000-0000-0000-0000-0000000000B1")
        let restoredA = recording(id: "00000000-0000-0000-0000-0000000000A1")
        overlay.insert(existingB, accountUserID: accountB)

        let applied = overlay.applyRestored(
            [PendingRecordingOverlay.Entry(accountUserID: accountA, recording: restoredA)],
            capturedBy: AccountScopedFetch(accountUserID: accountA),
            currentUserID: accountB
        )

        XCTAssertFalse(applied)
        XCTAssertTrue(overlay.merged(remote: [], accountUserID: accountA).isEmpty)
        XCTAssertEqual(overlay.merged(remote: [], accountUserID: accountB).map(\.id), [existingB.id])
    }

    func testRestoreReadForTheCurrentAccountIsAccepted() {
        var overlay = PendingRecordingOverlay()
        let restoredA = recording(id: "00000000-0000-0000-0000-0000000000A2")

        let applied = overlay.applyRestored(
            [PendingRecordingOverlay.Entry(accountUserID: accountA, recording: restoredA)],
            capturedBy: AccountScopedFetch(accountUserID: accountA),
            currentUserID: accountA
        )

        XCTAssertTrue(applied)
        XCTAssertEqual(overlay.merged(remote: [], accountUserID: accountA).map(\.id), [restoredA.id])
    }

    func testMergeIncludesOnlyPendingRowsOwnedByTheCurrentAccount() {
        var overlay = PendingRecordingOverlay()
        let pendingA = recording(id: "00000000-0000-0000-0000-0000000000A3")
        let pendingB = recording(id: "00000000-0000-0000-0000-0000000000B3")
        let remoteA = recording(id: "00000000-0000-0000-0000-0000000000A4")
        let duplicatePendingA = recording(id: remoteA.id.uuidString)
        overlay.insert(pendingA, accountUserID: accountA)
        overlay.insert(pendingB, accountUserID: accountB)
        overlay.insert(duplicatePendingA, accountUserID: accountA)

        let merged = overlay.merged(remote: [remoteA], accountUserID: accountA)

        XCTAssertEqual(merged.map(\.id), [remoteA.id, pendingA.id])
    }
}
