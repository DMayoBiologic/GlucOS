import XCTest
@testable import GlucOSEngine

/// Insights "Highs" (`HighsSummary`): time above range, how many highs, and the longest.
final class HighsSummaryTests: XCTestCase {
    // referenceNow is 14:00 UTC. Readings every 5 minutes, 120 mg/dL except inside `spikes` (220).
    // The high line is 180 mg/dL.

    private struct Spike {
        /// Days before today (UTC), and the UTC hour and minute it starts.
        var daysAgo: Int
        var hour: Int
        var minute = 0
        var length: Int
        var mgdl = 220.0
    }

    private func start(_ s: Spike) -> Date {
        utc.startOfDay(for: referenceNow)
            .addingTimeInterval(Double(-s.daysAgo) * 86_400 + Double(s.hour * 3600 + s.minute * 60))
    }

    private func history(days: Int = 30, spikes: [Spike]) -> [GlucoseReading] {
        var out: [GlucoseReading] = []
        var t = referenceNow.addingTimeInterval(-Double(days) * 86_400 + 300)
        while t <= referenceNow {
            let spike = spikes.first { s in t >= start(s) && t < start(s).addingTimeInterval(Double(s.length) * 60) }
            out.append(reading(t, spike?.mgdl ?? 120))
            t = t.addingTimeInterval(300)
        }
        return out
    }

    private func compute(_ readings: [GlucoseReading], period: HighsSummary.Period = .fortnight) -> HighsSummary? {
        HighsSummary.compute(readings: readings, high: 180, period: period)
    }

    private let peak: (Double) -> String = { "\(Int($0))" }

    func testNoHighs() throws {
        let s = try XCTUnwrap(compute(history(spikes: [])))
        XCTAssertEqual(s.count, 0)
        XCTAssertEqual(s.timeAbove, 0)
        XCTAssertNil(s.longest)
        XCTAssertEqual(s.days, 14)
        XCTAssertEqual(HighsSummaryText.headline(s), "No highs in the last 14 days.")
        XCTAssertEqual(HighsSummaryText.percent(s.timeAbove), "0%")
        XCTAssertNil(HighsSummaryText.perDayCaption(s))
        XCTAssertNil(HighsSummaryText.longestLine(s, peak: peak, calendar: utc))
        XCTAssertEqual(HighsSummaryText.spoken(s, highLine: "10.0 mmol/L", peak: peak, calendar: utc),
                       "Highs above 10.0 mmol/L, the last 14 days. Time above range 0 percent. No highs.")
    }

