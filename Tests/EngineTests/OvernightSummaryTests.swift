import XCTest
@testable import GlucOSEngine

/// Insights "Overnight" (`OvernightSummary`): time in range from midnight to 6 am, overnight lows,
/// and the usual change across the night.
final class OvernightSummaryTests: XCTestCase {
    // referenceNow is 14:00 UTC. Readings every 5 minutes for 30 days, 120 mg/dL unless `value`
    // says otherwise. Low line 70, high line 180, nights in UTC.

    /// Midnight UTC `daysAgo` days before today, plus `minutes`.
    private func at(_ daysAgo: Int, _ minutes: Int = 0) -> Date {
        utc.startOfDay(for: referenceNow).addingTimeInterval(Double(-daysAgo) * 86_400 + Double(minutes * 60))
    }

    private func history(until end: Date = referenceNow, skip: (Date) -> Bool = { _ in false },
                         value: (Date) -> Double? = { _ in nil }) -> [GlucoseReading] {
        var out: [GlucoseReading] = []
        var t = referenceNow.addingTimeInterval(-30 * 86_400 + 300)
        while t <= end {
            if !skip(t) { out.append(reading(t, value(t) ?? 120)) }
            t = t.addingTimeInterval(300)
        }
        return out
    }

    private func compute(_ readings: [GlucoseReading], period: OvernightSummary.Period = .fortnight) -> OvernightSummary? {
        OvernightSummary.compute(readings: readings, low: 70, high: 180, period: period, calendar: utc)
    }

    /// Minutes since that day's midnight UTC.
    private func minuteOfDay(_ t: Date) -> Int { Int(t.timeIntervalSince(utc.startOfDay(for: t)) / 60) }
    private func daysAgo(_ t: Date) -> Int {
        Int((utc.startOfDay(for: referenceNow).timeIntervalSince(utc.startOfDay(for: t)) / 86_400).rounded())
    }

    func testSteadyNights() throws {
        let s = try XCTUnwrap(compute(history()))
        // Midnight 13 days ago through this morning: 14 whole nights inside the 14 days.
        XCTAssertEqual(s.count, 14)
        XCTAssertEqual(s.nights.first?.start, at(13))
        XCTAssertEqual(s.timeInRange, 1)
        XCTAssertEqual(s.timeBelow, 0)
        XCTAssertEqual(s.lows, 0)
        XCTAssertEqual(s.averageChangeMgdl, 0)
        XCTAssertEqual(s.rose, 0)
        XCTAssertEqual(s.fell, 0)
        XCTAssertEqual(OvernightSummaryText.headline(s), "100% in range overnight, over 14 nights.")
        XCTAssertNil(OvernightSummaryText.lowsCaption(s))
        XCTAssertNil(OvernightSummaryText.rangeCaption(s))
        XCTAssertNil(OvernightSummaryText.movementLine(s, unit: .mgdl))
        XCTAssertEqual(OvernightSummaryText.changeValue(s.averageChangeMgdl, unit: .mgdl), "+0")
        XCTAssertEqual(OvernightSummaryText.footnote(s, lowLine: "70 mg/dL"),
                       "Counts nights with readings for at least half of midnight to 6 am. A low is 15 minutes or more below 70 mg/dL. Change is the last half hour against the first. Observations, not advice.")
        XCTAssertEqual(OvernightSummaryText.spoken(s, lowLine: "70 mg/dL", unit: .mgdl),
                       "Overnight, midnight to 6 am, the last 14 days. 100 percent in range over 14 nights. No lows. Usually steady across the night.")
    }

