import XCTest
@testable import GlucOSEngine

final class LowsSummaryTests: XCTestCase {
    // referenceNow is 14:00 UTC. Readings every 5 minutes, 120 mg/dL except inside `lows`.

    private struct Dip {
        /// Days before today (UTC), and the UTC hour and minute it starts.
        var daysAgo: Int
        var hour: Int
        var minute = 0
        var length: Int
    }

    private func start(_ d: Dip) -> Date {
        utc.startOfDay(for: referenceNow)
            .addingTimeInterval(Double(-d.daysAgo) * 86_400 + Double(d.hour * 3600 + d.minute * 60))
    }

    private func history(days: Int = 30, dips: [Dip]) -> [GlucoseReading] {
        let windows = dips.map { d -> (Date, Date) in
            let s = start(d)
            return (s, s.addingTimeInterval(Double(d.length) * 60))
        }
        var out: [GlucoseReading] = []
        var t = referenceNow.addingTimeInterval(-Double(days) * 86_400 + 300)
        while t <= referenceNow {
            let low = windows.contains { t >= $0.0 && t < $0.1 }
            out.append(reading(t, low ? 55 : 120))
            t = t.addingTimeInterval(300)
        }
        return out
    }

    private func compute(_ readings: [GlucoseReading], period: LowsSummary.Period = .fortnight,
                         meals: [MealEntry] = [], contexts: [ContextEvent] = [],
                         answers: [LowAnswer] = []) -> LowsSummary? {
        LowsSummary.compute(readings: readings, meals: meals, contexts: contexts, answers: answers,
                            low: 70, period: period, calendar: utc)
    }

    func testNoLows() throws {
        let s = try XCTUnwrap(compute(history(dips: [])))
        XCTAssertEqual(s.count, 0)
        XCTAssertNil(s.medianMinutes)
        XCTAssertNil(s.cluster)
        XCTAssertEqual(s.days, 14)
        XCTAssertEqual(LowsSummaryText.headline(s), "No lows in the last 14 days.")
        XCTAssertNil(LowsSummaryText.clusterLine(s))
        XCTAssertEqual(LowsSummaryText.spoken(s, lowLine: "3.9 mmol/L"),
                       "Lows below 3.9 mmol/L, the last 14 days. No lows.")
    }

    func testCountLengthAndOvernightCluster() throws {
        let s = try XCTUnwrap(compute(history(dips: [
            Dip(daysAgo: 1, hour: 2, length: 20),
            Dip(daysAgo: 2, hour: 3, length: 30),
            Dip(daysAgo: 3, hour: 1, length: 40),
            Dip(daysAgo: 4, hour: 15, length: 30),
        ])))
        XCTAssertEqual(s.count, 4)
        XCTAssertEqual(s.lows.map(\.minutes), [30, 40, 30, 20])
        XCTAssertEqual(try XCTUnwrap(s.medianMinutes), 30, accuracy: 0.001)
        XCTAssertEqual(s.byPart, [3, 0, 1, 0])
        XCTAssertEqual(s.cluster, .overnight)
        XCTAssertEqual(LowsSummaryText.headline(s), "4 lows in the last 14 days.")
        XCTAssertEqual(LowsSummaryText.clusterLine(s), "3 of 4 started overnight, midnight to 6 am.")
        // Nothing logged for any of them.
        XCTAssertEqual(s.treated, 0)
        XCTAssertEqual(LowsSummaryText.treatedCaption(s), "4 not logged")
        XCTAssertEqual(LowsSummaryText.spoken(s, lowLine: "3.9 mmol/L"),
                       "Lows below 3.9 mmol/L, the last 14 days. 4 lows. Typical length 30 minutes. "
                       + "0 of 4 treated, 4 with nothing logged. 3 of 4 started overnight, midnight to 6 am.")
    }

    func testSpreadAcrossTheDay() throws {
        let s = try XCTUnwrap(compute(history(dips: [
            Dip(daysAgo: 1, hour: 2, length: 20),
            Dip(daysAgo: 2, hour: 8, length: 20),
            Dip(daysAgo: 3, hour: 13, length: 20),
            Dip(daysAgo: 4, hour: 20, length: 20),
        ])))
        XCTAssertNil(s.cluster)
        XCTAssertEqual(LowsSummaryText.clusterLine(s), "Spread across the day.")
    }

    func testTwoLowsSayNothingAboutTimeOfDay() throws {
        let s = try XCTUnwrap(compute(history(dips: [
            Dip(daysAgo: 1, hour: 2, length: 20),
            Dip(daysAgo: 2, hour: 2, length: 20),
        ])))
        XCTAssertNil(s.cluster)
        XCTAssertNil(LowsSummaryText.clusterLine(s))
    }

