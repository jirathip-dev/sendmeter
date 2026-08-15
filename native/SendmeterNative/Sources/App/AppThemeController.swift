import Foundation
import SendmeterCore
import SwiftUI

/// Appearance preference controller — web's `ThemeSection` parity (#631):
/// System/Light/Dark persisted to UserDefaults (`sendmeter.native.theme`)
/// and applied pre-paint via `preferredColorScheme` on the root view. The
/// storage + resolution logic lives in Core (`AppTheme`) so the round-trip
/// is unit-tested; this type is the thin observable wrapper.
@MainActor
public final class AppThemeController: ObservableObject {
    @Published public private(set) var choice: AppThemeChoice
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.choice = AppTheme.storedChoice(defaults: defaults)
    }

    public func setChoice(_ next: AppThemeChoice) {
        choice = next
        AppTheme.store(next, defaults: defaults)
    }

    /// The scheme to force for the current system appearance: an explicit
    /// choice wins, System follows the OS (the web's `resolvedTheme`).
    public func resolvedScheme(prefersDark: Bool) -> ColorScheme {
        AppTheme.resolved(choice: choice, prefersDark: prefersDark) == .dark ? .dark : .light
    }
}
