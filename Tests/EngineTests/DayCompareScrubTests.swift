import XCTest
@testable import GlucOSEngine

final class DayCompareScrubTests: XCTestCase {
    private func run(_ pairs: [(Double, Double)]) -> [DayComparePoint] {
        pairs.map { DayComparePoint(minute: $0.0, mgdl: $0.1) }
    }

    // MARK: Stops and snapping

    func testStopsJoinBothDaysOnceEachInOrder() {
        let a = [run([(10, 100), (15, 110)]), run([(60, 120)])]
        let b = [run([(12, 90), (15, 95)])]
        XCTAssertEqual(DayCompareScrub.stops(a, b), [10, 12, 15, 60])
    }

    func testSnapsToNearestReadingEitherSide() {
        let stops: [Double] = [10, 15, 20, 300]
        XCTAssertEqual(DayCompareScrub.snap(finger: 16, stops: stops), 15)
        XCTAssertEqual(DayCompareScrub.snap(finger: 19, stops: stops), 20)
        XCTAssertEqual(DayCompareScrub.snap(finger: 0, stops: stops), 10)
        XCTAssertEqual(DayCompareScrub.snap(finger: 900, stops: stops), nil, "nothing within the gap")
        XCTAssertEqual(DayCompareScrub.snap(finger: 12.5, stops: stops), 10, "the earlier stop wins a tie")
    }

    func testNothingToSnapToWithoutReadings() {
        XCTAssertNil(DayCompareScrub.snap(finger: 100, stops: []))
        XCTAssertNil(DayCompareScrub.snap(finger: .nan, stops: [100]))
    }

    func testGapBeyondTwentyMinutesShowsNoCursor() {
        let stops: [Double] = [100, 200]
        XCTAssertEqual(DayCompareScrub.snap(finger: 120, stops: stops), 100)
        XCTAssertNil(DayCompareScrub.snap(finger: 125, stops: stops))
        XCTAssertNil(DayCompareScrub.snap(finger: 150, stops: stops))
        XCTAssertEqual(DayCompareScrub.snap(finger: 180, stops: stops), 200)
    }

    // MARK: Values at the cursor

    func testEachDayReadsItsOwnNearestPoint() {
        let a = [run([(600, 100), (605, 110)])]
        let b = [run([(603, 150)])]
        let r = DayCompareScrub.readout(at: 603, first: a, second: b)
        XCTAssertEqual(r.first, 110)
        XCTAssertEqual(r.second, 150)
        XCTAssertEqual(r.difference, 40)
    }

    func testADayWithAGapThereHasNoValue() {
        let a = [run([(600, 100)])]
        let b = [run([(700, 150)])]
        let r = DayCompareScrub.readout(at: 600, first: a, second: b)
        XCTAssertEqual(r.first, 100)
        XCTAssertNil(r.second)
        XCTAssertNil(r.difference)
    }

    func testRepeatedHourTakesTheNearerPointThenTheEarlierRun() {
        // A 25-hour day: the repeated hour draws over itself as its own run.
        let a = [run([(120, 100), (125, 104)]), run([(121, 200), (126, 204)])]
        XCTAssertEqual(DayCompareScrub.value(at: 121, in: a), 200)
        XCTAssertEqual(DayCompareScrub.value(at: 120.5, in: a), 100, "a tie goes to the earlier run")
    }

    // MARK: Feel

    func testLandingTicksOnceThenReadingsDoNot() {
        let a = [run([(0, 120), (5, 125), (10, 130)])]
        XCTAssertEqual(DayCompareScrubTick.tick(from: nil, to: 5, first: a, second: [], low: 70, high: 180), .landed)
        XCTAssertNil(DayCompareScrubTick.tick(from: 5, to: 10, first: a, second: [], low: 70, high: 180))
        XCTAssertNil(DayCompareScrubTick.tick(from: 5, to: 5, first: a, second: [], low: 70, high: 180))
        XCTAssertNil(DayCompareScrubTick.tick(from: 5, to: nil, first: a, second: [], low: 70, high: 180))
    }

