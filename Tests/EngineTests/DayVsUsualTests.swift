import XCTest
@testable import GlucOSEngine

final class DayVsUsualTests: XCTestCase {
    // referenceNow is 14:00 UTC.
    private var today: Date { utc.startOfDay(for: referenceNow) }
    private func day(_ back: Int) -> Date { utc.date(byAdding: .day, value: -back, to: today)! }

    private func fig(_ inRange: Double, coverage: Double = 1) -> DayInRange {
        DayInRange(below: 0, inRange: inRange, above: 1 - inRange, spanMinutes: 1440, coverage: coverage)
    }

    /// Yesterday at `share`, the 14 days before it at `prior` (nil leaves a day out).
    private func figures(yesterday share: Double, prior: [Double?]) -> [Date: DayInRange] {
        var out: [Date: DayInRange] = [day(1): fig(share)]
        for (i, p) in prior.enumerated() { if let p { out[day(i + 2)] = fig(p) } }
        return out
    }

    private func compare(_ f: [Date: DayInRange], _ d: Date? = nil) -> DayVsUsual? {
        DayVsUsual.compare(d ?? day(1), figures: f, now: referenceNow, calendar: utc)
    }

    func testMedianOfTheFourteenDaysBefore() throws {
        let prior: [Double?] = [0.6, 0.62, 0.64, 0.66, 0.68, 0.70, 0.72, 0.74, 0.76, 0.78, 0.80, 0.82, 0.84, 0.86]
        let c = try XCTUnwrap(compare(figures(yesterday: 0.85, prior: prior)))
        XCTAssertEqual(c.usual, 0.73, accuracy: 0.0001)
        XCTAssertEqual(c.days, 14)
        XCTAssertEqual(c.points, 12)
        XCTAssertEqual(c.direction, .above)
        XCTAssertTrue(c.isNotable)
    }

    func testADayFifteenDaysBackIsNotCounted() throws {
        var f = figures(yesterday: 0.7, prior: Array(repeating: 0.7, count: 14))
        f[day(16)] = fig(0) // outside the window
        let c = try XCTUnwrap(compare(f))
        XCTAssertEqual(c.usual, 0.7, accuracy: 0.0001)
        XCTAssertEqual(c.days, 14)
    }

    func testThresholdIsTenPointsOnTheRoundedPercents() throws {
        let prior = Array<Double?>(repeating: 0.70, count: 14)
        XCTAssertFalse(try XCTUnwrap(compare(figures(yesterday: 0.79, prior: prior))).isNotable)
        XCTAssertTrue(try XCTUnwrap(compare(figures(yesterday: 0.80, prior: prior))).isNotable)
        let below = try XCTUnwrap(compare(figures(yesterday: 0.58, prior: prior)))
        XCTAssertTrue(below.isNotable)
        XCTAssertEqual(below.points, -12)
        XCTAssertEqual(below.direction, .below)
        XCTAssertFalse(try XCTUnwrap(compare(figures(yesterday: 0.61, prior: prior))).isNotable)
    }

    func testNeedsSevenComparableDays() {
        var prior = Array<Double?>(repeating: nil, count: 14)
        for i in 0..<6 { prior[i] = 0.5 }
        XCTAssertNil(compare(figures(yesterday: 0.9, prior: prior)))
        prior[10] = 0.5
        XCTAssertNotNil(compare(figures(yesterday: 0.9, prior: prior)))
    }

    func testThinlyCoveredDaysAreNeitherComparedNorCounted() throws {
        var f = figures(yesterday: 0.9, prior: Array(repeating: 0.6, count: 14))
        f[day(1)] = fig(0.9, coverage: 0.4)
        XCTAssertNil(compare(f))
        // A thin prior day is left out of the usual.
        var g = figures(yesterday: 0.9, prior: Array(repeating: 0.6, count: 14))
        g[day(2)] = fig(0, coverage: 0.3)
        let c = try XCTUnwrap(compare(g))
        XCTAssertEqual(c.days, 13)
        XCTAssertEqual(c.usual, 0.6, accuracy: 0.0001)
    }

