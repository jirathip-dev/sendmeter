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
}
