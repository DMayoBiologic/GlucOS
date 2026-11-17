import XCTest
@testable import GlucOSEngine

/// Insights cards rise in once per visit, staggered when they come into view together.
final class CardRevealsTests: XCTestCase {
    func testEachCardRisesOncePerVisit() {
        let reveals = CardReveals()
        let t = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(reveals.hasRevealed("lows"))
        XCTAssertEqual(reveals.claim("lows", now: t), 0)
        XCTAssertTrue(reveals.hasRevealed("lows"))
        XCTAssertNil(reveals.claim("lows", now: t.addingTimeInterval(5)))
        // A new visit starts afresh.
        XCTAssertEqual(CardReveals().claim("lows", now: t), 0)
    }

    func testCardsComingIntoViewTogetherAreStaggered() {
        let reveals = CardReveals()
        let t = Date(timeIntervalSince1970: 1_000)
        let delays = (0..<7).map { reveals.claim("card\($0)", now: t.addingTimeInterval(Double($0) * 0.01)) }
        let step = CardReveals.step
        XCTAssertEqual(delays, [0, step, 2 * step, 3 * step, 4 * step, 4 * step, 4 * step])
    }

    func testALaterScrollStartsANewBatch() {
        let reveals = CardReveals()
        let t = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(reveals.claim("a", now: t), 0)
        XCTAssertEqual(reveals.claim("b", now: t.addingTimeInterval(0.1)), CardReveals.step)
        XCTAssertEqual(reveals.claim("c", now: t.addingTimeInterval(2)), 0)
    }
}
