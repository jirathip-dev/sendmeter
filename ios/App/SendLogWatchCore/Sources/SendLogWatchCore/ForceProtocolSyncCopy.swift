import Foundation

/// Watch-facing copy for a `ForceProtocolCatalog` refresh failure (#536).
///
/// The picker must never render `error.localizedDescription` — real observed
/// text included `JWT expired`, an implementation detail, not something a
/// climber can act on. This turns a `BackendFailureReason` into the exact
/// recovery message, and separately into a `Presentation` whose `title`
/// carries the sync-outcome claim and whose `message` carries only the
/// recovery action — matching the issue's proposed UX
/// (`**Showing saved protocols**` / `Open Sendmeter on iPhone to refresh.` /
/// `Retry`) instead of saying the same thing twice in one banner (#536
/// review finding 2). The caller is responsible for keeping the original
/// technical error in `Logger` only.
///
/// `ForceProtocolCatalog.syncBannerTitle` is the one production caller of
/// `title(for:)`/`presentation(for:rows:)` — kept here, not re-declared in
/// the app target, so the rendered strings have exactly one source of truth
/// (#536 review round 2 finding B).
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

    /// What the banner's title is allowed to claim about the user's saved
    /// protocol count. `.cachedWithRows` / `.cachedEmpty` both mean a prior
    /// successful fetch is still on screen (this refresh merely failed to
    /// replace it) — the count claim in the title is genuinely known, either
    /// non-empty or legitimately zero. `.neverSynced` means no successful
    /// fetch has ever completed for this account, so nothing is actually
    /// known about the count: "we couldn't find out" must stay
    /// distinguishable from "you have none" (#536 review round 2 finding A —
    /// gating the title on row-count alone made every `.failed` banner claim
    /// "No saved protocols yet" even when the account genuinely has rows the
    /// watch just hasn't been able to confirm).
    public enum RowsState: Sendable, Equatable {
        case cachedWithRows
        case cachedEmpty
        case neverSynced
    }

    /// The title alone. `syncBannerTitle` calls this directly when it only
    /// needs the title (no failure reason is involved, e.g. deriving it from
    /// live catalog state for display).
    public static func title(for rows: RowsState) -> String {
        switch rows {
        case .cachedWithRows:
            return "Showing saved protocols"
        case .cachedEmpty:
            return "No saved protocols yet"
        case .neverSynced:
            return "Couldn\u{2019}t sync protocols"
        }
    }

    public static func presentation(
        for reason: BackendFailureReason,
        rows: RowsState
    ) -> Presentation {
        Presentation(title: title(for: rows), message: message(for: reason))
    }

    /// The recovery action alone — no cache/count claim, so pairing this
    /// with any title never repeats itself.
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
