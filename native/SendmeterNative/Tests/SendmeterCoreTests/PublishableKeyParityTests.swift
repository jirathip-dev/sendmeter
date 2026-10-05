import Foundation
import XCTest

/// #1007: the phone target and the Watch companion authenticate against the
/// same hosted Supabase project, but the publishable key reaches them through
/// different mechanisms — a compiled Swift constant on the phone, a bundled
/// plist value on the Watch — and nothing but this test tied the two committed
/// values together. A rotation that updated one file and missed the other used
/// to be invisible; now it fails here, at the lowest layer both files share,
/// which `just core` reaches on every run.
///
/// It also pins the Watch's simulator-only branch to the Supabase CLI's fixed
/// local-development publishable key (`defaultPublishableKey` in
/// `pkg/config/apikeys.go`, shipped with local publishable/secret-key support
/// in supabase/cli#4167, merged 2025-09-17; a local `supabase start` prints it
/// as `Publishable key:`). That branch talks to the **local** stack at
/// 127.0.0.1:54321, so its literal must follow the CLI's constant and never
/// silently drift from it — and the hosted project's key must never follow
/// this one.
final class PublishableKeyParityTests: XCTestCase {
    /// The Supabase CLI's fixed local-development publishable key constant.
    /// Shared by every local stack and intentionally public (RLS is the
    /// security boundary); against a hosted endpoint it is rejected (401).
    /// NOT a hosted-project credential. If Supabase ever changes this
    /// constant, move the Watch literal and this value together.
    ///
    /// `.gitleaks.toml` allowlists this exact assignment form — if this line's
    /// shape changes, the matching entry there must move with it or the secret
    /// scan starts reporting it.
    private static let localDevPublishableKey = "sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH"

    func testPhoneAndWatchCommittedPublishableKeysMatch() throws {
        let phone = try source("Sources/Data/SupabaseService.swift")
        let watch = try source("../../ios/App/SendLogWatch Watch App/Resources/SupabaseConfig.plist")
        let phoneKeyCapture = try firstCapture(of: #"public static let publishableKey\s*=\s*"([^"]+)""#, in: phone)
        let phoneKey = try XCTUnwrap(
            phoneKeyCapture,
            "SupabaseConfiguration.publishableKey is missing from the phone SupabaseService.swift"
        )
        let watchKeyCapture = try firstCapture(of: #"<key>SUPABASE_ANON_KEY</key>\s*<string>([^<]+)</string>"#, in: watch)
        let watchKey = try XCTUnwrap(
            watchKeyCapture,
            "SUPABASE_ANON_KEY is missing from the Watch SupabaseConfig.plist"
        )
        XCTAssertTrue(phoneKey.hasPrefix("sb_publishable_"), "phone key does not look like a publishable key: \(phoneKey)")
        XCTAssertTrue(watchKey.hasPrefix("sb_publishable_"), "Watch key does not look like a publishable key: \(watchKey)")
        XCTAssertNotEqual(
            phoneKey, Self.localDevPublishableKey,
            "The shipped key must be the hosted project's key, never the local stack's"
        )
        XCTAssertEqual(
            phoneKey, watchKey,
            "The phone and the Watch app must ship the same hosted publishable key (#1007): phone=\(phoneKey) watch=\(watchKey)"
        )
    }

    func testWatchSimulatorBranchUsesTheLocalStackKey() throws {
        let watch = try source("../../ios/App/SendLogWatch Watch App/Services/SupabaseService.swift")
        let simulatorBranchCapture = try firstCapture(
            of: #"#if DEBUG && targetEnvironment\(simulator\)([\s\S]*?)#else"#,
            in: watch
        )
        let simulatorBranch = try XCTUnwrap(
            simulatorBranchCapture,
            "the Watch SupabaseService no longer has a simulator-only client branch to pin"
        )
        XCTAssertTrue(
            simulatorBranch.contains(#"URL(string: "http://127.0.0.1:54321")!"#),
            "the Watch simulator branch must point at the local Supabase stack"
        )
        let simulatorKeyCapture = try firstCapture(of: #"supabaseKey:\s*"([^"]+)""#, in: simulatorBranch)
        let simulatorKey = try XCTUnwrap(
            simulatorKeyCapture,
            "the Watch simulator branch has no supabaseKey literal"
        )
        XCTAssertEqual(
            simulatorKey, Self.localDevPublishableKey,
            "The Watch simulator branch must use the Supabase CLI's fixed local-development publishable key (#1007); got \(simulatorKey)"
        )
    }

    func testPhoneAndWatchBundledURLsMatch() throws {
        let phone = try source("Sources/Data/SupabaseService.swift")
        let watch = try source("../../ios/App/SendLogWatch Watch App/Resources/SupabaseConfig.plist")
        let phoneURLCapture = try firstCapture(of: #"projectURL\s*=\s*URL\(string:\s*"([^"]+)"\)"#, in: phone)
        let phoneURL = try XCTUnwrap(
            phoneURLCapture,
            "SupabaseConfiguration.projectURL is missing from the phone SupabaseService.swift"
        )
        let watchURLCapture = try firstCapture(of: #"<key>SUPABASE_URL</key>\s*<string>([^<]+)</string>"#, in: watch)
        let watchURL = try XCTUnwrap(
            watchURLCapture,
            "SUPABASE_URL is missing from the Watch SupabaseConfig.plist"
        )
        XCTAssertEqual(phoneURL, watchURL, "the phone and the Watch app must point at the same Supabase project")
    }

    /// Reads a repo file relative to this test file's package root
    /// (`native/SendmeterNative`), the same wiring-test convention as
    /// `SplashPresentationWiringTests`.
    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func firstCapture(of pattern: String, in text: String) throws -> String? {
        let regex = try NSRegularExpression(pattern: pattern)
        let haystack = text as NSString
        guard
            let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: haystack.length)),
            match.numberOfRanges > 1
        else { return nil }
        return haystack.substring(with: match.range(at: 1))
    }
}
