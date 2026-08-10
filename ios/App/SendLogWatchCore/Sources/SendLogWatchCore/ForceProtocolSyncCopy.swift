import Foundation

/// Watch-facing copy for a `ForceProtocolCatalog` refresh failure (#536).
///
/// The picker must never render `error.localizedDescription` — real observed
/// text included `JWT expired`, an implementation detail, not something a
/// climber can act on. This turns a `BackendFailureReason` into the exact
/// recovery message, and separately into a `Presentation` whose `title`
/// carries the cache claim ("Showing saved protocols") and whose `message`
/// carries only the recovery action — matching the issue's proposed UX
/// (`**Showing saved protocols**` / `Open Sendmeter on iPhone to refresh.` /
/// `Retry`) instead of saying the same thing twice in one banner (#536
/// review finding 2). The caller is responsible for keeping the original
/// technical error in `Logger` only.
public enum ForceProtocolSyncCopy {
    /// `title` + `message` for a `.cached`/`.failed` catalog banner.
    public struct Presentation: Sendable, Equatable {
        public let title: String
        public let message: String

        public init(title: String, message: String) {
            self.title = title
            self.message = message
        }
    }

    /// `hasUsableRows` must reflect actual saved rows (e.g.
    /// `!myProtocols.isEmpty`) — NOT merely that a cache write has ever
    /// happened. An empty catalog is a legitimately persisted cache (a user
    /// with zero saved presets), so a title claiming "showing saved
    /// protocols" would be false in that case (#536 review finding 1).
    public static func presentation(
        for reason: BackendFailureReason,
        hasUsableRows: Bool
    ) -> Presentation {
        Presentation(
            title: hasUsableRows ? "Showing saved protocols" : "No saved protocols yet",
            message: message(for: reason)
        )
    }

    /// The recovery action alone — no cache claim, so pairing this with any
    /// title never repeats itself.
    public static func message(for reason: BackendFailureReason) -> String {
        switch reason {
        case .authExpired:
            return "Open Sendmeter on iPhone to refresh."
        case .unreachable:
            return "Connect to iPhone to refresh."
        case .unknown:
            return "Couldn\u{2019}t refresh right now."
        }
    }
}
