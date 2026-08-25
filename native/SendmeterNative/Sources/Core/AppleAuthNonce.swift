import CryptoKit
import Foundation

/// Sign in with Apple nonce handling — mirrors `src/lib/appleAuth.ts`:
/// Apple echoes the SHA-256 hash of the nonce we hand it into the identity
/// token's `nonce` claim, and Supabase re-hashes the RAW nonce we pass to
/// `signInWithIdToken` and compares. The generator is injectable so tests
/// are deterministic (seeded) and the exchange never depends on a UUID.
public protocol AppleNonceGenerating: Sendable {
    func makeRawNonce() -> String
}

public struct UUIDAppleNonceGenerator: AppleNonceGenerating {
    public init() {}
    public func makeRawNonce() -> String { UUID().uuidString }
}

public enum AppleAuthNonce {
    /// The RP ID the Apple auth request must carry — same bundle-id as the
    /// Capacitor app so a user's Apple identity is shared between targets.
    public static let clientID = "com.jirathip.sendlog"

    public static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The one flow: generate a raw nonce, return it alongside its hash —
    /// the raw value goes to Supabase, the hash to Apple.
    public static func flow(generator: AppleNonceGenerating) -> (raw: String, hashed: String) {
        let raw = generator.makeRawNonce()
        return (raw, sha256Hex(raw))
    }
}