    func testTimeAboveCountAndLongest() throws {
        let s = try XCTUnwrap(compute(history(spikes: [
            Spike(daysAgo: 3, hour: 15, length: 30),
            Spike(daysAgo: 2, hour: 3, length: 60, mgdl: 250),
            Spike(daysAgo: 1, hour: 2, length: 120),
        ])))
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s.highs.map(\.minutes), [30, 60, 120])
        XCTAssertEqual(s.highs.map(\.peakMgdl), [220, 250, 220])
        // 42 of 4,032 five-minute buckets: about 1%, 15 minutes a day.
        XCTAssertEqual(s.timeAbove, 42.0 / 4_032, accuracy: 1e-9)
        XCTAssertEqual(s.minutesAbovePerDay, 15, accuracy: 1e-9)
        XCTAssertEqual(HighsSummaryText.percent(s.timeAbove), "1%")
        XCTAssertEqual(HighsSummaryText.perDayCaption(s), "About 15 min a day")
        let longest = try XCTUnwrap(s.longest)
        XCTAssertEqual(longest.minutes, 120)
        XCTAssertEqual(longest.start, start(Spike(daysAgo: 1, hour: 2, length: 120)))
        XCTAssertEqual(HighsSummaryText.headline(s), "3 highs in the last 14 days.")
        let line = try XCTUnwrap(HighsSummaryText.longestLine(s, peak: peak, calendar: utc))
        XCTAssertTrue(line.hasPrefix("The longest began yesterday at "), line)
        XCTAssertTrue(line.hasSuffix(" and peaked at 220."), line)
        let spoken = HighsSummaryText.spoken(s, highLine: "10.0 mmol/L", peak: peak, calendar: utc)
        XCTAssertTrue(spoken.hasPrefix("Highs above 10.0 mmol/L, the last 14 days. Time above range 1 percent, "
                                       + "about 15 minutes a day. 3 highs. Longest 2 hours. The longest began yesterday at "), spoken)
        XCTAssertTrue(spoken.hasSuffix(" and peaked at 220."), spoken)
    }

    func testAShortSpikeCountsAsTimeAboveButNotAsAHigh() throws {
        let s = try XCTUnwrap(compute(history(spikes: [Spike(daysAgo: 1, hour: 9, length: 10)])))
        XCTAssertEqual(s.count, 0)
        XCTAssertEqual(s.timeAbove, 2.0 / 4_032, accuracy: 1e-9)
        // Under half a percent still shows as something.
        XCTAssertEqual(HighsSummaryText.percent(s.timeAbove), "<1%")
        XCTAssertEqual(HighsSummaryText.perDayCaption(s), "About 5 min a day")
    }

    func testAtTheLineIsNotAbove() throws {
        let s = try XCTUnwrap(compute(history(spikes: [Spike(daysAgo: 1, hour: 9, length: 60, mgdl: 180)])))
        XCTAssertEqual(s.count, 0)
        XCTAssertEqual(s.timeAbove, 0)
    }

    func testTheEarlierOfTwoEqualHighsIsTheLongest() throws {
        let s = try XCTUnwrap(compute(history(spikes: [
            Spike(daysAgo: 4, hour: 9, length: 45),
            Spike(daysAgo: 2, hour: 9, length: 45),
        ])))
        XCTAssertEqual(s.longest?.start, start(Spike(daysAgo: 4, hour: 9, length: 45)))
    }

    func testThePeriodLeavesOutOlderHighs() throws {
        let readings = history(spikes: [Spike(daysAgo: 10, hour: 9, length: 60)])
        XCTAssertEqual(try XCTUnwrap(compute(readings, period: .week)).count, 0)
        XCTAssertEqual(try XCTUnwrap(compute(readings, period: .fortnight)).count, 1)
        XCTAssertEqual(try XCTUnwrap(compute(readings, period: .month)).count, 1)
    }

    func testNeedsADayOfReadings() {
        XCTAssertNil(compute(readings(endingAt: referenceNow, minutes: 600) { _ in 200 }))
        XCTAssertNil(compute([]))
    }

    func testAFewDaysOfReadingsSaySo() throws {
        let s = try XCTUnwrap(compute(history(days: 3, spikes: [Spike(daysAgo: 1, hour: 9, length: 60)])))
        XCTAssertEqual(s.days, 3)
        XCTAssertEqual(HighsSummaryText.footnote(s, highLine: "10.0 mmol/L"),
                       "Time above counts every reading over 10.0 mmol/L. A high is 15 minutes or more above it. "
                       + "Based on 3 days with readings. Observations, not advice.")
    }

    func testHighSpansReadLikeLowSpans() {
        // A gap of over 30 minutes ends a high at its last high bucket, as it does a low.
        let t0 = referenceNow
        let points: [(Date, Double)] = [
            (t0, 200), (t0.addingTimeInterval(300), 200), (t0.addingTimeInterval(600), 200),
            (t0.addingTimeInterval(600 + 2_400), 200), (t0.addingTimeInterval(600 + 2_700), 120),
        ]
        let spans = TodaySoFar.highSpans(points, high: 180)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.start, t0)
        XCTAssertEqual(spans.first?.end, t0.addingTimeInterval(900))
        // The low rule is unchanged.
        XCTAssertEqual(TodaySoFar.lowSpans(points.map { ($0.0, 260 - $0.1) }, low: 70).count, 1)
    }

    func testCacheKeyMovesWithTheHighLineAndPeriod() {
        let r = history(days: 2, spikes: [])
        let a = HighsSummaryCache.key(readings: r, high: 180, period: .fortnight)
        XCTAssertEqual(a, HighsSummaryCache.key(readings: r, high: 180, period: .fortnight))
        XCTAssertNotEqual(a, HighsSummaryCache.key(readings: r, high: 200, period: .fortnight))
        XCTAssertNotEqual(a, HighsSummaryCache.key(readings: r, high: 180, period: .week))
    }

    func testTheCardRowSaysWhereItGoes() {
        XCTAssertEqual(HighsSummaryText.logbookLine(.week), "See the last 7 days in the Logbook")
        XCTAssertEqual(HighsSummaryText.logbookHint, "Opens the Logbook on Highs over the same days")
    }
}