    func testCrossingALineOnEitherDayTicks() {
        let a = [run([(0, 120), (5, 125), (10, 130)])]
        let b = [run([(0, 175), (5, 185), (10, 190)])]
        XCTAssertEqual(DayCompareScrubTick.tick(from: 0, to: 5, first: a, second: b, low: 70, high: 180), .rangeEdge)
        XCTAssertNil(DayCompareScrubTick.tick(from: 5, to: 10, first: a, second: b, low: 70, high: 180))
    }

    func testFastDragThroughAShortLowStillTicks() {
        let a = [run([(0, 90), (5, 65), (10, 90)])]
        XCTAssertTrue(DayCompareScrub.crossesRangeEdge(from: 0, to: 10, first: a, second: [], low: 70, high: 180))
        XCTAssertTrue(DayCompareScrub.crossesRangeEdge(from: 10, to: 0, first: a, second: [], low: 70, high: 180))
    }

    // MARK: VoiceOver stepping

    func testVoiceOverStepsAnHourAtATime() {
        let stops = stride(from: 0.0, to: 1_440, by: 5).map { $0 + 2 }
        XCTAssertEqual(DayCompareScrub.stepped(nil, by: 1, stops: stops), 722, "starts near noon")
        XCTAssertEqual(DayCompareScrub.stepped(722, by: 1, stops: stops), 782)
        XCTAssertEqual(DayCompareScrub.stepped(722, by: -1, stops: stops), 662)
        XCTAssertEqual(DayCompareScrub.stepped(662, by: -1, stops: stops), 602)
        XCTAssertNil(DayCompareScrub.stepped(1_437, by: 1, stops: stops))
        XCTAssertNil(DayCompareScrub.stepped(2, by: -1, stops: stops))
    }

    func testVoiceOverSkipsHoursWithNoReadings() {
        let stops: [Double] = [60, 300]
        XCTAssertEqual(DayCompareScrub.stepped(60, by: 1, stops: stops), 300)
        XCTAssertEqual(DayCompareScrub.stepped(300, by: -1, stops: stops), 60)
        XCTAssertNil(DayCompareScrub.stepped(60, by: 0, stops: stops))
    }

    // MARK: Words

    func testReadoutWords() {
        let r = DayCompareReadout(minute: 1_095, first: 130, second: 110)
        XCTAssertEqual(DayCompareScrubText.time(r.minute), "6:15 pm")
        XCTAssertEqual(DayCompareScrubText.value(r.first, unit: .mgdl), "130")
        XCTAssertEqual(DayCompareScrubText.value(nil, unit: .mgdl), "–")
        XCTAssertEqual(DayCompareScrubText.difference(r, unit: .mgdl), "20 higher")
        XCTAssertEqual(DayCompareScrubText.firstHigher(r, unit: .mgdl), true)
        let level = DayCompareReadout(minute: 0, first: 100, second: 100.4)
        XCTAssertEqual(DayCompareScrubText.difference(level, unit: .mgdl), "Same")
        XCTAssertNil(DayCompareScrubText.firstHigher(level, unit: .mgdl))
        XCTAssertNil(DayCompareScrubText.difference(DayCompareReadout(minute: 0, first: 100, second: nil), unit: .mgdl))
    }

    func testSpokenReadsBothValuesAndWhichIsHigher() {
        let r = DayCompareReadout(minute: 1_095, first: 110, second: 130)
        XCTAssertEqual(DayCompareScrubText.spoken(r, first: "Today", second: "Monday 11 November", unit: .mgdl),
                       "6:15 pm. Today 110 mg/dL, Monday 11 November 130 mg/dL. Monday 11 November 20 mg/dL higher.")
        let gap = DayCompareReadout(minute: 720, first: 110, second: nil)
        XCTAssertEqual(DayCompareScrubText.spoken(gap, first: "Today", second: "Yesterday", unit: .mgdl),
                       "noon. Today 110 mg/dL, Yesterday no reading.")
    }

    func testWordsNeverJudgeADay() {
        let r = DayCompareReadout(minute: 600, first: 60, second: 250)
        let text = [DayCompareScrubText.spoken(r, first: "Today", second: "Yesterday", unit: .mmol),
                    DayCompareScrubText.difference(r, unit: .mmol) ?? "",
                    DayCompareScrubText.hint, DayCompareScrubText.macHint].joined(separator: " ").lowercased()
        for word in ["better", "worse", "should", "dose", "bolus"] { XCTAssertFalse(text.contains(word), word) }
    }
}
