import Foundation

/// The row shape returned by PostgREST for the per-account purge-generation
/// endpoint. Keeping this in the testable core lets the repository's empty
/// response behavior stay explicit instead of being hidden in an app-only
/// transport implementation.
public struct PurgeGenerationRow: Decodable, Equatable, Sendable {
    public let generation: Int64

    public init(generation: Int64) {
        self.generation = generation
    }
}

/// The response type is decoded by `PostgRESTClient.request`, not by a
/// repository-only JSON decoder. Its `Decodable` initializer accepts the
/// exact array shape emitted by PostgREST and collapses the RLS-empty result
/// to generation zero.
public struct PurgeGenerationResponse: Decodable, Equatable, Sendable {
    public let generation: Int64

    public init(generation: Int64) {
        self.generation = generation
    }

    public init(from decoder: Decoder) throws {
        let rows = try [PurgeGenerationRow](from: decoder)
        // RLS yields zero rows before the first hard purge. That is a valid
        // generation-zero response, distinct from a transport/schema
        // failure; callers handle the latter by passing nil to the
        // convergence policy.
        self.generation = rows.first?.generation ?? 0
    }
}
