import XCTest
@testable import SendLogWatchCore

final class ErrorTextTests: XCTestCase {
    func testUserFacingMessagesArePlainAndActionable() {
        let expectations: [(ErrorText.Class, String)] = [
            (.authExpired, "Signed out — open the iPhone app to reconnect, then try again."),
            (.unreachable, "No connection — try again in a moment."),
            (.saveFailed, "Couldn't save. Try again."),
            (.workoutStartFailed, "Couldn't start the workout. Check Health access on your iPhone, then try again."),
            (.workoutFailed, "The workout stopped unexpectedly. Check Health access on your iPhone, then try again."),
            (.workoutHealthSaveFailed, "Apple Health couldn't save this workout. Check Health access on your iPhone, then try again."),
            (.readinessUnavailable, "Couldn't reach your iPhone. Try again when it's nearby."),
            (.progressorUnavailable, "Bluetooth is unavailable. Turn it on and try connecting again."),
            (.progressorUnsupported, "This watch can't connect to a Progressor over Bluetooth."),
            (.progressorNotFound, "Couldn't find the Progressor. Make sure it's on and nearby, then try again."),
            (.progressorConnectFailed, "Couldn't connect to the Progressor. Make sure it's on and nearby, then try again."),
            (.progressorDisconnected, "The Progressor disconnected. Reconnect it and try again."),
            (.progressorUnrecognized, "The Progressor wasn't recognised. Turn it off and on, then try connecting again."),
            (.forceSessionSaveFailed, "Force session wasn't saved. Your pulls may still be saved individually; create a session for them on your phone."),
            (.repNotSaved, "Rep wasn't saved. Try pulling again."),
            (.repNotSavedOnWatch, "Rep couldn't be saved on the watch. It won't appear in this workout."),
            (.recordingNotSavedOnWatch, "Recording couldn't be saved on the watch. It won't appear in this workout.")
        ]
        for (classification, expected) in expectations {
            XCTAssertEqual(ErrorText.message(for: classification), expected)
        }
    }

    func testFriendlyNeverLeaksRawDescription() {
        let error = NSError(
            domain: "PostgRESTError",
            code: 23514,
            userInfo: [NSLocalizedDescriptionKey: "Status Code: 500 Body: {\"message\":\"internal error\"}"]
        )
        let message = ErrorText.friendly(error)
        XCTAssertFalse(message.localizedCaseInsensitiveContains("Status Code"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("500"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("PostgRESTError"))
        XCTAssertEqual(message, "Something went wrong. Try again.")
    }

    func testFailureMessageVerdictMatchesCopy() {
        XCTAssertTrue(ErrorText.isFailureMessage(ErrorText.message(for: .repNotSaved)))
        XCTAssertTrue(ErrorText.isFailureMessage(ErrorText.message(for: .repNotSavedOnWatch)))
        XCTAssertTrue(ErrorText.isFailureMessage(ErrorText.message(for: .recordingNotSavedOnWatch)))
        XCTAssertFalse(ErrorText.isFailureMessage("Saved · 38.2 kg · Crimp edge"))
        XCTAssertFalse(ErrorText.isFailureMessage("Saving…"))
    }
}
