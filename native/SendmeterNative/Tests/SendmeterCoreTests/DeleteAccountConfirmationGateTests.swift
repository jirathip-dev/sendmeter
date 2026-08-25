import XCTest
@testable import SendmeterCore

/// Pins the #759 gate: the destructive action can only be armed after the
/// warning step has been explicitly advanced past and the exact phrase has
/// been typed. A stray touch, close-but-wrong text, or re-entering from a
/// warning surface must never satisfy it.
final class DeleteAccountConfirmationGateTests: XCTestCase {
    func testStartsAtWarningAndCannotConfirm() {
        let gate = DeleteAccountConfirmationGate()

        XCTAssertEqual(gate.stage, .warning)
        XCTAssertFalse(gate.canConfirm)
    }

    func testAdvancingOpensTheConfirmationStepButDoesNotArmDelete() {
        var gate = DeleteAccountConfirmationGate()

        gate.advanceFromWarning()

        XCTAssertEqual(gate.stage, .confirmation)
        XCTAssertFalse(gate.canConfirm)
    }

    func testOnlyTheExactPhraseArmsTheDestructiveAction() {
        var gate = DeleteAccountConfirmationGate(stage: .confirmation)

        for value in ["", "delete", "Delete", "DELETE ", " DELETE", "DELETES", "DELETE\n"] {
            gate.updateEntry(value)
            XCTAssertFalse(gate.canConfirm, "unexpectedly accepted \(value.debugDescription)")
        }

        gate.updateEntry(DeleteAccountConfirmationGate.phrase)
        XCTAssertTrue(gate.canConfirm)
    }

    func testEntriesMadeBeforeTheWarningStepAreIgnored() {
        var gate = DeleteAccountConfirmationGate()

        gate.updateEntry(DeleteAccountConfirmationGate.phrase)

        XCTAssertEqual(gate.entry, "")
        XCTAssertFalse(gate.canConfirm)
    }

    func testGoingBackAlwaysClearsThePhrase() {
        var gate = DeleteAccountConfirmationGate(
            stage: .confirmation,
            entry: DeleteAccountConfirmationGate.phrase
        )
        XCTAssertTrue(gate.canConfirm)

        gate.backToWarning()

        XCTAssertEqual(gate.stage, .warning)
        XCTAssertEqual(gate.entry, "")
        XCTAssertFalse(gate.canConfirm)
    }

    func testAdvancingCannotSkipPastAnAlreadyOpenConfirmation() {
        var gate = DeleteAccountConfirmationGate(stage: .confirmation)

        gate.advanceFromWarning()

        XCTAssertEqual(gate.stage, .confirmation)
    }
}