    func testTreatedNotTreatedAndNothingLogged() throws {
        let dips = [
            Dip(daysAgo: 1, hour: 9, length: 30),
            Dip(daysAgo: 2, hour: 9, length: 30),
            Dip(daysAgo: 3, hour: 9, length: 30),
            Dip(daysAgo: 4, hour: 9, length: 30),
            Dip(daysAgo: 5, hour: 9, length: 30),
        ]
        let at = { (i: Int, minutes: Double) in self.start(dips[i]).addingTimeInterval(minutes * 60) }
        let s = try XCTUnwrap(compute(
            history(dips: dips),
            meals: [MealEntry(timestamp: at(4, 10), carbs: 15, food: "Jelly beans")],
            contexts: [ContextEvent(timestamp: at(3, -5), tags: [.hypoTreatment])],
            answers: [
                LowAnswer(lowStart: at(2, 0), lowEnd: at(2, 30), answer: .notTreated, answeredAt: at(2, 60)),
                LowAnswer(lowStart: at(1, 0), lowEnd: at(1, 30), answer: .dismissed, answeredAt: at(1, 60)),
            ]))
        // Oldest first: day 5 (meal), day 4 (tag), day 3 (No), day 2 (dismissed), day 1 (nothing).
        XCTAssertEqual(s.lows.map(\.status), [.treated, .treated, .notTreated, .unknown, .unknown])
        XCTAssertEqual(s.treated, 2)
        XCTAssertEqual(s.notTreated, 1)
        XCTAssertEqual(s.unknown, 2)
        XCTAssertEqual(LowsSummaryText.treatedValue(s.treated, of: s.count), "2 of 5")
        XCTAssertEqual(LowsSummaryText.treatedCaption(s), "1 came up by itself, 2 not logged")
        XCTAssertEqual(s.cluster, .morning)
        XCTAssertEqual(LowsSummaryText.clusterLine(s), "5 of 5 started in the morning, 6 am to noon.")
    }

    func testFoodLongAfterTheLowDoesNotCount() throws {
        let dip = Dip(daysAgo: 1, hour: 9, length: 30)
        let s = try XCTUnwrap(compute(history(dips: [dip]),
                                      meals: [MealEntry(timestamp: start(dip).addingTimeInterval(90 * 60), carbs: 40)]))
        XCTAssertEqual(s.lows.map(\.status), [.unknown])
    }

    func testPeriodChoosesTheLows() throws {
        let readings = history(dips: [
            Dip(daysAgo: 2, hour: 2, length: 20),
            Dip(daysAgo: 10, hour: 2, length: 20),
            Dip(daysAgo: 20, hour: 2, length: 20),
        ])
        XCTAssertEqual(try XCTUnwrap(compute(readings, period: .week)).count, 1)
        XCTAssertEqual(try XCTUnwrap(compute(readings, period: .fortnight)).count, 2)
        XCTAssertEqual(try XCTUnwrap(compute(readings, period: .month)).count, 3)
    }

    func testShortDipsAreNotLows() throws {
        let s = try XCTUnwrap(compute(history(dips: [Dip(daysAgo: 1, hour: 2, length: 10)])))
        XCTAssertEqual(s.count, 0)
    }

    func testMatchesWeekInReviewCount() throws {
        let readings = history(dips: [
            Dip(daysAgo: 1, hour: 2, length: 20),
            Dip(daysAgo: 3, hour: 10, length: 45),
            Dip(daysAgo: 5, hour: 22, length: 15),
        ])
        let week = try XCTUnwrap(WeekInReview.compute(readings: readings, low: 70, high: 180, calendar: utc))
        XCTAssertEqual(try XCTUnwrap(compute(readings, period: .week)).count, week.thisWeek.lows)
    }

    func testNeedsADayOfReadings() throws {
        XCTAssertNil(compute(history(days: 0, dips: [])))
        let halfDay = history(dips: []).filter { referenceNow.timeIntervalSince($0.timestamp) < 12 * 3600 }
        XCTAssertNil(compute(halfDay))
        let twoDays = history(days: 2, dips: [])
        let s = try XCTUnwrap(compute(twoDays))
        XCTAssertEqual(s.days, 2)
        XCTAssertEqual(LowsSummaryText.footnote(s, lowLine: "3.9 mmol/L"),
                       "A low is 15 minutes or more below 3.9 mmol/L. Treated means food or a hypo treatment was logged around it. Based on 2 days with readings. Observations, not advice.")
    }

    func testDurations() {
        XCTAssertEqual(LowsSummaryText.duration(25), "25 min")
        XCTAssertEqual(LowsSummaryText.duration(60), "1 h")
        XCTAssertEqual(LowsSummaryText.duration(70), "1 h 10 min")
        XCTAssertEqual(LowsSummaryText.spokenDuration(1), "1 minute")
        XCTAssertEqual(LowsSummaryText.spokenDuration(70), "1 hour 10 minutes")
        XCTAssertEqual(LowsSummaryText.spokenDuration(120), "2 hours")
    }

    func testLowSpansMatchLowRuns() {
        let t0 = referenceNow
        let points: [(Date, Double)] = (0..<40).map { i in
            (t0.addingTimeInterval(Double(i) * 300), (5..<10).contains(i) || (20..<22).contains(i) ? 55 : 120)
        }
        let spans = TodaySoFar.lowSpans(points, low: 70)
        XCTAssertEqual(spans.count, TodaySoFar.lowRuns(points, low: 70))
        XCTAssertEqual(spans, [TodaySoFar.LowSpan(start: t0.addingTimeInterval(1500), end: t0.addingTimeInterval(3000))])
    }

    func testCacheKeyMovesWithAnswersAndPeriod() {
        let readings = history(days: 2, dips: [])
        let a = LowsSummaryCache.key(readings: readings, meals: [], contexts: [], answers: [], low: 70, period: .week)
        let b = LowsSummaryCache.key(readings: readings, meals: [], contexts: [], answers: [], low: 70, period: .month)
        let answer = LowAnswer(lowStart: referenceNow, lowEnd: referenceNow, answer: .notTreated, answeredAt: referenceNow)
        let c = LowsSummaryCache.key(readings: readings, meals: [], contexts: [], answers: [answer], low: 70, period: .week)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a, LowsSummaryCache.key(readings: readings, meals: [], contexts: [], answers: [], low: 70, period: .week))
    }
}
