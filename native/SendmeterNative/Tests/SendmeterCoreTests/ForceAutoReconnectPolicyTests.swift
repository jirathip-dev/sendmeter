@testable import SendmeterCore
import XCTest

/// #1021 (rollout #1028 slice 2): the auto-reconnect decision. Each rule has
/// its own test so a mutation of one rule fails exactly one test.
final class ForceAutoReconnectPolicyTests: XCTestCase {
    private func decide(
        _ trigger: ForceAutoReconnectTrigger = .enteredForce,
        device: ForceBarDevice = .disconnected,
        known: Bool = true,
        userDisconnected: Bool = false,
        session: Bool = false,
        forceTab: Bool = true
    ) -> Bool {
        ForceAutoReconnectPolicy.shouldReconnect(
            ForceAutoReconnectInput(
                trigger: trigger,
                device: device,
                hasKnownProgressor: known,
                userDisconnected: userDisconnected,
                sessionActive: session,
                forceTabSelected: forceTab
            )
        )
    }

    /// Rule 1: entering Force or foregrounding on Force reconnects the last
    /// Progressor when the link is down.
    func testReconnectsOnEnteringForceAndOnForeground() {
        XCTAssertTrue(decide(.enteredForce, device: .disconnected))
        XCTAssertTrue(decide(.enteredForce, device: .interrupted))
        XCTAssertTrue(decide(.foreground, device: .disconnected))
        XCTAssertTrue(decide(.foreground, device: .interrupted))
    }

    /// Rule 2: never after the user's own Disconnect.
    func testDoesNotReconnectAfterAUserDisconnect() {
        for trigger in [ForceAutoReconnectTrigger.enteredForce, .foreground] {
            XCTAssertFalse(decide(trigger, userDisconnected: true), "\(trigger)")
            XCTAssertFalse(decide(trigger, device: .interrupted, userDisconnected: true), "\(trigger)")
        }
    }

    /// Rule 3: never mid-session (guided protocol, hands-free arm, live pull).
    func testDoesNotReconnectMidSession() {
        for trigger in [ForceAutoReconnectTrigger.enteredForce, .foreground] {
            XCTAssertFalse(decide(trigger, session: true), "\(trigger)")
            XCTAssertFalse(decide(trigger, device: .interrupted, session: true), "\(trigger)")
        }
    }

    /// Nothing to reconnect to, or nothing to do.
    func testNeedsAKnownProgressorAndADownLink() {
        XCTAssertFalse(decide(known: false))
        for device in [ForceBarDevice.bluetoothOff, .connecting, .connected, .measuring] {
            XCTAssertFalse(decide(device: device), "\(device)")
        }
    }

    /// Foreground only reconnects when Force is the visible tab.
    func testForegroundOnAnotherTabDoesNotReconnect() {
        XCTAssertFalse(decide(.foreground, forceTab: false))
    }

    func testKnownProgressorStoreRoundTrips() throws {
        let suite = "ForceAutoReconnectPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KnownProgressorStore(defaults: defaults)
        XCTAssertNil(store.identifier)
        let id = UUID()
        store.remember(id)
        XCTAssertEqual(KnownProgressorStore(defaults: defaults).identifier, id, "persists across instances")
        defaults.set("not-a-uuid", forKey: KnownProgressorStore.defaultsKey)
        XCTAssertNil(store.identifier, "a corrupt value reads as no known Progressor")
    }
}
