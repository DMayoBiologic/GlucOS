import XCTest
@testable import GlucOSEngine

final class DayCompareMotionTests: XCTestCase {
    private func run(_ minutes: [Double], mgdl: Double = 100) -> [DayComparePoint] {
        minutes.map { DayComparePoint(minute: $0, mgdl: mgdl) }
    }

    // MARK: Which motion

    func testOpeningDrawsInUnlessReduceMotion() {
        XCTAssertEqual(DayCompareMotion.opening(reduceMotion: false), .drawIn)
        XCTAssertEqual(DayCompareMotion.opening(reduceMotion: true), .instant)
    }

    func testLaterDayEntersFromTheRight() {
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(DayCompareMotion.change(from: d, to: d.addingTimeInterval(86_400), reduceMotion: false),
                       .slide(direction: 1))
        XCTAssertEqual(DayCompareMotion.change(from: d, to: d.addingTimeInterval(-86_400), reduceMotion: false),
                       .slide(direction: -1))
    }

    func testReduceMotionAndNoChangeAreInstant() {
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(DayCompareMotion.change(from: d, to: d.addingTimeInterval(86_400), reduceMotion: true), .instant)
        XCTAssertEqual(DayCompareMotion.change(from: d, to: d, reduceMotion: false), .instant)
    }

    // MARK: Slide frames

    func testSlideFramesCrossOver() {
        let start = DayCompareMotion.frame(progress: 0, direction: 1)
        XCTAssertEqual(start.incomingOffset, DayCompareMotion.slideMinutes)
        XCTAssertEqual(start.incomingOpacity, 0)
        XCTAssertEqual(start.outgoingOffset, 0)
        XCTAssertEqual(start.outgoingOpacity, 1)
        let end = DayCompareMotion.frame(progress: 1, direction: 1)
        XCTAssertEqual(end.incomingOffset, 0)
        XCTAssertEqual(end.incomingOpacity, 1)
        XCTAssertEqual(end.outgoingOffset, -DayCompareMotion.slideMinutes)
        XCTAssertEqual(end.outgoingOpacity, 0)
        let back = DayCompareMotion.frame(progress: 0.5, direction: -1)
        XCTAssertEqual(back.incomingOffset, -DayCompareMotion.slideMinutes / 2)
        XCTAssertEqual(back.outgoingOffset, DayCompareMotion.slideMinutes / 2)
    }

    func testSlideProgressIsClamped() {
        XCTAssertEqual(DayCompareMotion.frame(progress: -0.5, direction: 1), DayCompareMotion.frame(progress: 0, direction: 1))
        XCTAssertEqual(DayCompareMotion.frame(progress: 2, direction: 1), DayCompareMotion.frame(progress: 1, direction: 1))
    }

    // MARK: Draw-in

    func testRevealCutsAtTheEdgeWithAnInterpolatedTip() throws {
        let runs = [[DayComparePoint(minute: 0, mgdl: 100), DayComparePoint(minute: 720, mgdl: 200),
                     DayComparePoint(minute: 1_440, mgdl: 100)]]
        let half = DayCompareMotion.revealed(runs, fraction: 0.25)
        XCTAssertEqual(half.count, 1)
        let run = try XCTUnwrap(half.first)
        XCTAssertEqual(run.map(\.minute), [0, 360])
        XCTAssertEqual(run.last?.mgdl ?? 0, 150, accuracy: 0.001)
    }

    func testRevealEnds() {
        let runs = [run([0, 5, 10])]
        XCTAssertEqual(DayCompareMotion.revealed(runs, fraction: 0), [])
        XCTAssertEqual(DayCompareMotion.revealed(runs, fraction: 1), runs)
        XCTAssertEqual(DayCompareMotion.revealed(runs, fraction: 3), runs)
    }

    func testRevealDropsRunsNotYetReached() {
        let runs = [run([0, 60]), run([600, 660])]
        let shown = DayCompareMotion.revealed(runs, fraction: 0.1) // 144 minutes
        XCTAssertEqual(shown, [run([0, 60])])
    }

    // MARK: Cross-slide

    func testSlidMovesAndClipsToTheDay() throws {
        let runs = [[DayComparePoint(minute: 0, mgdl: 100), DayComparePoint(minute: 100, mgdl: 200),
                     DayComparePoint(minute: 1_400, mgdl: 100)]]
        let right = try XCTUnwrap(DayCompareMotion.slid(runs, by: 100).first)
        XCTAssertEqual(right.first?.minute, 100)
        XCTAssertEqual(right.last?.minute, DayCompare.minutesPerDay)
        let left = try XCTUnwrap(DayCompareMotion.slid(runs, by: -50).first)
        XCTAssertEqual(left.first?.minute, 0)
        XCTAssertEqual(left.first?.mgdl ?? 0, 150, accuracy: 0.001)
        XCTAssertEqual(left.last?.minute, 1_350)
    }

    func testSlidKeepsASegmentSpanningTheWholeDay() throws {
        let runs = [run([-100, 1_600])]
        let shown = try XCTUnwrap(DayCompareMotion.clipped(runs, from: 0, to: DayCompare.minutesPerDay).first)
        XCTAssertEqual(shown.map(\.minute), [0, DayCompare.minutesPerDay])
    }

    func testSlidOffTheDayIsEmpty() {
        XCTAssertEqual(DayCompareMotion.slid([run([0, 60])], by: -200), [])
        XCTAssertEqual(DayCompareMotion.slid([run([0, 60])], by: 0), [run([0, 60])])
    }

    // MARK: Scale

    func testScaleGlidesBetweenDomains() {
        let mid = DayCompareMotion.blend(40...360, 40...210, progress: 0.5)
        XCTAssertEqual(mid.lowerBound, 40)
        XCTAssertEqual(mid.upperBound, 285)
        XCTAssertEqual(DayCompareMotion.blend(40...360, 40...210, progress: 0), 40...360)
        XCTAssertEqual(DayCompareMotion.blend(40...360, 40...210, progress: 5), 40...210)
    }
}
