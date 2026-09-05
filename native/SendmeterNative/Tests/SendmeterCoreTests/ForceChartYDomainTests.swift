import XCTest
@testable import SendmeterCore

/// #900: discriminating tests for the live force trace Y-domain. The domain
/// must keep the target band's on-screen level stable across rep boundaries
/// (window empties) and identical wherever the shared function is called,
/// while still expanding for genuine big pulls.
final class ForceChartYDomainTests: XCTestCase {
    // MARK: - Pure domain function

    /// AC2: the domain never collapses below the band's upper bound plus
    /// headroom when the visible window empties.
    func testDomainFloorsAtBandUpperBoundPlusHeadroom() {
        let emptyWindow = ForceChartYDomain.maxValue(
            bandUpperBoundKilograms: 11.3,
            windowPeakKilograms: 0,
            heldPeakKilograms: 0
        )
        XCTAssertEqual(emptyWindow, 11.3 * ForceChartYDomain.headroom, accuracy: 0.001)
        // Rest-level window contents below the band cannot move the domain.
        let restingWindow = ForceChartYDomain.maxValue(
            bandUpperBoundKilograms: 11.3,
            windowPeakKilograms: 2.0,
            heldPeakKilograms: 0
        )
        XCTAssertEqual(emptyWindow, restingWindow, accuracy: 0.001)
    }

    /// The legacy absolute 10 kg floor still applies when no band is shown.
    func testDomainFloorsAtTenWhenNoBand() {
        XCTAssertEqual(
            ForceChartYDomain.maxValue(
                bandUpperBoundKilograms: nil,
                windowPeakKilograms: 0,
                heldPeakKilograms: 0
            ),
            10 * ForceChartYDomain.headroom,
            accuracy: 0.001
        )
    }

    /// A genuine big pull that exceeds the anchored domain still expands it.
    func testBigWindowPeakStillExpandsTheDomain() {
        let domain = ForceChartYDomain.maxValue(
            bandUpperBoundKilograms: 11.3,
            windowPeakKilograms: 17.3,
            heldPeakKilograms: 0
        )
        XCTAssertEqual(domain, 17.3 * ForceChartYDomain.headroom, accuracy: 0.001)
        XCTAssertGreaterThan(domain, 11.3 * ForceChartYDomain.headroom)
    }

    /// The held recent-pull peak keeps the domain open once the window empties.
    func testHeldPeakKeepsTheDomainOpenForAnEmptyWindow() {
        let domain = ForceChartYDomain.maxValue(
            bandUpperBoundKilograms: 11.3,
            windowPeakKilograms: 0,
            heldPeakKilograms: 17.3
        )
        XCTAssertEqual(domain, 17.3 * ForceChartYDomain.headroom, accuracy: 0.001)
    }

    /// A held peak never inflates a bandless trace: with no band there is no
    /// level to stabilize, so the legacy fit-the-window scale is preserved.
    func testHeldPeakIsIgnoredWhenNoBandIsPresent() {
        XCTAssertEqual(
            ForceChartYDomain.maxValue(
                bandUpperBoundKilograms: nil,
                windowPeakKilograms: 0,
                heldPeakKilograms: 17.3
            ),
            10 * ForceChartYDomain.headroom,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ForceChartYDomain.maxValue(
                bandUpperBoundKilograms: nil,
                windowPeakKilograms: 17.3,
                heldPeakKilograms: 17.3
            ),
            17.3 * ForceChartYDomain.headroom,
            accuracy: 0.001
        )
    }

    // MARK: - Tracker hysteresis (rep-boundary simulation)

    /// AC1: the band's on-screen level (fraction of chart height) stays put
    /// across a simulated rep boundary — mid-rep window, then the empty
    /// window that follows the buffer reset.
    func testBandLevelIsStableAcrossARepBoundaryWindowEmpty() {
        let bandUpper = 11.3
        var tracker = ForceChartYDomainTracker()

        // Mid-rep: the window carries the pull's peak.
        tracker.frame(bandUpperBoundKilograms: bandUpper, windowPeakKilograms: 17.3)
        let midRep = ForceChartYDomain.maxValue(
            bandUpperBoundKilograms: bandUpper,
            windowPeakKilograms: 17.3,
            heldPeakKilograms: tracker.heldPeakKilograms
        )

        // Rep boundary: the window empties (accumulator reset). The domain
        // must NOT collapse back to the band anchor — no band jump.
        tracker.frame(bandUpperBoundKilograms: bandUpper, windowPeakKilograms: 0)
        let afterEmpty = ForceChartYDomain.maxValue(
            bandUpperBoundKilograms: bandUpper,
            windowPeakKilograms: 0,
            heldPeakKilograms: tracker.heldPeakKilograms
        )

        XCTAssertEqual(afterEmpty, midRep, accuracy: 0.001)
        XCTAssertEqual(
            bandUpper / afterEmpty,
            bandUpper / midRep,
            accuracy: 0.0001,
            "the band's fraction of chart height must not move at the boundary"
        )
        XCTAssertGreaterThan(
            afterEmpty,
            bandUpper * ForceChartYDomain.headroom,
            "the domain must stay open for the recent pull instead of collapsing"
        )
    }

