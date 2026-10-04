import XCTest
@testable import SendmeterCore

/// #1004 (session-lock layer): the Force surface's orphaned-lock wiring.
///
/// The app target is not part of the host SwiftPM package, so these source
/// invariants pin the wiring the hosted Xcode compile gate cannot assert on
/// its own: the lock's owner is attributed through the Core policy, the
/// release renders exactly on the orphaned owner, and the release action is
/// restricted to ended sessions and touches no data.
final class ForceLockOrphanWiringTests: XCTestCase {
    func testTheForceSurfaceAttributesTheGuidedLockThroughThePolicy() {
        let force = code(source("Sources/Features/Force/ForceView.swift"))
        let forceView = exactType(force, startingWith: "struct ForceView: View")
        let owner = exactBlock(force, startingWith: "private var guidedLockOwner: ForceGuidedLockOwner", missingMessage: "property")
        let orphaned = exactBlock(force, startingWith: "private var guidedLockOrphaned: Bool", missingMessage: "property")
        let lock = exactBlock(force, startingWith: "private var recordingContextLocked: Bool", missingMessage: "property")
        let normalizedOwner = normalizeWhitespace(owner)

        XCTAssertTrue(normalizedOwner.contains("ForceLockOrphanPolicy.owner("))
        XCTAssertTrue(normalizedOwner.contains("ForceGuidedLockReadState("))
        // The read is the surface's OWN state — the same three facts the
        // policy doc names, with no stored owner identifier anywhere.
        XCTAssertTrue(normalizedOwner.contains("sessionPresent: guidedSessionIsActive"))
        XCTAssertTrue(normalizedOwner.contains("sessionEnded: guidedSession?.isEnded == true"))
        XCTAssertTrue(normalizedOwner.contains("launchInFlight: guidedLaunch.inFlight"))

        XCTAssertTrue(
            normalizeWhitespace(orphaned).contains("ForceLockOrphanPolicy.requiresRelease(guidedLockOwner)"),
            "the orphaned flag must come from the policy, not from a second spelling of the condition"
        )
        // The lock itself is unchanged: it still locks on the session object
        // (that is exactly why an ENDED session can hold the surface).
        XCTAssertTrue(normalizeWhitespace(lock).contains("guidedSessionActive: guidedControlsLocked"))
        XCTAssertTrue(forceView.contains("private var guidedSessionIsActive: Bool"))
        XCTAssertTrue(normalizeWhitespace(forceView).contains("guidedSessionIsActive || guidedLaunch.inFlight"))
    }

    /// The pair that makes the orphan recoverable: the resume card still
    /// hides for an ended session, and the release card renders on the
    /// policy's orphan condition — the same condition, read the same way.
    func testTheReleaseAffordanceRendersExactlyOnTheOrphanedOwner() {
        let force = code(source("Sources/Features/Force/ForceView.swift"))
        let forceView = exactType(force, startingWith: "struct ForceView: View")
        let forceBody = exactFunction(forceView, startingWith: "var body: some View {")

        XCTAssertTrue(
            forceBody.contains("if let guidedSession, !guidedSession.isEnded {"),
            "fixture: the resume card hides once the session has ended"
        )
        XCTAssertTrue(forceBody.contains("if guidedLockOrphaned {"))

        let releaseRow = region(
            forceBody,
            from: "if guidedLockOrphaned {",
            to: "recordingContextCard"
        )
        XCTAssertTrue(releaseRow.contains("GuidedSessionReleaseCard {"))
        XCTAssertTrue(releaseRow.contains("releaseFinishedGuidedSession()"))

        let card = exactType(force, startingWith: "struct GuidedSessionReleaseCard: View")
        XCTAssertTrue(card.contains("ForceLockOrphanPolicy.releaseHeading"))
        XCTAssertTrue(card.contains("ForceLockOrphanPolicy.releaseNotice"))
        XCTAssertTrue(card.contains("ForceLockOrphanPolicy.releaseTitle"))
        XCTAssertTrue(card.contains("ForceLockOrphanPolicy.releaseHint"))
        XCTAssertTrue(card.contains("accessibilityIdentifier(\"guided-session-release\")"))
    }

