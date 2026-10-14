import Foundation

/// #1021 (rollout #1028 slice 2): when the Force tab may reconnect the last
/// Progressor on its own. Pure decision logic — AppModel builds the input
/// from the transport and session state and calls the transport only when
/// this says so.
public enum ForceAutoReconnectTrigger: Equatable, Sendable {
    /// The Force tab appeared.
    case enteredForce
    /// The app came to the foreground while the Force tab was selected.
    case foreground
}

public struct ForceAutoReconnectInput: Equatable, Sendable {
    public var trigger: ForceAutoReconnectTrigger
    /// The transport state, in the bar's terms.
    public var device: ForceBarDevice
    /// A Progressor has connected on this phone before (its identifier is
    /// remembered).
    public var hasKnownProgressor: Bool
    /// The user tapped Disconnect (or cancelled a connect) this launch and
    /// has not asked to connect since.
    public var userDisconnected: Bool
    /// A guided protocol, a hands-free arm or a live pull owns the device.
    public var sessionActive: Bool
    /// The Force tab is the selected tab (foreground trigger only).
    public var forceTabSelected: Bool

    public init(
        trigger: ForceAutoReconnectTrigger,
        device: ForceBarDevice,
        hasKnownProgressor: Bool,
        userDisconnected: Bool,
        sessionActive: Bool,
        forceTabSelected: Bool
    ) {
        self.trigger = trigger
        self.device = device
        self.hasKnownProgressor = hasKnownProgressor
        self.userDisconnected = userDisconnected
        self.sessionActive = sessionActive
        self.forceTabSelected = forceTabSelected
    }
}

public enum ForceAutoReconnectPolicy {
    public static func shouldReconnect(_ input: ForceAutoReconnectInput) -> Bool {
        // Never fight the user's own Disconnect.
        guard !input.userDisconnected else { return false }
        // Never mid-session: a guided protocol or hands-free loop owns the
        // device and its interrupted path.
        guard !input.sessionActive else { return false }
        guard input.hasKnownProgressor else { return false }
        if input.trigger == .foreground, !input.forceTabSelected { return false }
        switch input.device {
        case .disconnected, .interrupted:
            return true
        case .bluetoothOff, .connecting, .connected, .measuring:
            return false
        }
    }
}

/// #1021: the last connected Progressor's CoreBluetooth identifier, kept on
/// this phone only so the Force tab can reconnect to it directly.
public struct KnownProgressorStore {
    public static let defaultsKey = "sendmeter.native.tindeq.last-peripheral"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = KnownProgressorStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    public var identifier: UUID? {
        defaults.string(forKey: key).flatMap(UUID.init(uuidString:))
    }

    public func remember(_ identifier: UUID) {
        defaults.set(identifier.uuidString, forKey: key)
    }
}