    func testRisingNightsGiveTheAverageChange() throws {
        // Two nights climb steadily from 120 at midnight to just under 180 by 6 am.
        let s = try XCTUnwrap(compute(history { t in
            let m = self.minuteOfDay(t)
            return [1, 2].contains(self.daysAgo(t)) && m < 360 ? 120 + Double(m) / 6 : nil
        }))
        XCTAssertEqual(s.count, 14)
        // Last half hour (5:30 to 6) averages 177.1, the first 122.1: 55 up on each.
        XCTAssertEqual(try XCTUnwrap(s.nights.last(where: { $0.changeMgdl != 0 })?.changeMgdl), 55, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(s.averageChangeMgdl), 110.0 / 14, accuracy: 0.001)
        XCTAssertEqual(s.rose, 2)
        XCTAssertEqual(s.fell, 0)
        XCTAssertEqual(s.timeInRange, 1)
        XCTAssertEqual(OvernightSummaryText.changeValue(s.averageChangeMgdl, unit: .mgdl), "+8")
        XCTAssertEqual(OvernightSummaryText.movementLine(s, unit: .mgdl), "Rose more than 18 mg/dL on 2 of 14 nights.")
        XCTAssertEqual(OvernightSummaryText.spoken(s, lowLine: "70 mg/dL", unit: .mgdl),
                       "Overnight, midnight to 6 am, the last 14 days. 100 percent in range over 14 nights. No lows. On average rose 8 mg/dL across the night. Rose more than 18 mg/dL on 2 of 14 nights.")
    }

    func testRisesAndFallsTogether() throws {
        let s = try XCTUnwrap(compute(history { t in
            let m = self.minuteOfDay(t)
            guard m < 360 else { return nil }
            switch self.daysAgo(t) {
            case 1: return 120 + Double(m) / 6
            case 4: return 170 - Double(m) / 6
            default: return nil
            }
        }))
        XCTAssertEqual(s.rose, 1)
        XCTAssertEqual(s.fell, 1)
        XCTAssertEqual(try XCTUnwrap(s.averageChangeMgdl), 0, accuracy: 0.001)
        XCTAssertEqual(OvernightSummaryText.movementLine(s, unit: .mgdl),
                       "Rose more than 18 mg/dL on 1 of 14 nights and fell as much on 1.")
    }

    func testOnlyLowsThatStartOvernightCount() throws {
        let s = try XCTUnwrap(compute(history { t in
            let m = self.minuteOfDay(t)
            switch (self.daysAgo(t), m) {
            case (3, 120..<150), (3, 240..<260): return 55   // 2 am for 30 min, 4 am for 20 min
            case (4, 900..<960): return 55                   // 3 pm: not overnight
            default: return nil
            }
        }))
        XCTAssertEqual(s.lows, 2)
        XCTAssertEqual(s.nightsWithLows, 1)
        XCTAssertEqual(s.nights.first(where: { $0.lows > 0 })?.start, at(3))
        // 6 + 4 of the 14 × 72 night buckets were low.
        XCTAssertEqual(s.timeBelow, 10.0 / 1_008, accuracy: 0.000_001)
        XCTAssertEqual(s.timeInRange, 998.0 / 1_008, accuracy: 0.000_001)
        XCTAssertEqual(OvernightSummaryText.lowsCaption(s), "On 1 night")
        XCTAssertEqual(OvernightSummaryText.rangeCaption(s), "1% below")
        XCTAssertEqual(OvernightSummaryText.headline(s), "99% in range overnight, over 14 nights.")
        XCTAssertEqual(OvernightSummaryText.spoken(s, lowLine: "70 mg/dL", unit: .mgdl),
                       "Overnight, midnight to 6 am, the last 14 days. 99 percent in range over 14 nights. 1 percent below 70 mg/dL. 2 lows on 1 night. Usually steady across the night.")
    }

    func testANightWithoutReadingsIsLeftOut() throws {
        // Nothing from 11 pm five nights ago to 4 am: under half the night has readings.
        let s = try XCTUnwrap(compute(history(skip: { t in
            t >= self.at(5, -60) && t < self.at(5, 240)
        })))
        XCTAssertEqual(s.count, 13)
        XCTAssertFalse(s.nights.contains { $0.start == at(5) })
        XCTAssertTrue(OvernightSummaryText.footnote(s, lowLine: "70 mg/dL").hasSuffix("Based on 13 nights with readings. Observations, not advice."))
    }

    func testANightStillUnderWayIsntCounted() throws {
        // The newest reading is 3 am today: tonight isn't over yet.
        let s = try XCTUnwrap(compute(history(until: at(0, 180))))
        XCTAssertEqual(s.count, 13)
        XCTAssertEqual(s.nights.last?.start, at(1))
    }

