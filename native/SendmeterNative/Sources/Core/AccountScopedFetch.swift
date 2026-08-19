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
}
