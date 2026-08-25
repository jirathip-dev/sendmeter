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

public enum PurgeGenerationResponse {
    /// RLS yields zero rows before the first hard purge. That is a valid
    /// generation-zero response, distinct from a transport/schema failure;
    /// callers handle the latter by passing nil to the convergence policy.
    public static func generation(from rows: [PurgeGenerationRow]) -> Int64 {
        rows.first?.generation ?? 0
    }
}
