import XCTest
@testable import SendmeterCore

final class AppleAuthNonceTests: XCTestCase {
    /// The SHA-256 of "abc" — the standard NIST test vector. Pins the hash
    /// implementation (lowercase hex, CryptoKit) against the web's
    /// `crypto.subtle.digest("SHA-256", ...)` byte-for-byte.
    func testSha256HexKnownVector() {
        XCTAssertEqual(
            AppleAuthNonce.sha256Hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testSha256HexEmptyString() {
        XCTAssertEqual(
            AppleAuthNonce.sha256Hex(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    /// A seeded generator makes the whole flow deterministic — the raw nonce
    /// is what Supabase receives, the hash is what Apple echoes back.
    func testFlowIsDeterministicWithSeededGenerator() {
        struct Seeded: AppleNonceGenerating {
            func makeRawNonce() -> String { "seed-1234" }
        }
        let first = AppleAuthNonce.flow(generator: Seeded())
        let second = AppleAuthNonce.flow(generator: Seeded())
        XCTAssertEqual(first.raw, "seed-1234")
        XCTAssertEqual(first.hashed, AppleAuthNonce.sha256Hex("seed-1234"))
        XCTAssertEqual(first.raw, second.raw)
        XCTAssertEqual(first.hashed, second.hashed)
    }

    func testFlowHashedNeverEqualsRaw() {
        let flow = AppleAuthNonce.flow(generator: UUIDAppleNonceGenerator())
        XCTAssertFalse(flow.hashed.isEmpty)
        XCTAssertFalse(flow.raw.isEmpty)
        XCTAssertNotEqual(flow.hashed, flow.raw)
        XCTAssertEqual(flow.hashed, AppleAuthNonce.sha256Hex(flow.raw))
    }

    func testClientIDMatchesWebAndCapacitorApp() {
        XCTAssertEqual(AppleAuthNonce.clientID, "com.jirathip.sendlog")
    }
}
