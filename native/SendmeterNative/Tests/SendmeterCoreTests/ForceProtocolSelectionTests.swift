import XCTest
@testable import SendmeterCore

/// #710: the RECORDING CONTEXT selector's mutually-exclusive Free /
/// Suggested / Saved state machine. Asserted directly so the single-armed
/// invariant is pinned by the pure reducer, not only exercised by the view.
final class ForceProtocolSelectionTests: XCTestCase {
    private let id = UUID()

    // (a) Selecting Free clears Suggested + Saved.
    func testSelectingFreeClearsSuggested() {
        XCTAssertEqual(
            ForceProtocolPicker.next(current: .suggestedZone(.power), tapped: .free),
            .free
        )
        XCTAssertEqual(
            ForceProtocolPicker.next(current: .suggestedMaintenance(.warmup), tapped: .free),
            .free
        )
    }

    func testSelectingFreeClearsSaved() {
        XCTAssertEqual(
            ForceProtocolPicker.next(current: .savedPreset(id), tapped: .free),
            .free
        )
    }

    // (b) Selecting Suggested clears Free + Saved.
    func testSelectingSuggestedClearsFree() {
        XCTAssertEqual(
            ForceProtocolPicker.next(current: .free, tapped: .suggestedZone(.power)),
            .suggestedZone(.power)
        )
        XCTAssertEqual(
            ForceProtocolPicker.next(current: .free, tapped: .suggestedMaintenance(.prehab)),
            .suggestedMaintenance(.prehab)
        )
    }

    func testSelectingSuggestedClearsSaved() {
        XCTAssertEqual(
            ForceProtocolPicker.next(current: .savedPreset(id), tapped: .suggestedZone(.endurance)),
            .suggestedZone(.endurance)
        )
        XCTAssertEqual(
            ForceProtocolPicker.next(current: .savedPreset(id), tapped: .suggestedMaintenance(.warmup)),
            .suggestedMaintenance(.warmup)
        )
    }

    // (c) Selecting Saved clears Free + Suggested.
    func testSelectingSavedClearsFree() {
        XCTAssertEqual(
            ForceProtocolPicker.next(current: .free, tapped: .savedPreset(id)),
            .savedPreset(id)
        )
    }

    func testSelectingSavedClearsSuggested() {
        XCTAssertEqual(
            ForceProtocolPicker.next(current: .suggestedZone(.strength), tapped: .savedPreset(id)),
            .savedPreset(id)
        )
        XCTAssertEqual(
            ForceProtocolPicker.next(current: .suggestedMaintenance(.warmup), tapped: .savedPreset(id)),
            .savedPreset(id)
        )
    }

    // (d) Tapping the active chip deselects back to Free.
    func testTappingActiveSuggestedDeselectsToFree() {
        XCTAssertEqual(
            ForceProtocolPicker.next(current: .suggestedZone(.power), tapped: .suggestedZone(.power)),
            .free
        )
        XCTAssertEqual(
            ForceProtocolPicker.next(current: .suggestedMaintenance(.prehab), tapped: .suggestedMaintenance(.prehab)),
            .free
        )
    }

    func testTappingActiveSavedDeselectsToFree() {
        XCTAssertEqual(
            ForceProtocolPicker.next(current: .savedPreset(id), tapped: .savedPreset(id)),
            .free
        )
    }

    // A different saved preset switches, not deselects.
    func testTappingDifferentSavedSwitches() {
        let other = UUID()
        XCTAssertEqual(
            ForceProtocolPicker.next(current: .savedPreset(id), tapped: .savedPreset(other)),
            .savedPreset(other)
        )
    }

    func testFreeIsIdempotent() {
        XCTAssertEqual(ForceProtocolPicker.next(current: .free, tapped: .free), .free)
    }

    // (e) #711: Movement is the same single-armed selector — selecting it
    // clears Free/Suggested/Saved, and any of those clears it back.
    func testSelectingMovementClearsFree() {
        XCTAssertEqual(
            ForceProtocolPicker.next(current: .free, tapped: .movement),
            .movement
        )
    }

    func testSelectingMovementClearsSuggestedAndSaved() {
        XCTAssertEqual(
            ForceProtocolPicker.next(current: .suggestedZone(.power), tapped: .movement),
            .movement
        )
        XCTAssertEqual(
            ForceProtocolPicker.next(current: .suggestedMaintenance(.warmup), tapped: .movement),
            .movement
        )
        XCTAssertEqual(
            ForceProtocolPicker.next(current: .savedPreset(id), tapped: .movement),
            .movement
        )
    }

    func testSelectingFreeOrSuggestedOrSavedClearsMovement() {
        XCTAssertEqual(
            ForceProtocolPicker.next(current: .movement, tapped: .free),
            .free
        )
        XCTAssertEqual(
            ForceProtocolPicker.next(current: .movement, tapped: .suggestedZone(.endurance)),
            .suggestedZone(.endurance)
        )
        XCTAssertEqual(
            ForceProtocolPicker.next(current: .movement, tapped: .suggestedMaintenance(.prehab)),
            .suggestedMaintenance(.prehab)
        )
        XCTAssertEqual(
            ForceProtocolPicker.next(current: .movement, tapped: .savedPreset(id)),
            .savedPreset(id)
        )
    }

    func testTappingActiveMovementDeselectsToFree() {
        XCTAssertEqual(
            ForceProtocolPicker.next(current: .movement, tapped: .movement),
            .free
        )
    }

    // (f) #711: ForceMeasurementMode is the presentation mapping of the armed
    // protocol's modality (web `forceSetup.ts`).
    func testMeasurementModeMapsFromProtocolMode() {
        XCTAssertEqual(ForceMeasurementMode(protocolMode: .hold), .static)
        XCTAssertEqual(ForceMeasurementMode(protocolMode: .reverseAction), .movement)
        XCTAssertEqual(ForceMeasurementMode.static.protocolMode, .hold)
        XCTAssertEqual(ForceMeasurementMode.movement.protocolMode, .reverseAction)
        XCTAssertEqual(ForceMeasurementMode.static.badgeLabel, "STATIC")
        XCTAssertEqual(ForceMeasurementMode.movement.badgeLabel, "MOVEMENT")
    }

    func testMovementSuggestionIsExposed() {
        XCTAssertEqual(ForceProtocolSelection.movement.suggested, .movement)
    }
}
