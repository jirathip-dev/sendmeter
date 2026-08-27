import Foundation

/// #842: the provenance of a failure that wants a user-facing surface.
///
/// The same network failure is a different thing for a first load than for a
/// refresh whose last-good snapshot is already on screen. The refresh path
/// classifies before it decides whether to escalate to the global banner.
public enum ErrorSurfaceSource: Equatable, Sendable {
    /// A load or action the user initiated (cold-start bootstrap, sign-in,
    /// retry button, pull-to-refresh). Failures keep the full banner.
    case userInitiated
    /// An automatic refresh (foreground lifecycle, realtime convergence,
    /// mutation follow-up). The user did not ask for it.
    case background
}

/// #842: the `surface()` classification matrix.
///
/// A background/partial refresh failure must not escalate to the global
/// "Couldn't reach Sendmeter" banner while a last-good dataset is already
/// visible: the copy claims total unreachability, but only the refresh
/// failed. The banner is reserved for user-initiated loads (where the user
/// needs the retry affordance) and for background failures with NO last-good
/// data (a cold-start-style blackout, where the honest aid still applies).
/// Suppressed failures keep their non-banner side effects (auth recovery) and
/// the last-good data itself is never blanked.
public struct ErrorSurfacePolicy: Equatable, Sendable {
    public init() {}

    /// The classification matrix, pinned by `ErrorSurfacePolicyTests`:
    ///   userInitiated + any data state          → surface
    ///   background    + last-good data present  → suppress
    ///   background    + no last-good data       → surface
    public func shouldSurface(
        source: ErrorSurfaceSource,
        hasLastGoodData: Bool
    ) -> Bool {
        switch source {
        case .userInitiated:
            return true
        case .background:
            return !hasLastGoodData
        }
    }
}
