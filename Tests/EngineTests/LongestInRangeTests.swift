import XCTest
@testable import GlucOSEngine

/// Insights "Longest in range" (`LongestInRange`): the longest unbroken stretch in range over the
/// period, when it was, and the Logbook link over it.
final class LongestInRangeTests: XCTestCase {
    // referenceNow is 14:00 UTC. Readings every 5 minutes at 220 mg/dL (above range) except inside
    // `windows` (120, in range). The range is 70–180 mg/dL.

    private struct Window {
        /// Days before today (UTC), and the UTC hour and minute it starts.
        var daysAgo: Int
        var hour: Int
        var minute = 0
        var length: Int
        var mgdl = 120.0
    }

    private func start(_ w: Window) -> Date {
        utc.startOfDay(for: referenceNow)
            .addingTimeInterval(Double(-w.daysAgo) * 86_400 + Double(w.hour * 3600 + w.minute * 60))
    }

    private func history(days: Int = 30, windows: [Window], outside: Double = 220,
                         skip: (Date) -> Bool = { _ in false }) -> [GlucoseReading] {
        var out: [GlucoseReading] = []
        var t = referenceNow.addingTimeInterval(-Double(days) * 86_400 + 300)
        while t <= referenceNow {
            if !skip(t) {
                let w = windows.first { w in t >= start(w) && t < start(w).addingTimeInterval(Double(w.length) * 60) }
                out.append(reading(t, w?.mgdl ?? outside))
            }
            t = t.addingTimeInterval(300)
        }
        return out
    }

    private func compute(_ readings: [GlucoseReading], period: LongestInRange.Period = .fortnight) -> LongestInRange? {
        LongestInRange.compute(readings: readings, low: 70, high: 180, period: period)
    }

    // MARK: Compute

    func testFindsTheLongestStretchAndCountsLongOnes() throws {
        let long = Window(daysAgo: 3, hour: 22, minute: 15, length: 580)   // 9 h 40 min, across midnight
        let r = try XCTUnwrap(compute(history(windows: [
            Window(daysAgo: 5, hour: 8, length: 180),
            long,
            Window(daysAgo: 1, hour: 9, length: 240),
        ])))
        XCTAssertEqual(r.longest.start, start(long))
        XCTAssertEqual(r.longest.minutes, 580, accuracy: 0.01)
        XCTAssertFalse(r.longest.ongoing)
        // 9 h 40 min and exactly 4 h; the 3 h one doesn't count.
        XCTAssertEqual(r.longCount, 2)
        XCTAssertEqual(r.coverage, 1, accuracy: 0.01)
        XCTAssertEqual(LongestInRangeText.length(r.longest), "9 h 40 min")
        XCTAssertEqual(LongestInRangeText.headline(r), "9 h 40 min in range in one go.")
    }

    func testTheRangeEdgesCountAsInRange() throws {
        let r = try XCTUnwrap(compute(history(windows: [
            Window(daysAgo: 2, hour: 1, length: 60, mgdl: 70),
            Window(daysAgo: 2, hour: 2, length: 60, mgdl: 180),
        ])))
        XCTAssertEqual(r.longest.minutes, 120, accuracy: 0.01)
    }

    func testATieShowsTheLaterOne() throws {
        let later = Window(daysAgo: 2, hour: 10, length: 120)
        let r = try XCTUnwrap(compute(history(windows: [Window(daysAgo: 6, hour: 10, length: 120), later])))
        XCTAssertEqual(r.longest.start, start(later))
    }

    func testShortGapsKeepAStretchGoingAndLongOnesEndIt() throws {
        let w = Window(daysAgo: 4, hour: 6, length: 300)
        let s = start(w)
        // 30 minutes without a reading two hours in: still one 5-hour stretch.
        let short = try XCTUnwrap(compute(history(windows: [w]).filter {
            !($0.timestamp > s.addingTimeInterval(7_200) && $0.timestamp < s.addingTimeInterval(7_200 + 1_800))
        }))
        XCTAssertEqual(short.longest.minutes, 300, accuracy: 0.01)
        // 45 minutes without one: it ends five minutes after the last reading before the gap.
        let long = try XCTUnwrap(compute(history(windows: [w]).filter {
            !($0.timestamp > s.addingTimeInterval(7_200) && $0.timestamp < s.addingTimeInterval(7_200 + 2_700))
        }))
        XCTAssertEqual(long.longest.start, s.addingTimeInterval(7_200 + 2_700))
        XCTAssertEqual(long.longest.minutes, 300 - 165, accuracy: 0.01)
    }

