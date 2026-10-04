import Foundation

/// The suite-backed App Group accessor for platforms without CoreFoundation.
///
/// #991 fix rounds 1–2: `ReadinessWidgetAppGroupDefaults` needs the full
/// Apple CoreFoundation (`CFPreferencesCopyValue` and friends); a Linux build
/// ships only a CoreFoundation subset (no CFString, no CFPreferences), so
/// `canImport(CoreFoundation)` is true there and is NOT a usable guard. The
/// `package-tests` CI job builds this module inside a `swift:6.3` container
/// through the watch package; `ReadinessWidgetStore.appGroupStore` therefore
/// selects this accessor on every non-Apple target, where the
/// `os(macOS) || os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)` target
/// guard is false.
///
/// It preserves the store contract exactly: the same App Group domain and
/// key, save → load round-trips, and a domain that holds nothing — or a
/// suite that could not be created at all — reads as `nil`, with writes
/// turned into no-ops there. Never a crash, never a fabricated value. There
/// is no containerized-preferences refusal to avoid on these platforms (no
/// cfprefsd, no App Group containers), and the Apple app path never selects
/// this accessor.
///
/// Compiled on every platform (not `#if`-gated) so the fallback protocol
/// behaviour is exercised by the host tests instead of only assumed for
/// Linux.
public struct ReadinessWidgetFallbackDefaults: ReadinessWidgetDefaults {
    private let defaults: UserDefaults?

    public init(appGroup: String) {
        self.init(defaults: UserDefaults(suiteName: appGroup))
    }

    /// The seat a suite that could not be created degrades into: nil reads,
    /// no-op writes.
    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    public func data(forKey defaultName: String) -> Data? {
        defaults?.data(forKey: defaultName)
    }

    public func set(_ value: Any?, forKey defaultName: String) {
        defaults?.set(value, forKey: defaultName)
    }

    public func removeObject(forKey defaultName: String) {
        defaults?.removeObject(forKey: defaultName)
    }
}
