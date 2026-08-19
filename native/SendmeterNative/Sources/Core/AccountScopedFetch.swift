import Foundation

/// Identity captured before an account-scoped async fetch. A completion must
/// check this against the live account immediately before publishing its
/// result; a fetch that resumes after an account switch is stale.
public struct AccountScopedFetch: Equatable, Sendable {
    public let accountUserID: UUID

    public init(accountUserID: UUID) {
        self.accountUserID = accountUserID
    }

    public func canApply(to currentUserID: UUID?) -> Bool {
        currentUserID == accountUserID
    }

    /// Run one synchronous publication only while the live account still
    /// matches the account captured before the async work. Callers must pass
    /// the result here immediately after the awaited operation returns; the
    /// closure contains no suspension point, so a stale completion cannot
    /// publish any part of its result.
    @discardableResult
    public func publishIfCurrent(
        to currentUserID: UUID?,
        _ publication: () -> Void
    ) -> Bool {
        guard canApply(to: currentUserID) else { return false }
        publication()
        return true
    }
}