    func testAStretchStillGoingIsMarkedAndEndsAtTheNewestReading() throws {
        let w = Window(daysAgo: 0, hour: 6, length: 24 * 60)
        let r = try XCTUnwrap(compute(history(windows: [w])))
        XCTAssertTrue(r.longest.ongoing)
        XCTAssertEqual(r.longest.end, referenceNow)
        XCTAssertEqual(r.longest.minutes, 8 * 60, accuracy: 0.01)
        XCTAssertEqual(LongestInRangeText.headline(r), "8 h in range in one go, and counting.")
        XCTAssertTrue(LongestInRangeText.whenLine(r, now: referenceNow, calendar: utc).hasPrefix("Since today at "))
    }

    func testAStretchFromBeforeThePeriodCountsFromItsStart() throws {
        // In range for the whole of the last 7 days and more: it counts 7 days, not 10.
        let r = try XCTUnwrap(compute(history(windows: [], outside: 120), period: .week))
        XCTAssertEqual(r.longest.minutes, 7 * 1_440, accuracy: 5.01)
        XCTAssertTrue(r.longest.start >= referenceNow.addingTimeInterval(-7 * 86_400))
    }

    func testHiddenUnderHalfCoverage() throws {
        // Readings on 6 of the 14 days: under half.
        let sparse = history(windows: [Window(daysAgo: 1, hour: 9, length: 120)]) {
            $0 < referenceNow.addingTimeInterval(-6 * 86_400)
        }
        XCTAssertNil(compute(sparse))
        // On 8 of 14: shown, and the footnote says how much the readings cover.
        let some = history(windows: [Window(daysAgo: 1, hour: 9, length: 120)]) {
            $0 < referenceNow.addingTimeInterval(-8 * 86_400)
        }
        let r = try XCTUnwrap(compute(some))
        XCTAssertEqual(r.coverage, 8.0 / 14, accuracy: 0.01)
        XCTAssertTrue(LongestInRangeText.footnote(r, rangeLine: "3.9–10.0 mmol/L").contains("Readings cover 57%"))
        // A full period's footnote doesn't.
        let full = try XCTUnwrap(compute(history(windows: [Window(daysAgo: 1, hour: 9, length: 120)])))
        XCTAssertFalse(LongestInRangeText.footnote(full, rangeLine: "3.9–10.0 mmol/L").contains("Readings cover"))
    }

    func testNothingInRangeOrNoReadingsGivesNothing() {
        XCTAssertNil(compute([]))
        XCTAssertNil(compute(history(windows: [])))
        // Ten minutes in range isn't a stretch.
        XCTAssertNil(compute(history(windows: [Window(daysAgo: 2, hour: 3, length: 10)])))
    }

    func testFifteenMinuteHistoryCountsAsCovered() throws {
        let every15 = history(windows: [Window(daysAgo: 2, hour: 3, length: 180)]).filter {
            Int($0.timestamp.timeIntervalSince1970) % 900 == 0
        }
        let r = try XCTUnwrap(compute(every15))
        XCTAssertEqual(r.coverage, 1, accuracy: 0.01)
        XCTAssertEqual(r.longest.minutes, 180, accuracy: 0.01)
    }

    // MARK: Words

    func testWhenLineNamesBothEnds() throws {
        let w = Window(daysAgo: 1, hour: 22, minute: 15, length: 580)
        let r = try XCTUnwrap(compute(history(windows: [w])))
        let from = ClockLabel.time(start(w), calendar: utc)
        let to = ClockLabel.time(start(w).addingTimeInterval(580 * 60), calendar: utc)
        XCTAssertEqual(LongestInRangeText.whenLine(r, now: referenceNow, calendar: utc),
                       "From yesterday at \(from) to today at \(to).")
        XCTAssertEqual(LongestInRangeText.span(r.longest, now: referenceNow, calendar: utc), "Yesterday \(from) – \(to)")
        // The same day: the end has no day.
        let same = Window(daysAgo: 1, hour: 9, length: 120)
        let s = try XCTUnwrap(compute(history(windows: [same])))
        XCTAssertEqual(LongestInRangeText.whenLine(s, now: referenceNow, calendar: utc),
                       "From yesterday at \(ClockLabel.time(start(same), calendar: utc)) to \(ClockLabel.time(start(same).addingTimeInterval(7_200), calendar: utc)).")
    }