    func testNeedsThreeNights() {
        let recent = history().filter { $0.timestamp > referenceNow.addingTimeInterval(-2 * 86_400) }
        XCTAssertNil(compute(recent))
        XCTAssertNil(compute([]))
    }

    func testPeriodsCountTheirOwnNights() throws {
        XCTAssertEqual(try XCTUnwrap(compute(history(), period: .week)).count, 7)
        // 30 days of readings start just after 2 pm 30 days ago, so the first whole night is 29 days ago.
        XCTAssertEqual(try XCTUnwrap(compute(history(), period: .month)).count, 30)
    }

    func testIsOvernight() {
        XCTAssertTrue(OvernightSummary.isOvernight(at(0), calendar: utc))
        XCTAssertTrue(OvernightSummary.isOvernight(at(0, 359), calendar: utc))
        XCTAssertFalse(OvernightSummary.isOvernight(at(0, 360), calendar: utc))
        XCTAssertFalse(OvernightSummary.isOvernight(at(1, 23 * 60 + 59), calendar: utc))
    }

    func testCacheKeyMovesWithTheLines() {
        let r = history()
        let a = OvernightSummaryCache.key(readings: r, low: 70, high: 180, period: .fortnight)
        XCTAssertEqual(a, OvernightSummaryCache.key(readings: r, low: 70, high: 180, period: .fortnight))
        XCTAssertNotEqual(a, OvernightSummaryCache.key(readings: r, low: 72, high: 180, period: .fortnight))
        XCTAssertNotEqual(a, OvernightSummaryCache.key(readings: r, low: 70, high: 200, period: .fortnight))
        XCTAssertNotEqual(a, OvernightSummaryCache.key(readings: r, low: 70, high: 180, period: .week))
    }
}

// MARK: - The Logbook's Overnight chip

extension OvernightSummaryTests {
    func testTheOvernightChipHoldsWhatWasLoggedOvernight() {
        let cal = Calendar.autoupdatingCurrent
        let threeAM = cal.date(bySettingHour: 3, minute: 0, second: 0, of: referenceNow)!
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: referenceNow)!
        let night = LogEntry.meal(MealEntry(timestamp: threeAM, carbs: 15, food: "Jelly beans", note: ""))
        let day = LogEntry.meal(MealEntry(timestamp: noon, carbs: 60, food: "Sandwich", note: ""))
        XCTAssertTrue(LogbookFilter.overnight.matches(night, lowIDs: []))
        XCTAssertFalse(LogbookFilter.overnight.matches(day, lowIDs: []))
        let rows = AlertLog.rows([AlertRecord(kind: .low, firedAt: threeAM),
                                  AlertRecord(kind: .high, firedAt: noon)])
        XCTAssertEqual(rows.filter(LogbookFilter.overnight.matches).map(\.timestamp), [threeAM])
        // A time of day, not a kind of entry: it's only in the chip bar when the card opens on it.
        XCTAssertFalse(LogbookFilter.overnight.isListed)
        XCTAssertFalse(LogbookFilter.available(entries: [night], alerts: rows).contains(.overnight))
        XCTAssertEqual(LogbookFilter.overnight.title, "Overnight")
    }

    func testTheOvernightLinkCoversTheCardsDays() {
        let now = referenceNow
        let newest = now.addingTimeInterval(-10 * 60)
        for period in OvernightSummary.Period.allCases {
            let link = LogbookLink.overnight(period, newestReading: newest, now: now)
            XCTAssertEqual(link.filter, .overnight)
            XCTAssertEqual(link.period, LogbookLink.lows(period, newestReading: newest, now: now).period)
        }
        XCTAssertEqual(LogbookLink.overnight(.week, newestReading: now, now: now).sourceID, "logbook-overnight")
        XCTAssertNotEqual(LogbookLink.overnight(.week, newestReading: now, now: now).sourceID,
                          LogbookLink.highs(.week, newestReading: now, now: now).sourceID)
    }
}
