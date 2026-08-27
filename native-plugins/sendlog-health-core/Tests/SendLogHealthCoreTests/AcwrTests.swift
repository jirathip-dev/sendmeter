import XCTest
@testable import SendLogHealthCore

final class AcwrTests: XCTestCase {
    func testNoLoadReturnsNil() {
        XCTAssertNil(Acwr.ratio(dailyLoads: Array(repeating: 0, count: 90)))
    }

    func testNonPositiveChronicLoadReturnsNil() {
        XCTAssertNil(Acwr.ratio(dailyLoads: [-1]))
    }

    func testSteadyLoadTendsToOne() {
        // Constant daily load: acute and chronic EWMAs converge, ratio ≈ 1.
        let r = Acwr.ratio(dailyLoads: Array(repeating: 100, count: 90))
        XCTAssertNotNil(r)
        XCTAssertEqual(r!, 1.0, accuracy: 0.01)
    }

    func testRecentSpikeRaisesRatioAboveOne() {
        // Flat for 83 days then a hard 7-day spike → acute outruns chronic.
        var loads = Array(repeating: 50.0, count: 83)
        loads.append(contentsOf: Array(repeating: 300.0, count: 7))
        let r = Acwr.ratio(dailyLoads: loads)
        XCTAssertNotNil(r)
        XCTAssertGreaterThan(r!, 1.3)
    }
}
