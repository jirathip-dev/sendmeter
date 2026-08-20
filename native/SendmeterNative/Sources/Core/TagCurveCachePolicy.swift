import Foundation

/// A request stamp for an asynchronous tag-curve fit.
///
/// `AccountScopedFetch` protects account ownership; `generation` protects the
/// current recording snapshot within that account. Both checks are required:
/// a fit started before a recording save or refresh must not repopulate the
/// cache after the inputs have changed, even when the account is unchanged.
public struct TagCurveCacheRequest: Equatable, Sendable {
    public let accountFetch: AccountScopedFetch
    public let generation: UInt64

    public init(accountFetch: AccountScopedFetch, generation: UInt64) {
        self.accountFetch = accountFetch
        self.generation = generation
    }

    public func canApply(
        to currentUserID: UUID?,
        accountEpoch: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch)
            && generation == currentGeneration
    }
}
