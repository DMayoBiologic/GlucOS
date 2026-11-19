import XCTest
@testable import GlucOSEngine

final class DayPatternScrubTests: XCTestCase {
    /// A pattern whose middle line is `p50(slotIndex)`, nil where it returns nil.
    private func pattern(_ p50: (Int) -> Double?) -> DayPattern {
        let slots: [DayPattern.Slot?] = (0..<DayPattern.slotCount).map { i in
            p50(i).map { DayPattern.Slot(minute: i * 30, p10: $0 - 30, p25: $0 - 15, p50: $0, p75: $0 + 15,
                                         p90: $0 + 30, count: 10) }
        }
        return DayPattern(window: .fortnight, slots: slots, days: 14)
    }

    /// Highest at 2 pm (slot 28) at 200, lowest at 4 am (slot 8) at 80, 120 elsewhere.
    private var shaped: DayPattern {
        pattern { i in i == 28 ? 200 : i == 8 ? 80 : 120 }
    }

    // MARK: Stops

    func testStopsAreFilledSlotMiddles() {
        let p = pattern { i in i < 2 || i == 5 ? 100 : nil }
        XCTAssertEqual(DayPatternScrub.stops(p), [15, 45, 165])
        XCTAssertEqual(DayPatternScrub.slot(at: 45, in: p)?.minute, 30)
        XCTAssertNil(DayPatternScrub.slot(at: 40, in: p), "only a slot's middle is a stop")
        XCTAssertNil(DayPatternScrub.slot(at: 75, in: p), "missing slot")
    }

    func testNearestSlotAndGaps() {
        let p = pattern { i in i < 2 || i == 10 ? 100 : nil }
        XCTAssertEqual(DayPatternScrub.nearest(finger: 20, pattern: p), 15)
        XCTAssertEqual(DayPatternScrub.nearest(finger: 30, pattern: p), 15, "earlier wins a tie")
        XCTAssertEqual(DayPatternScrub.nearest(finger: 70, pattern: p), 45)
        XCTAssertNil(DayPatternScrub.nearest(finger: 150, pattern: p), "nothing within a slot")
        XCTAssertEqual(DayPatternScrub.nearest(finger: 300, pattern: p), 315)
        XCTAssertNil(DayPatternScrub.nearest(finger: .nan, pattern: p))
    }

    // MARK: Landmarks and snapping

    func testLandmarksAreTheUsualHighestAndLowest() {
        XCTAssertEqual(DayPatternScrub.landmarks(shaped).count, 2)
        XCTAssertEqual(DayPatternScrub.landmark(at: 255, in: shaped), .lowest(mgdl: 80))
        XCTAssertEqual(DayPatternScrub.landmark(at: 855, in: shaped), .highest(mgdl: 200))
        XCTAssertNil(DayPatternScrub.landmark(at: 285, in: shaped))
        XCTAssertTrue(DayPatternScrub.landmarks(pattern { _ in 120 }).isEmpty, "a flat day has none")
    }

    func testSnapsOntoALandmarkWithinReachAndHolds() {
        // 5 minutes per point: reach 8 pt = 40 min, let go 14 pt = 70 min.
        let p = shaped
        XCTAssertEqual(DayPatternScrub.settle(finger: 820, pattern: p, current: nil, minutesPerPoint: 5), 855)
        XCTAssertEqual(DayPatternScrub.settle(finger: 790, pattern: p, current: nil, minutesPerPoint: 5), 795,
                       "out of reach: the nearest slot")
        XCTAssertEqual(DayPatternScrub.settle(finger: 790, pattern: p, current: 855, minutesPerPoint: 5), 855,
                       "held until let go")
        XCTAssertEqual(DayPatternScrub.settle(finger: 780, pattern: p, current: 855, minutesPerPoint: 5), 765,
                       "past let go it follows the finger")
    }