    func testSpokenIsOneSentenceSet() throws {
        let r = try XCTUnwrap(compute(history(windows: [Window(daysAgo: 1, hour: 9, length: 280)])))
        let spoken = LongestInRangeText.spoken(r, rangeLine: "3.9–10.0 mmol/L", now: referenceNow, calendar: utc)
        XCTAssertTrue(spoken.hasPrefix("Longest time in range, the last 14 days. 4 hours 40 minutes in one go. From yesterday at "))
        XCTAssertTrue(spoken.contains("1 stretch of 4 hours or more"))
        XCTAssertTrue(spoken.hasSuffix("In range is 3.9–10.0 mmol/L."))
        for word in ["dose", "bolus", "insulin", "units", "correction"] {
            XCTAssertFalse(spoken.lowercased().contains(word))
            XCTAssertFalse(LongestInRangeText.footnote(r, rangeLine: "x").lowercased().contains(word))
        }
    }

    // MARK: Logbook

    func testLinkOpensTheLogbookOverTheStretch() throws {
        let w = Window(daysAgo: 2, hour: 9, length: 300)
        let r = try XCTUnwrap(compute(history(windows: [w])))
        let link = LongestInRange.link(r.longest, now: referenceNow, calendar: utc)
        XCTAssertEqual(link.filter, .inRangeStretch)
        XCTAssertEqual(link.period.interval, DateInterval(start: start(w), duration: 300 * 60))
        XCTAssertNil(link.kindChip)
        XCTAssertEqual(link.sourceID, "logbook-inRangeStretch")
        XCTAssertEqual(LogbookFilter.inRangeStretch.title, "Longest in range")
        XCTAssertFalse(LogbookFilter.inRangeStretch.isListed)
        XCTAssertEqual(LogbookFilter.inRangeStretch.insightsCard, .inRangeStretch)
        let meal = LogEntry.meal(MealEntry(timestamp: start(w).addingTimeInterval(600), carbs: 30))
        XCTAssertTrue(LogbookFilter.inRangeStretch.matches(meal, lowIDs: []))
    }

    func testLinkForAStretchStillGoingRunsToNow() throws {
        let r = try XCTUnwrap(compute(history(windows: [Window(daysAgo: 0, hour: 6, length: 24 * 60)])))
        let now = referenceNow.addingTimeInterval(1_200)
        XCTAssertEqual(LongestInRange.link(r.longest, now: now, calendar: utc).period.interval.end, now)
    }

    // MARK: Layout, share, step

    func testCardSitsAfterTimeInRangeByHour() {
        XCTAssertEqual(InsightsCard(rawValue: "longestInRange"), .longestInRange)
        XCTAssertEqual(InsightsCard.longestInRange.title, "Longest in range")
        for defaults in [InsightsCard.phoneDefault, InsightsCard.macDefault] {
            let i = defaults.firstIndex(of: .hourlyInRange)!
            XCTAssertEqual(defaults[i + 1], .longestInRange)
        }
        XCTAssertTrue(InsightsCard.longestInRange.stepsWithPeriod)
        // A layout saved before it shipped, Time in range by hour moved to the top: it lands right after.
        let saved = InsightsLayout(order: ["hourlyInRange", "weekInReview", "lows"], hidden: ["lows"])
        XCTAssertEqual(Array(saved.arranged(InsightsCard.macDefault).prefix(2)), [.hourlyInRange, .longestInRange])
        XCTAssertFalse(saved.isHidden(.longestInRange))
    }

    func testSharePeriodFollowsThePicker() {
        let d = UserDefaults(suiteName: "LongestInRangeTests.share")!
        d.removePersistentDomain(forName: "LongestInRangeTests.share")
        XCTAssertEqual(InsightsShare.period(for: .longestInRange, defaults: d, firstReading: nil), .days(14))
        d.set(30, forKey: InsightsShare.Key.longestInRange)
        XCTAssertEqual(InsightsShare.period(for: .longestInRange, defaults: d, firstReading: nil), .days(30))
    }
}
