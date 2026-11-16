import XCTest
@testable import GlucOSEngine

final class WeekInReviewTests: XCTestCase {
    // referenceNow is 14:00 UTC; this week is the 7 days up to it, last week the 7 before.

    /// Readings every `step` minutes for `days` days up to `referenceNow`, following
    /// `value(minute of the UTC day, days before referenceNow)` -> mg/dL (nil leaves a gap).
    private func history(days: Int, step: Int = 5, value: (Int, Int) -> Double?) -> [GlucoseReading] {
        var out: [GlucoseReading] = []
        var t = referenceNow.addingTimeInterval(-Double(days) * 86_400 + Double(step) * 60)
        while t <= referenceNow {
            let minute = Int(t.timeIntervalSince(utc.startOfDay(for: t)) / 60)
            let ago = Int((referenceNow.timeIntervalSince(t) / 86_400).rounded(.down))
            if let v = value(minute, ago) { out.append(reading(t, v)) }
            t = t.addingTimeInterval(Double(step) * 60)
        }
        return out
    }

    private func compute(_ readings: [GlucoseReading]) -> WeekInReview? {
        WeekInReview.compute(readings: readings, low: 70, high: 180, calendar: utc)
    }

    func testSameAsLastWeek() throws {
        let w = try XCTUnwrap(compute(history(days: 14) { _, _ in 120 }))
        XCTAssertEqual(w.thisWeek.timeInRange, 1, accuracy: 0.001)
        XCTAssertEqual(w.thisWeek.meanMgdl, 120, accuracy: 0.001)
        XCTAssertEqual(w.thisWeek.days, 7)
        XCTAssertEqual(w.thisWeek.lows, 0)
        let last = try XCTUnwrap(w.lastWeek)
        XCTAssertEqual(last.days, 7)
        XCTAssertEqual(w.rangeChange, .same)
        XCTAssertEqual(WeekInReviewText.headline(w), "About the same time in range as last week.")
        XCTAssertEqual(w.sides, [.current, .previous])
        XCTAssertEqual(WeekInReviewText.spoken(.previous, w, unit: .mgdl),
                       "7 days. 100 percent in range. Average 120 mg/dL. No lows.")
        XCTAssertTrue(w.steadyAcrossDay)
        XCTAssertEqual(WeekInReviewText.lines(w), ["About the same at every time of day."])
    }

    func testBetterAndWorseThanLastWeek() throws {
        // Last week was above range every evening (a quarter of the day).
        let better = try XCTUnwrap(compute(history(days: 14) { m, ago in ago >= 7 && m >= 18 * 60 ? 240 : 120 }))
        XCTAssertEqual(try XCTUnwrap(better.lastWeek).timeInRange, 0.75, accuracy: 0.02)
        XCTAssertEqual(better.rangeChange, .better)
        XCTAssertEqual(WeekInReviewText.headline(better), "More time in range than last week.")
        XCTAssertEqual(WeekInReviewText.percent(try XCTUnwrap(better.week(.previous)).timeInRange), "75%")
        XCTAssertEqual(WeekInReviewText.average(try XCTUnwrap(better.week(.previous)), unit: .mgdl), "150 mg/dL")

        let worse = try XCTUnwrap(compute(history(days: 14) { m, ago in ago < 7 && m >= 18 * 60 ? 240 : 120 }))
        XCTAssertEqual(worse.rangeChange, .worse)
        XCTAssertEqual(WeekInReviewText.headline(worse), "Less time in range than last week.")
    }

