import XCTest
@testable import GlucOSEngine

/// The Mac popover's opening stagger and the summary card's period slide.
final class PopoverStaggerTests: XCTestCase {
    private typealias S = PopoverStagger.Section

    func testEverySectionShowingTakesItsTurnInLayoutOrder() {
        let all = Set(S.allCases)
        XCTAssertEqual(S.allCases.map { PopoverStagger.order(of: $0, showing: all) }, [0, 1, 2, 3, 4, 5, 6])
    }

    func testMissingSectionsLeaveNoPause() {
        // No notices or prompts: the chart comes straight after the hero.
        let showing: Set<S> = [.hero, .chart, .summary, .toolbar, .footer]
        XCTAssertNil(PopoverStagger.order(of: .notices, showing: showing))
        XCTAssertNil(PopoverStagger.order(of: .prompts, showing: showing))
        XCTAssertEqual(PopoverStagger.order(of: .chart, showing: showing), 1)
        XCTAssertEqual(PopoverStagger.delay(of: .chart, showing: showing), PopoverStagger.step, accuracy: 1e-9)
        XCTAssertEqual(PopoverStagger.order(of: .footer, showing: showing), 4)
    }

    func testHeroSlotAlwaysCountsForTheEmptyState() {
        let showing: Set<S> = [.notices, .toolbar, .footer]
        XCTAssertEqual(PopoverStagger.order(of: .hero, showing: showing), 0)
        XCTAssertEqual(PopoverStagger.order(of: .notices, showing: showing), 1)
        XCTAssertEqual(PopoverStagger.delay(of: .hero, showing: showing), 0)
    }

    func testOpeningIsShort() {
        let settled = PopoverStagger.settled(showing: Set(S.allCases))
        XCTAssertEqual(settled, 6 * PopoverStagger.step + PopoverStagger.duration, accuracy: 1e-9)
        XCTAssertLessThan(settled, 0.65)
    }

    func testForecastWaitsForItsCard() {
        let all = Set(S.allCases)
        let card = PopoverStagger.delay(of: .chart, showing: all)
        let forecast = PopoverStagger.forecastDelay(showing: all)
        XCTAssertGreaterThan(forecast, card)
        XCTAssertLessThan(forecast, card + PopoverStagger.duration)
        // No chart (no reading yet): nothing to wait for.
        XCTAssertEqual(PopoverStagger.forecastDelay(showing: [.hero, .notices]), 0)
    }

    func testSlideDirectionFollowsPeriodLength() {
        XCTAssertEqual(PopoverStagger.slideDirection(fromHours: 24, toHours: 168), 1)
        XCTAssertEqual(PopoverStagger.slideDirection(fromHours: 336, toHours: 24), -1)
        XCTAssertEqual(PopoverStagger.slideDirection(fromHours: 168, toHours: 168), 0)
    }
}
