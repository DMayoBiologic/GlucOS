import XCTest
@testable import GlucOSEngine

/// The iPhone Today stage folding into the navigation bar as you scroll (improvement round 46).
final class HeaderCollapseTests: XCTestCase {
    func testRestAndPullToRefreshStayOpen() {
        XCTAssertEqual(HeaderCollapse.progress(scrolled: 0, stageTop: 0), 0)
        XCTAssertEqual(HeaderCollapse.progress(scrolled: -80, stageTop: 0), 0)
        XCTAssertEqual(HeaderCollapse.progress(scrolled: .nan, stageTop: 0), 0)
        XCTAssertEqual(HeaderCollapse.progress(scrolled: 10, stageTop: .infinity), 0)
    }

    func testFollowsTheScrollAndClamps() {
        // Starts 60 pt before the stage's top reaches the bar and takes 140 pt.
        XCTAssertEqual(HeaderCollapse.progress(scrolled: 50, stageTop: 110), 0)
        XCTAssertEqual(HeaderCollapse.progress(scrolled: 120, stageTop: 110), 0.5)
        XCTAssertEqual(HeaderCollapse.progress(scrolled: 190, stageTop: 110), 1)
        XCTAssertEqual(HeaderCollapse.progress(scrolled: 5000, stageTop: 110), 1)
        // Banners above the stage push the fold further down the page.
        XCTAssertLessThan(HeaderCollapse.progress(scrolled: 120, stageTop: 200),
                          HeaderCollapse.progress(scrolled: 120, stageTop: 60))
    }

    func testNeverGoesBackwardsWhileScrollingOneWay() {
        var last = -1.0
        for y in stride(from: -50.0, through: 400, by: 0.5) {
            let p = HeaderCollapse.progress(scrolled: y, stageTop: 60)
            XCTAssertGreaterThanOrEqual(p, last)
            last = p
        }
    }

    func testRoundedToSteps() {
        var seen = Set<Double>()
        for y in stride(from: 0.0, through: 300, by: 0.25) {
            seen.insert(HeaderCollapse.progress(scrolled: y, stageTop: 60))
        }
        XCTAssertLessThanOrEqual(seen.count, Int(HeaderCollapse.steps) + 1)
    }

    func testShrinksWithMotionAndCrossFadesUnderReduceMotion() {
        XCTAssertEqual(HeaderCollapse.stageScale(0, reduceMotion: false), 1)
        XCTAssertEqual(HeaderCollapse.stageScale(1, reduceMotion: false), HeaderCollapse.stageEndScale, accuracy: 1e-9)
        XCTAssertEqual(HeaderCollapse.titleScale(0, reduceMotion: false), HeaderCollapse.titleStartScale, accuracy: 1e-9)
        XCTAssertEqual(HeaderCollapse.titleScale(1, reduceMotion: false), 1)
        for p in [0, 0.3, 0.5, 0.8, 1.0] {
            XCTAssertEqual(HeaderCollapse.stageScale(p, reduceMotion: true), 1)
            XCTAssertEqual(HeaderCollapse.titleScale(p, reduceMotion: true), 1)
        }
    }

    func testStageAndTitleCrossFade() {
        XCTAssertEqual(HeaderCollapse.stageOpacity(0), 1)
        XCTAssertEqual(HeaderCollapse.stageOpacity(0.5), 1)
        XCTAssertEqual(HeaderCollapse.stageOpacity(1), 0)
        XCTAssertEqual(HeaderCollapse.titleOpacity(0), 0)
        XCTAssertEqual(HeaderCollapse.titleOpacity(1), 1)
        for p in stride(from: 0.0, through: 1, by: 0.05) {
            XCTAssertEqual(HeaderCollapse.stageOpacity(p) + HeaderCollapse.titleOpacity(p), 1, accuracy: 1e-9)
        }
        // The wordmark is gone before the reading starts to show, so they never overlap.
        XCTAssertEqual(HeaderCollapse.wordmarkOpacity(0), 1)
        XCTAssertEqual(HeaderCollapse.wordmarkOpacity(0.5), 0)
        XCTAssertEqual(HeaderCollapse.titleOpacity(0.5), 0)
    }
}