    func testWithoutAPlotWidthItStillFollowsSlots() {
        XCTAssertEqual(DayPatternScrub.settle(finger: 820, pattern: shaped, current: nil, minutesPerPoint: 0), 825)
    }

    // MARK: Feel

    func testTicks() {
        // Above range 10 am–noon (slots 20–23), 120 elsewhere: the first 120 slot (midnight) is the
        // lowest, 10 am the highest.
        let p = pattern { i in i >= 20 && i < 24 ? 200 : 120 }
        XCTAssertEqual(DayPatternScrubTick.tick(from: nil, to: 45, pattern: p, low: 70, high: 180), .snapped)
        XCTAssertNil(DayPatternScrubTick.tick(from: 45, to: 75, pattern: p, low: 70, high: 180))
        XCTAssertNil(DayPatternScrubTick.tick(from: 45, to: 45, pattern: p, low: 70, high: 180))
        XCTAssertNil(DayPatternScrubTick.tick(from: 45, to: nil, pattern: p, low: 70, high: 180))
        XCTAssertEqual(DayPatternScrubTick.tick(from: 555, to: 645, pattern: p, low: 70, high: 180), .rangeEdge)
        XCTAssertEqual(DayPatternScrubTick.tick(from: 500, to: 800, pattern: p, low: 70, high: 180), .rangeEdge,
                       "a fast drag over the whole high stretch still ticks")
        XCTAssertEqual(DayPatternScrubTick.tick(from: 825, to: 855, pattern: shaped, low: 70, high: 250), .snapped,
                       "landing on the usual high")
    }

    // MARK: VoiceOver

    func testVoiceOverStepsAnHourAtATime() {
        let p = pattern { i in i == 25 || i == 26 || i == 30 || i == 31 ? 120 : nil }
        // Noon's slots (24, 25): 24 is missing, so 12:30.
        XCTAssertEqual(DayPatternScrub.stepped(nil, by: 1, pattern: p), 765)
        XCTAssertEqual(DayPatternScrub.stepped(765, by: 1, pattern: p), 795, "1 pm")
        XCTAssertEqual(DayPatternScrub.stepped(795, by: 1, pattern: p), 915, "skips the empty hour to 3 pm")
        XCTAssertNil(DayPatternScrub.stepped(915, by: 1, pattern: p), "nothing after 3 pm's hour")
        XCTAssertEqual(DayPatternScrub.stepped(945, by: -1, pattern: p), 795)
        XCTAssertNil(DayPatternScrub.stepped(765, by: -1, pattern: p))
        XCTAssertNil(DayPatternScrub.stepped(nil, by: 0, pattern: p))
    }

    // MARK: Words

    func testWords() throws {
        let s = try XCTUnwrap(DayPatternScrub.slot(at: 855, in: shaped))
        XCTAssertEqual(DayPatternScrubText.time(s), "2 pm–2:30 pm")
        XCTAssertEqual(DayPatternScrubText.middleHalf(s, unit: .mgdl), "185–215")
        XCTAssertEqual(DayPatternScrubText.spoken(s, kind: .highest(mgdl: 200), unit: .mgdl),
                       "2 pm to 2:30 pm. Middle 200 mg/dL, middle half 185 to 215. Highest of the day.")
        let first = try XCTUnwrap(DayPatternScrub.slot(at: 15, in: shaped))
        XCTAssertEqual(DayPatternScrubText.time(first), "midnight–12:30 am")
        XCTAssertNil(DayPatternScrubText.landmark(nil))
    }

    func testWordsNeverAdvise() throws {
        let s = try XCTUnwrap(DayPatternScrub.slot(at: 255, in: shaped))
        let all = [DayPatternScrubText.spoken(s, kind: .lowest(mgdl: 80), unit: .mmol), DayPatternScrubText.hint]
            .joined(separator: " ").lowercased()
        for word in ["insulin", "dose", "bolus", "units", "should", "correct"] {
            XCTAssertFalse(all.contains(word), word)
        }
    }
}
