import XCTest
import SendLogWatchCore

private func pairing(
    supported: Bool = true,
    activated: Bool = true,
    paired: Bool = true,
    appInstalled: Bool = true
) -> WatchPairing {
    WatchPairing(
        supported: supported, activated: activated,
        paired: paired, appInstalled: appInstalled
    )
}

private func id(_ version: String, _ build: String) -> BuildIdentity {
    guard let identity = BuildIdentity(version: version, build: build) else {
        preconditionFailure("fixture must be a valid identity")
    }
    return identity
}

final class BuildIdentityTests: XCTestCase {
    func testDisplayMatchesThePhoneBuildFormat() {
        // Same "1.4.0 (57)" shape the account sheet already renders for the
        // phone (#225) — the watch line has to read as its pair.
        XCTAssertEqual(id("1.4.0", "57").display, "1.4.0 (57)")
    }

    func testNilWhenNothingIsKnown() {
        XCTAssertNil(BuildIdentity(version: nil, build: nil))
        XCTAssertNil(BuildIdentity(version: "", build: "   "))
    }

    func testHalfKnownIdentityIsKept() {
        // A build with no marketing version is still evidence of which
        // install is on the wrist; losing it entirely would be worse.
        XCTAssertEqual(BuildIdentity(version: nil, build: "57")?.display, "? (57)")
        XCTAssertEqual(BuildIdentity(version: "1.4.0", build: nil)?.display, "1.4.0 (?)")
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(BuildIdentity(version: " 1.4.0 ", build: "\n57")?.display, "1.4.0 (57)")
    }

    func testReadsInfoDictionaryKeys() {
        let info: [String: Any] = [
            "CFBundleShortVersionString": "1.4.0",
            "CFBundleVersion": "57",
            "CFBundleName": "SendLogWatch",
        ]
        XCTAssertEqual(BuildIdentity(infoDictionary: info), id("1.4.0", "57"))
        XCTAssertNil(BuildIdentity(infoDictionary: [:]))
        XCTAssertNil(BuildIdentity(infoDictionary: nil))
    }

    func testBuildNumberOnlyParsesIntegers() {
        XCTAssertEqual(id("1.4.0", "57").buildNumber, 57)
        // A hand-built local install can carry anything; it just isn't ordered.
        XCTAssertNil(id("1.4.0", "1.4.0-dev").buildNumber)
    }
}

final class WatchBuildStampingTests: XCTestCase {
    func testRoundTripsThroughAMessage() {
        let msg = WatchBuildReport.stamped(
            ["kind": "liveWorkout", "status": "live"], with: id("1.4.0", "57")
        )
        XCTAssertEqual(msg["kind"] as? String, "liveWorkout")
        XCTAssertEqual(WatchBuildReport.identity(in: msg), id("1.4.0", "57"))
    }

    func testStampingIsANoOpWithoutAnIdentity() {
        // Reporting is observability: it must never be able to damage the
        // message it rides on.
        let msg = WatchBuildReport.stamped(["kind": "requestSession"], with: nil)
        XCTAssertEqual(msg.count, 1)
        XCTAssertNil(WatchBuildReport.identity(in: msg))
    }

    func testUnstampedMessageYieldsNoIdentity() {
        XCTAssertNil(WatchBuildReport.identity(in: ["kind": "liveForce", "kg": 12.5]))
    }

    func testStrippingLeavesTheOriginalPayloadShape() {
        // The live-workout / live-force payloads are forwarded to the WebView
        // as-is; the report fields must not leak into those message types.
        let stamped = WatchBuildReport.stamped(
            ["kind": "liveForce", "kg": 12.5], with: id("1.4.0", "57")
        )
        let stripped = WatchBuildReport.stripped(stamped)
        XCTAssertEqual(stripped.count, 2)
        XCTAssertEqual(stripped["kg"] as? Double, 12.5)
        XCTAssertNil(stripped[WatchBuildReport.versionKey])
        XCTAssertNil(stripped[WatchBuildReport.buildKey])
    }
}

final class WatchBuildStatusTests: XCTestCase {
    private let phone = id("1.4.0", "57")

    func testMatchingBuilds() {
        XCTAssertEqual(
            WatchBuildReport.status(watch: id("1.4.0", "57"), phone: phone, pairing: pairing()),
            .match
        )
    }

    func testWatchBehindIsOrdered() {
        // The whole point of #228: a pre-#208 watch against a fixed phone.
        XCTAssertEqual(
            WatchBuildReport.status(watch: id("1.3.0", "51"), phone: phone, pairing: pairing()),
            .watchBehind
        )
    }

    func testWatchAheadIsOrdered() {
        XCTAssertEqual(
            WatchBuildReport.status(watch: id("1.5.0", "60"), phone: phone, pairing: pairing()),
            .watchAhead
        )
    }

    func testUnorderableDifferenceIsStillADifference() {
        // Non-integer build numbers can't be ordered, but "these are not the
        // same install" is still the actionable fact.
        XCTAssertEqual(
            WatchBuildReport.status(
                watch: id("1.4.0", "local"), phone: phone, pairing: pairing()
            ),
            .differs
        )
        // Same build number, different marketing version — not orderable
        // either, and definitely not a match.
        XCTAssertEqual(
            WatchBuildReport.status(watch: id("1.3.0", "57"), phone: phone, pairing: pairing()),
            .differs
        )
    }

    func testNeverReportedIsNotAMatch() {
        // A watch that has never reported must not render as up to date.
        XCTAssertEqual(
            WatchBuildReport.status(watch: nil, phone: phone, pairing: pairing()),
            .notReported
        )
    }

    func testNotPairedAndAppNotInstalledAreDistinct() {
        XCTAssertEqual(
            WatchBuildReport.status(watch: nil, phone: phone, pairing: pairing(paired: false)),
            .notPaired
        )
        XCTAssertEqual(
            WatchBuildReport.status(
                watch: nil, phone: phone, pairing: pairing(appInstalled: false)
            ),
            .appNotInstalled
        )
        // iPad: WCSession isn't supported at all, so there is no watch to lag.
        XCTAssertEqual(
            WatchBuildReport.status(watch: nil, phone: phone, pairing: pairing(supported: false)),
            .notPaired
        )
    }

    func testPreActivationIsUnknownRatherThanNotPaired() {
        // isPaired/isWatchAppInstalled only mean anything after activation —
        // reading them early would report a paired watch as absent.
        XCTAssertEqual(
            WatchBuildReport.status(
                watch: id("1.4.0", "57"), phone: phone, pairing: pairing(activated: false)
            ),
            .unknown
        )
    }

    func testUnknownPhoneBuildCannotBeCompared() {
        XCTAssertEqual(
            WatchBuildReport.status(watch: id("1.4.0", "57"), phone: nil, pairing: pairing()),
            .unknown
        )
    }

    func testStaleReportFromAnUnpairedWatchDoesNotClaimAMatch() {
        // The watch was unpaired after reporting: the stored build is history,
        // not the state of a paired device.
        XCTAssertEqual(
            WatchBuildReport.status(
                watch: id("1.4.0", "57"), phone: phone, pairing: pairing(paired: false)
            ),
            .notPaired
        )
    }
}
