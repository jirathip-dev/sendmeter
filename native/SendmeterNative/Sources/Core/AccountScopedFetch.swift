import Foundation

/// Identity captured before an account-scoped async fetch. A completion must
/// check this against the live account and lifecycle epoch immediately before
/// publishing its result; a fetch that resumes after an account switch is
/// stale, even if the same user later signs back in.
public struct AccountScopedFetch: Equatable, Sendable {
    public let accountUserID: UUID
    public let accountEpoch: UInt64

    public init(accountUserID: UUID, accountEpoch: UInt64) {
        self.accountUserID = accountUserID
        self.accountEpoch = accountEpoch
    }

    public func canApply(to currentUserID: UUID?, accountEpoch: UInt64) -> Bool {
        currentUserID == accountUserID && accountEpoch == self.accountEpoch
    }

    /// Run one synchronous publication only while the live account and epoch
    /// still match the values captured before the async work. Callers must
    /// pass the result here immediately after the awaited operation returns;
    /// the closure contains no suspension point, so a stale completion cannot
    /// publish any part of its result.
    @discardableResult
    public func publishIfCurrent(
        to currentUserID: UUID?,
        accountEpoch: UInt64,
        _ publication: () -> Void
    ) -> Bool {
        guard canApply(to: currentUserID, accountEpoch: accountEpoch) else { return false }
        publication()
        return true
    }
}

/// Ownership for a completion that may control an account-scoped UI flag.
/// The account snapshot prevents an old account's completion from finishing a
/// later account, while the token prevents an older same-account completion
/// from finishing a newer request.
public struct AccountScopedCompletion: Equatable, Sendable {
    public let fetch: AccountScopedFetch
    public let token: UUID

    public init(fetch: AccountScopedFetch, token: UUID = UUID()) {
        self.fetch = fetch
        self.token = token
    }

    public func owns(
        currentUserID: UUID?,
        accountEpoch: UInt64,
        activeOwner: AccountScopedCompletion?
    ) -> Bool {
        fetch.canApply(to: currentUserID, accountEpoch: accountEpoch)
            && activeOwner == self
    }
}