    /// The data-safety fence, as a source invariant: the release may only
    /// join an ENDED session's terminal flight and clear the view state that
    /// held the screen. No queue, cache, cursor or device-summary call may
    /// appear in it.
    func testTheReleaseOnlyTouchesAnEndedSessionAndNoDataAtAll() {
        let force = code(source("Sources/Features/Force/ForceView.swift"))
        let release = exactFunction(force, startingWith: "private func releaseFinishedGuidedSession()")
        let normalized = normalizeWhitespace(release)

        XCTAssertTrue(normalized.contains("guard let session = guidedSession, session.isEnded else { return }"))
        XCTAssertTrue(normalized.contains("await session.teardown()"))
        XCTAssertTrue(normalized.contains("guard session.isEnded, guidedSession?.id == session.id else { return }"))
        XCTAssertTrue(normalized.contains("clearGuidedSession(session)"))

        for forbidden in [
            "clearCompletedRecording",
            "clearInterruptedRecording",
            "saveForceSummary",
            "queue",
            "Queue",
            "LocalCache",
            "cache",
            "cursor",
            "discard",
        ] {
            XCTAssertFalse(
                release.contains(forbidden),
                "the release must not reach \(forbidden) — it may only join the settled flight"
            )
        }
    }

    /// One implementation: the lifecycle teardown (account change, real tab
    /// disappearance) and the user's release both go through the same
    /// function, so the two paths cannot drift.
    func testTheLifecycleTeardownSharesTheOneReleaseImplementation() {
        let force = code(source("Sources/Features/Force/ForceView.swift"))
        let teardown = exactFunction(force, startingWith: "private func teardownGuidedSessionIfNeeded()")
        let endedBranch = region(
            teardown,
            from: "if session.isEnded {",
            to: "Task {"
        )

        XCTAssertTrue(
            normalizedSquashed(endedBranch).contains("releaseFinishedGuidedSession()"),
            "the ended branch must run the same release the user's card runs"
        )
    }

    /// The device row must not claim a resume/end that no longer exists: the
    /// orphaned lock names the release it can see.
    func testTheDeviceRowNamesTheReleaseWhenTheLockIsOrphaned() {
        let force = code(source("Sources/Features/Force/ForceView.swift"))
        let deviceCard = exactType(force, startingWith: "private struct ForceDeviceCard: View")
        let forceView = exactType(force, startingWith: "struct ForceView: View")

        XCTAssertTrue(deviceCard.contains("let guidedLockOrphaned: Bool"))
        XCTAssertTrue(deviceCard.contains("ForceLockOrphanPolicy.orphanedLockLabel"))
        XCTAssertTrue(deviceCard.contains("ForceLockOrphanPolicy.activeLockLabel"))
        XCTAssertTrue(
            normalizeWhitespace(forceView).contains("guidedLockOrphaned: guidedLockOrphaned,"),
            "the card's orphan readout must be the view's own policy read"
        )
        XCTAssertFalse(
            force.contains("\"Guided protocol active — resume or end it above\""),
            "the inline label moved into the policy copy"
        )
    }

    private func source(_ relativePath: String) -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileURL = packageRoot.appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            XCTFail("Could not read source invariant file: \(fileURL.path): \(error)")
            return ""
        }
    }

    private func code(_ source: String) -> String {
        let withoutBlockComments = source.replacingOccurrences(
            of: #"(?s)/\*.*?\*/"#,
            with: "",
            options: .regularExpression
        )
        return withoutBlockComments
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? "" }
            .joined(separator: "\n")
    }

    private func exactFunction(_ source: String, startingWith marker: String) -> String {
        exactBlock(source, startingWith: marker, missingMessage: "function")
    }

    private func exactType(_ source: String, startingWith marker: String) -> String {
        exactBlock(source, startingWith: marker, missingMessage: "type")
    }

    private func exactBlock(
        _ source: String,
        startingWith marker: String,
        missingMessage: String
    ) -> String {
        guard let startRange = source.range(of: marker),
              let openBrace = source.range(
                  of: "{",
                  range: startRange.upperBound..<source.endIndex
              )
        else {
            XCTFail("Missing source invariant \(missingMessage): \(marker)")
            return ""
        }

        var depth = 0
        var cursor = openBrace.lowerBound
        while cursor < source.endIndex {
            switch source[cursor] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[startRange.lowerBound...cursor])
                }
            default: break
            }
            cursor = source.index(after: cursor)
        }

        XCTFail("Unclosed source invariant \(missingMessage): \(marker)")
        return ""
    }

    private func region(_ source: String, from start: String, to end: String) -> String {
        guard let startRange = source.range(of: start),
              let endRange = source.range(
                  of: end,
                  range: startRange.upperBound..<source.endIndex
              )
        else {
            XCTFail("Missing source invariant region: \(start) → \(end)")
            return ""
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private func normalizeWhitespace(_ source: String) -> String {
        source
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedSquashed(_ source: String) -> String {
        source
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
    }
}