    func testTodayIsNotCompared() {
        var f = figures(yesterday: 0.7, prior: Array(repeating: 0.7, count: 14))
        f[today] = fig(1)
        XCTAssertNil(compare(f, today))
    }

    func testNotableKeepsOnlyFarDays() {
        let f = figures(yesterday: 0.95, prior: Array(repeating: 0.7, count: 14))
        let n = DayVsUsual.notable([day(1), day(2), today], figures: f, now: referenceNow, calendar: utc)
        XCTAssertEqual(Set(n.keys), [day(1)])
    }

    func testDaysNeededCoversEachDayAndTheFourteenBefore() {
        let needed = DayVsUsual.daysNeeded(for: [day(1), day(3)], calendar: utc)
        XCTAssertEqual(needed.count, 17) // day 1 ... day 17
        XCTAssertEqual(needed.first, day(17))
        XCTAssertEqual(needed.last, day(1))
    }

    func testMedianOfAnEvenCount() {
        XCTAssertEqual(DayVsUsual.median([0.2, 0.8, 0.4, 0.6]), 0.5, accuracy: 0.0001)
        XCTAssertEqual(DayVsUsual.median([]), 0)
    }

    func testFromReadingsLikeTheBars() throws {
        // 14 days at 120 except 6 hours at 220 each (75%); yesterday all in range.
        var r: [GlucoseReading] = []
        for back in 1...15 {
            let start = day(back)
            var t = start
            while t < start.addingTimeInterval(86_400) {
                let hour = Int(t.timeIntervalSince(start) / 3600)
                r.append(reading(t, back > 1 && hour < 6 ? 220 : 120))
                t = t.addingTimeInterval(300)
            }
        }
        let days = DayVsUsual.daysNeeded(for: [day(1)], calendar: utc)
        let f = DayInRange.compute(readings: r, days: days, low: 70, high: 180, now: referenceNow, calendar: utc)
        let c = try XCTUnwrap(DayVsUsual.compare(day(1), figures: f, now: referenceNow, calendar: utc))
        XCTAssertEqual(c.usual, 0.75, accuracy: 0.001)
        XCTAssertEqual(c.points, 25)
    }

    // MARK: Words

    func testWords() throws {
        let c = DayVsUsual(day: day(1), inRange: 0.80, usual: 0.68, days: 12)
        XCTAssertEqual(DayVsUsualText.short(c), "+12 vs your usual")
        XCTAssertEqual(DayVsUsualText.spoken(c), "12 points above your usual time in range of 68%")
        let b = DayVsUsual(day: day(1), inRange: 0.57, usual: 0.68, days: 12)
        XCTAssertEqual(DayVsUsualText.short(b), "\u{2212}11 vs your usual")
        XCTAssertEqual(DayVsUsualText.spoken(b), "11 points below your usual time in range of 68%")
        let lines = DayVsUsualText.explanation(c, spokenDay: "Yesterday")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("14 days before this one"))
        XCTAssertTrue(lines[0].contains("the 12 that had enough readings: 68%"))
        XCTAssertEqual(lines[1], "Yesterday was 80% in range, 12 points above it.")
        XCTAssertTrue(lines[2].contains("10 or more points"))
        XCTAssertTrue(DayVsUsualText.help(c).hasSuffix("Click to see how it's worked out."))
        for line in lines + [DayVsUsualText.spoken(c)] {
            for word in ["bolus", "dose", "units", "insulin"] { XCTAssertFalse(line.lowercased().contains(word), word) }
        }
    }

    func testWhatsNewHighlightFits() throws {
        let release = try XCTUnwrap(WhatsNewCatalog.releases.first { $0.version == "1.97.0" })
        let h = try XCTUnwrap(release.highlights.first { $0.title == "Days compared with your usual" })
        XCTAssertLessThanOrEqual(h.title.count, 40)
        XCTAssertTrue(h.detail.hasSuffix("."))
        for word in ["bolus", "dose", "units", "correct"] {
            XCTAssertFalse(h.detail.lowercased().contains(word), word)
        }
    }
}