    func testBestAndHardestTimeOfDay() throws {
        // This week: evenings above range, mornings partly below, afternoons and nights in range.
        let w = try XCTUnwrap(compute(history(days: 14) { m, ago in
            guard ago < 7 else { return 120 }
            if m >= 18 * 60 { return 240 }
            if m >= 6 * 60 && m < 7 * 60 { return 60 }
            return 120
        }))
        XCTAssertEqual(w.parts.count, 4)
        XCTAssertFalse(w.steadyAcrossDay)
        // Overnight and afternoon tie at 100%; neither has lows, so the first in clock order wins.
        XCTAssertEqual(w.best?.timeInRange ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(w.worst?.part, .evening)
        XCTAssertEqual(WeekInReviewText.lines(w).last, "Hardest: evenings, 0% in range, mostly above range.")
        XCTAssertGreaterThan(w.thisWeek.lows, 0)
        XCTAssertEqual(w.lastWeek?.lows, 0)

        XCTAssertEqual(WeekInReviewText.spokenLines(w).last,
                       "Hardest: evenings, 6 pm to midnight, 0 percent in range, mostly above range.")
        XCTAssertEqual(WeekInReviewText.spokenLines(w).count, WeekInReviewText.lines(w).count)
        XCTAssertTrue(try XCTUnwrap(WeekInReviewText.spoken(.current, w, unit: .mgdl)).hasSuffix(WeekInReviewText.lows(w.thisWeek.lows) + "."))
        XCTAssertTrue(try XCTUnwrap(WeekInReviewText.spoken(.previous, w, unit: .mgdl)).hasSuffix("No lows."))
    }

    func testHardestCanLeanLow() throws {
        let w = try XCTUnwrap(compute(history(days: 7) { m, _ in m < 6 * 60 && m % 60 < 30 ? 55 : 120 }))
        XCTAssertEqual(w.worst?.part, .overnight)
        XCTAssertEqual(WeekInReviewText.lean(try XCTUnwrap(w.worst)), "mostly below range")
    }

    func testOneWeekShowsOnItsOwn() throws {
        let w = try XCTUnwrap(compute(history(days: 7) { _, _ in 120 }))
        XCTAssertNil(w.lastWeek)
        XCTAssertNil(w.rangeChange)
        XCTAssertEqual(w.sides, [.current])
        XCTAssertNil(WeekInReviewText.spoken(.previous, w, unit: .mgdl))
        XCTAssertEqual(WeekInReviewText.headline(w), "100% in range over the last 7 days.")
        XCTAssertTrue(WeekInReviewText.footnote(w).hasPrefix("Last week joins in"))
    }

    func testPartialLastWeekIsLeftOut() throws {
        // Ten days: last week has only 3 days of readings, under the 4 it needs.
        let w = try XCTUnwrap(compute(history(days: 10) { _, _ in 120 }))
        XCTAssertNil(w.lastWeek)
    }

    func testTooFewDaysThisWeekShowsNothing() {
        XCTAssertNil(compute(history(days: 3) { _, _ in 120 }))
        XCTAssertNil(compute([]))
        XCTAssertFalse(WeekInReviewText.emptyLine.isEmpty)
    }

    func testFifteenMinuteHistoryCountsAsComplete() throws {
        // LibreLinkUp's 15-minute history fills every 15-minute slot, so the weeks count.
        let w = try XCTUnwrap(compute(history(days: 14, step: 15) { _, _ in 120 }))
        XCTAssertEqual(w.thisWeek.days, 7)
        XCTAssertNotNil(w.lastWeek)
        XCTAssertEqual(w.parts.count, 4)
    }

    func testCacheKeyMovesWithData() {
        let a = history(days: 7) { _, _ in 120 }
        let k1 = WeekInReviewCache.key(readings: a, low: 70, high: 180)
        XCTAssertEqual(k1, WeekInReviewCache.key(readings: a, low: 70, high: 180))
        XCTAssertNotEqual(k1, WeekInReviewCache.key(readings: a, low: 70, high: 200))
        let more = a + [reading(referenceNow.addingTimeInterval(900), 120)]
        XCTAssertNotEqual(k1, WeekInReviewCache.key(readings: more, low: 70, high: 180))
    }

    func testLowsWords() {
        XCTAssertEqual(WeekInReviewText.lows(0), "No lows")
        XCTAssertEqual(WeekInReviewText.lows(1), "1 low")
        XCTAssertEqual(WeekInReviewText.lows(3), "3 lows")
    }

    func testEachWeekOpensTheLogbookOnItsOwnSevenDays() {
        let newest = referenceNow.addingTimeInterval(-600)
        let this = LogbookLink.week(.current, newestReading: newest, now: referenceNow)
        XCTAssertEqual(this.filter, .thisWeek)
        XCTAssertEqual(this.period.interval.start, newest.addingTimeInterval(-7 * 86_400))
        // Runs on to now, so something logged after the last reading still shows.
        XCTAssertEqual(this.period.interval.end, referenceNow)
        XCTAssertEqual(this.period.label, "Last 7 days")

        let last = LogbookLink.week(.previous, newestReading: newest, now: referenceNow)
        XCTAssertEqual(last.filter, .lastWeek)
        XCTAssertEqual(last.period.interval.start, newest.addingTimeInterval(-14 * 86_400))
        XCTAssertEqual(last.period.interval.end, newest.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(last.period.label, "7 days before")

        // The weeks meet without overlapping, matching what the card counted.
        XCTAssertEqual(WeekInReview.interval(.previous, end: newest).end, WeekInReview.interval(.current, end: newest).start)
        XCTAssertNotEqual(this.sourceID, last.sourceID)
    }

    func testTheWeekChipsKeepEverythingAndAreOnlyOfferedFromTheCard() {
        let dose = LogEntry.dose(InsulinDose(timestamp: referenceNow, units: 2, kind: .rapid, name: "NovoRapid", note: ""))
        XCTAssertTrue(LogbookFilter.thisWeek.matches(dose, lowIDs: []))
        XCTAssertTrue(LogbookFilter.lastWeek.matches(dose, lowIDs: []))
        XCTAssertFalse(LogbookFilter.thisWeek.isListed)
        XCTAssertFalse(LogbookFilter.lastWeek.isListed)
        let offered = LogbookFilter.available(entries: [dose], alerts: [])
        XCTAssertFalse(offered.contains(.thisWeek))
        XCTAssertFalse(offered.contains(.lastWeek))
        XCTAssertEqual(LogbookFilter.thisWeek.title, "This week")
        XCTAssertEqual(LogbookFilter.lastWeek.title, "Last week")
        // Back on the Mac goes to the one card from either week.
        XCTAssertEqual(LogbookFilter.lastWeek.insightsCard, .thisWeek)
        XCTAssertEqual(LogbookFilter.thisWeek.insightsCard, .thisWeek)
    }
}
