import XCTest
@testable import SendmeterCore

final class ManualForceFullscreenPresentationTests: XCTestCase {
    func testRegularStartOpensMeasuringViewportAndMinimizeKeepsItAlive() {
        var lifecycle = ManualForceFullscreenLifecycle()
        XCTAssertTrue(lifecycle.open(armed: false))
        XCTAssertEqual(lifecycle.phase, .measuring)
        XCTAssertTrue(lifecycle.keepsRecordingAliveWhenMinimized)
        XCTAssertFalse(lifecycle.canDismiss)
    }

    func testHandsFreeArmPromotesToMeasuringAndRearmsAfterAutomaticSave() {
        var lifecycle = ManualForceFullscreenLifecycle()
        XCTAssertTrue(lifecycle.open(armed: true))
        XCTAssertEqual(lifecycle.phase, .armed)
        XCTAssertTrue(lifecycle.beginRecording())
        XCTAssertEqual(lifecycle.phase, .measuring)
        XCTAssertTrue(lifecycle.rearm())
        XCTAssertEqual(lifecycle.phase, .armed)
    }

    func testManualSaveClaimsOnceAndLeavesFailedPullAvailableForRetry() {
        var lifecycle = ManualForceFullscreenLifecycle(phase: .measuring)
        XCTAssertTrue(lifecycle.requestSave())
        XCTAssertFalse(lifecycle.requestSave())
        XCTAssertEqual(lifecycle.phase, .saving)

        lifecycle.saveFailed()
        XCTAssertEqual(lifecycle.phase, .readyToSave)
        XCTAssertTrue(lifecycle.requestSave())
        lifecycle.saveSucceeded()
        XCTAssertEqual(lifecycle.phase, .saved)
        XCTAssertTrue(lifecycle.canDismiss)
    }

    func testAutomaticTransportStopLeavesCompletedPullReadyForExplicitSave() {
        var lifecycle = ManualForceFullscreenLifecycle(phase: .measuring)
        XCTAssertTrue(lifecycle.markReadyToSave())
        XCTAssertEqual(lifecycle.phase, .readyToSave)
        XCTAssertFalse(lifecycle.markReadyToSave())
    }

    func testHandsFreeSaveCanRearmViewportWithoutReopeningIt() {
        var lifecycle = ManualForceFullscreenLifecycle(phase: .measuring)
        XCTAssertTrue(lifecycle.requestSave())
        XCTAssertTrue(lifecycle.rearm())
        XCTAssertEqual(lifecycle.phase, .armed)
    }

    func testDisconnectIsTerminalForTheFullscreenOwner() {
        var lifecycle = ManualForceFullscreenLifecycle(phase: .measuring)
        lifecycle.interrupted()
        XCTAssertEqual(lifecycle.phase, .interrupted)
        XCTAssertFalse(lifecycle.keepsRecordingAliveWhenMinimized)
        XCTAssertTrue(lifecycle.canDismiss)
        XCTAssertFalse(lifecycle.requestSave())
    }

    func testPresentationUsesLockedContextAndElapsedPhaseCopy() {
        let measuring = ManualForceFullscreenPresentation.stage(
            phase: .measuring,
            exercise: "Half crimp",
            side: .left,
            elapsedSeconds: 65.2
        )
        XCTAssertEqual(measuring.label, "MEASURING")
        XCTAssertTrue(measuring.detail.contains("Half crimp · Left"))
        XCTAssertTrue(measuring.detail.contains("01:05"))

        let armed = ManualForceFullscreenPresentation.stage(
            phase: .armed,
            exercise: "Half crimp",
            side: .left,
            elapsedSeconds: 0
        )
        XCTAssertEqual(armed.label, "PULL TO START")
        XCTAssertTrue(armed.detail.contains("Hands-free"))
    }
}
