import XCTest
@testable import GlucOSEngine

final class DayPatternMorphTests: XCTestCase {
    /// A pattern with every slot set round `middle`, spread `width` either side for the outer band
    /// and half that for the inner one, with `gaps` left empty.
    private func pattern(_ window: DayPattern.Window = .fortnight, middle: Double, width: Double = 40,
                         gaps: Set<Int> = []) -> DayPattern {
        let slots = (0..<DayPattern.slotCount).map { i -> DayPattern.Slot? in
            guard !gaps.contains(i) else { return nil }
            return DayPattern.Slot(minute: i * DayPattern.slotMinutes, p10: middle - width, p25: middle - width / 2,
                                   p50: middle, p75: middle + width / 2, p90: middle + width, count: 10)
        }
        return DayPattern(window: window, slots: slots, days: window.days)
    }

    func testBlendEndsExactlyOnEachPattern() {
        let a = pattern(.fortnight, middle: 120)
        let b = pattern(.month, middle: 160, width: 60)
        XCTAssertEqual(DayPatternMorph.blend(from: a, to: b, t: 1), b)
        XCTAssertEqual(DayPatternMorph.blend(from: a, to: b, t: 5), b)
        let start = DayPatternMorph.blend(from: a, to: b, t: 0)
        XCTAssertEqual(start.filled.map(\.p50), a.filled.map(\.p50))
        XCTAssertEqual(start.filled.map(\.p90), a.filled.map(\.p90))
        XCTAssertEqual(start.window, .month)
    }

    func testBlendGlidesEachSlotInPlace() throws {
        let a = pattern(middle: 120, width: 40)
        let b = pattern(.month, middle: 160, width: 60)
        let mid = DayPatternMorph.blend(from: a, to: b, t: 0.5)
        let s = try XCTUnwrap(mid.slots[10])
        XCTAssertEqual(s.minute, 300)
        XCTAssertEqual(s.p50, 140, accuracy: 1e-9)
        XCTAssertEqual(s.p10, 90, accuracy: 1e-9)
        XCTAssertEqual(s.p90, 190, accuracy: 1e-9)
    }

    func testGapsTakeTheNewPatternAtOnce() {
        let a = pattern(middle: 120, gaps: [3])
        let b = pattern(.month, middle: 160, gaps: [7])
        let mid = DayPatternMorph.blend(from: a, to: b, t: 0.3)
        XCTAssertNotNil(mid.slots[3], "a slot the new period fills shows straight away")
        XCTAssertEqual(mid.slots[3]?.p50, 160)
        XCTAssertNil(mid.slots[7], "a slot the new period lacks is a gap straight away")
    }

    func testMismatchedSlotCountsJumpToTheNewPattern() {
        let a = DayPattern(window: .fortnight, slots: [nil], days: 5)
        let b = pattern(.month, middle: 150)
        XCTAssertEqual(DayPatternMorph.blend(from: a, to: b, t: 0.5), b)
    }

    func testSpreadGrowsBandsOutOfTheMiddleLine() throws {
        let p = pattern(middle: 130, width: 40, gaps: [0])
        let none = DayPatternMorph.spread(p, reveal: 0)
        XCTAssertNil(none.slots[0])
        for s in none.filled {
            XCTAssertEqual(s.p10, 130, accuracy: 1e-9)
            XCTAssertEqual(s.p90, 130, accuracy: 1e-9)
            XCTAssertEqual(s.p50, 130, accuracy: 1e-9)
        }
        let half = try XCTUnwrap(DayPatternMorph.spread(p, reveal: 0.5).slots[5])
        XCTAssertEqual(half.p10, 110, accuracy: 1e-9)
        XCTAssertEqual(half.p75, 140, accuracy: 1e-9)
        XCTAssertEqual(DayPatternMorph.spread(p, reveal: 1), p)
        XCTAssertEqual(DayPatternMorph.spread(p, reveal: 2), p)
    }

    func testAxisGlidesBetweenPeriods() {
        // 14 days reaching 260, 30 days reaching 300: the top of the axis moves 270 → 310.
        let a = pattern(middle: 200, width: 60)
        let b = pattern(.month, middle: 200, width: 100)
        XCTAssertEqual(DayPatternMorph.yDomain(a, low: 70, high: 180).upperBound, 270)
        XCTAssertEqual(DayPatternMorph.yDomain(from: a, to: b, t: 0.5, low: 70, high: 180).upperBound, 290, accuracy: 1e-9)
        XCTAssertEqual(DayPatternMorph.yDomain(from: a, to: b, t: 1, low: 70, high: 180),
                       DayPatternMorph.yDomain(b, low: 70, high: 180))
        // Never narrower than 60–200 or the target, with 10 to spare.
        let flat = pattern(middle: 120, width: 5)
        XCTAssertEqual(DayPatternMorph.yDomain(flat, low: 70, high: 180), 50...210)
    }
}