    /// The same monotone-hold property expressed through the tracker's own
    /// view of the domain: consecutive empties keep the top until a new
    /// stronger pull arrives.
    func testTrackerHoldSurvivesConsecutiveEmptyWindows() {
        var tracker = ForceChartYDomainTracker()
        tracker.frame(bandUpperBoundKilograms: 11.3, windowPeakKilograms: 15.0)
        tracker.frame(bandUpperBoundKilograms: 11.3, windowPeakKilograms: 0)
        tracker.frame(bandUpperBoundKilograms: 11.3, windowPeakKilograms: 0)
        XCTAssertEqual(tracker.heldPeakKilograms, 15.0, accuracy: 0.001)
    }

    /// A stronger later pull expands the hold (and never shrinks it).
    func testTrackerHoldGrowsWithNewStrongerPulls() {
        var tracker = ForceChartYDomainTracker()
        tracker.frame(bandUpperBoundKilograms: 11.3, windowPeakKilograms: 15.0)
        tracker.frame(bandUpperBoundKilograms: 11.3, windowPeakKilograms: 17.3)
        tracker.frame(bandUpperBoundKilograms: 11.3, windowPeakKilograms: 16.0)
        XCTAssertEqual(tracker.heldPeakKilograms, 17.3, accuracy: 0.001)
    }

    /// The numeric target changing (band upper bound) is the only permitted
    /// level change: a new target context re-anchors the domain.
    func testTrackerReanchorsWhenTheTargetBandChanges() {
        var tracker = ForceChartYDomainTracker()
        tracker.frame(bandUpperBoundKilograms: 11.3, windowPeakKilograms: 17.3)
        tracker.frame(bandUpperBoundKilograms: 11.3, windowPeakKilograms: 0)

        // A new stage band (ramp) starts a new context from the anchor.
        tracker.frame(bandUpperBoundKilograms: 13.0, windowPeakKilograms: 0)
        XCTAssertEqual(tracker.heldPeakKilograms, 0, accuracy: 0.001)
        XCTAssertEqual(
            ForceChartYDomain.maxValue(
                bandUpperBoundKilograms: 13.0,
                windowPeakKilograms: 0,
                heldPeakKilograms: tracker.heldPeakKilograms
            ),
            13.0 * ForceChartYDomain.headroom,
            accuracy: 0.001
        )
    }

    /// Dropping the band (plan cleared / bandless mode) also re-anchors so a
    /// stale pull peak cannot zoom a bandless trace out.
    func testTrackerReanchorsWhenTheBandDisappears() {
        var tracker = ForceChartYDomainTracker()
        tracker.frame(bandUpperBoundKilograms: 11.3, windowPeakKilograms: 17.3)
        tracker.frame(bandUpperBoundKilograms: nil, windowPeakKilograms: 0)
        XCTAssertEqual(tracker.heldPeakKilograms, 0, accuracy: 0.001)
    }

    /// A fresh tracker behaves exactly like the original per-frame formula,
    /// so charts without a history (first mount) render identically.
    func testFreshTrackerMatchesLegacyFittingBehavior() {
        var tracker = ForceChartYDomainTracker()
        tracker.frame(bandUpperBoundKilograms: 11.3, windowPeakKilograms: 17.3)
        XCTAssertEqual(tracker.heldPeakKilograms, 17.3, accuracy: 0.001)

        // Bandless legacy behavior: the window fits itself (10 kg floor
        // applies, the old hold cannot inflate a bandless trace).
        tracker.frame(bandUpperBoundKilograms: nil, windowPeakKilograms: 17.3)
        XCTAssertEqual(
            ForceChartYDomain.maxValue(
                bandUpperBoundKilograms: nil,
                windowPeakKilograms: 17.3,
                heldPeakKilograms: tracker.heldPeakKilograms
            ),
            17.3 * ForceChartYDomain.headroom,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ForceChartYDomain.maxValue(
                bandUpperBoundKilograms: nil,
                windowPeakKilograms: 6.0,
                heldPeakKilograms: tracker.heldPeakKilograms
            ),
            10 * ForceChartYDomain.headroom,
            accuracy: 0.001,
            "a bandless window below the 10 kg floor keeps the legacy floor"
        )
    }
}
