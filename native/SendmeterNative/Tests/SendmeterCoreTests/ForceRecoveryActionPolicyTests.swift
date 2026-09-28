import Foundation
import XCTest
@testable import SendmeterCore

/// #1004's new acceptance criterion: the two disabled conditions must never be
/// simultaneously satisfiable. A held pull must always have exactly one working
/// action — save it or discard it — regardless of any session-active state, and
/// a failed save must fall back to offering discard.
final class ForceRecoveryActionPolicyTests: XCTestCase {
    /// The pre-#1004 disable condition, verbatim from the Force card at base
    /// `43c7cc5` (`ForceView.swift:2849`, `:2855`, `:2867`, `:2873`):
    /// `.disabled(savingSummary || guidedSessionActive)`.
    ///
    /// It is kept here as the comparator the policy must not reproduce — a
    /// test that only checked "some button is enabled" could pass on a policy
    /// that re-introduced it in a different spelling.
    private func legacyDisablesRecovery(saving: Bool, sessionActive: Bool) -> Bool {
        saving || sessionActive
    }

    private func state(
        hasUnsavedRecording: Bool,
        saving: Bool,
        sessionActive: Bool,
        saveFailed: Bool
    ) -> ForceRecoveryControlsState {
        ForceRecoveryControlsState(
            hasUnsavedRecording: hasUnsavedRecording,
            saving: saving,
            sessionActive: sessionActive,
            saveFailed: saveFailed
        )
    }

    /// Exhaustive over the four inputs: a held pull with no save in flight
    /// always keeps at least one action, and the card's existence tracks the
    /// held pull rather than the session state.
    func testAHeldPullNeverLosesEveryActionInAnyCombination() {
        for hasUnsavedRecording in [false, true] {
            for saving in [false, true] {
                for sessionActive in [false, true] {
                    for saveFailed in [false, true] {
                        let state = state(
                            hasUnsavedRecording: hasUnsavedRecording,
                            saving: saving,
                            sessionActive: sessionActive,
                            saveFailed: saveFailed
                        )
                        let controls = ForceRecoveryActionPolicy.controls(state: state)
                        let label = "held=\(hasUnsavedRecording) saving=\(saving) session=\(sessionActive) saveFailed=\(saveFailed)"

                        XCTAssertEqual(
                            controls.showsRecoveryCard,
                            hasUnsavedRecording,
                            "\(label): the recovery card belongs to the held pull"
                        )
                        XCTAssertFalse(
                            controls.canSave && !hasUnsavedRecording,
                            "\(label): nothing to save without a held pull"
                        )
                        XCTAssertFalse(
                            controls.canDiscard && !hasUnsavedRecording,
                            "\(label): nothing to discard without a held pull"
                        )
                        if hasUnsavedRecording && !saving {
                            XCTAssertTrue(
                                controls.hasWorkingRecoveryAction,
                                "\(label): a held pull with no save in flight must keep a working action"
                            )
                        }
                    }
                }
            }
        }
    }

    /// The deadlock cell itself: a re-established session-active state on top
    /// of a held pull. The OLD condition disabled Save and Discard here while
    /// `hasUnsavedRecording` disabled Start.
    func testThePreFixConditionIsTheDeadlockThePolicyMustNotReproduce() {
        let deadlockState = state(
            hasUnsavedRecording: true,
            saving: false,
            sessionActive: true,
            saveFailed: false
        )

        XCTAssertTrue(
            legacyDisablesRecovery(
                saving: deadlockState.saving,
                sessionActive: deadlockState.sessionActive
            ),
            "fixture: the pre-fix condition greys both recovery buttons"
        )

        let controls = ForceRecoveryActionPolicy.controls(state: deadlockState)

        XCTAssertTrue(controls.canSave)
        XCTAssertTrue(controls.canDiscard)
        XCTAssertTrue(
            controls.hasWorkingRecoveryAction,
            "a session-active state must never take the only way out of a held pull"
        )
    }

    /// `sessionActive` is carried as an input only so this pin can prove it is
    /// inert: flipping it alone changes nothing.
    func testSessionActiveIsInertAcrossTheWholeMatrix() {
        for hasUnsavedRecording in [false, true] {
            for saving in [false, true] {
                for saveFailed in [false, true] {
                    let inactive = ForceRecoveryActionPolicy.controls(
                        state: state(
                            hasUnsavedRecording: hasUnsavedRecording,
                            saving: saving,
                            sessionActive: false,
                            saveFailed: saveFailed
                        )
                    )
                    let active = ForceRecoveryActionPolicy.controls(
                        state: state(
                            hasUnsavedRecording: hasUnsavedRecording,
                            saving: saving,
                            sessionActive: true,
                            saveFailed: saveFailed
                        )
                    )
                    XCTAssertEqual(
                        inactive,
                        active,
                        "held=\(hasUnsavedRecording) saving=\(saving) saveFailed=\(saveFailed)"
                    )
                }
            }
        }
    }

    /// A failed save leaves the pull held, so the fallback the user is OFFERED
    /// is discard — visibly, and with what it costs stated.
    func testAFailedSaveFallsBackToOfferingDiscard() {
        let controls = ForceRecoveryActionPolicy.controls(
            state: state(
                hasUnsavedRecording: true,
                saving: false,
                sessionActive: true,
                saveFailed: true
            )
        )

        XCTAssertTrue(controls.canDiscard)
        XCTAssertTrue(controls.offersDiscardFallback)
        XCTAssertFalse(
            ForceRecoveryActionPolicy.discardFallbackNotice.isEmpty,
            "the fallback must say what it costs"
        )
    }

    /// While a save is in flight there is nothing to offer — but a save that
    /// has NOT happened yet (or failed) must never present the spinner state.
    func testSavingInFlightIsTheOnlyStateWithBothActionsUnavailable() {
        let saving = ForceRecoveryActionPolicy.controls(
            state: state(
                hasUnsavedRecording: true,
                saving: true,
                sessionActive: false,
                saveFailed: false
            )
        )
        XCTAssertFalse(saving.hasWorkingRecoveryAction)
        XCTAssertFalse(saving.offersDiscardFallback)

        let failed = ForceRecoveryActionPolicy.controls(
            state: state(
                hasUnsavedRecording: true,
                saving: false,
                sessionActive: false,
                saveFailed: true
            )
        )
        XCTAssertTrue(failed.hasWorkingRecoveryAction)
    }
}
