import XCTest
@testable import GlucOSEngine

final class LogbookExportTests: XCTestCase {
    // referenceNow is 14:00 UTC; every test uses the UTC calendar.
    private var today: Date { utc.startOfDay(for: referenceNow) }

    private func day(_ offset: Int) -> Date { utc.date(byAdding: .day, value: offset, to: today)! }

    /// Readings every `step` minutes from `start` up to (not including) `end`.
    private func series(from start: Date, to end: Date, step: Int = 5, value: (Date) -> Double = { _ in 120 }) -> [GlucoseReading] {
        stride(from: start.timeIntervalSince1970, to: end.timeIntervalSince1970, by: Double(step) * 60)
            .map { t in let d = Date(timeIntervalSince1970: t); return reading(d, value(d)) }
    }

    // MARK: Period

    func testLastDaysIncludesToday() {
        let p = LogbookExport.Period.last(14, now: referenceNow, calendar: utc)
        XCTAssertEqual(p.days, 14)
        XCTAssertEqual(p.start, day(-13))
        XCTAssertEqual(p.end, day(1))
        XCTAssertTrue(p.contains(referenceNow))
        XCTAssertFalse(p.contains(day(1)))
        XCTAssertTrue(p.contains(day(-13)))
        XCTAssertFalse(p.contains(day(-13).addingTimeInterval(-1)))
    }

    func testCustomDaysAreOrderedClippedAndCapped() {
        // Backwards and running into the future: read in order, ending today.
        let p = LogbookExport.Period.days(from: day(3), to: day(-2), now: referenceNow, calendar: utc)
        XCTAssertEqual(p.start, day(-2))
        XCTAssertEqual(p.end, day(1))
        XCTAssertEqual(p.days, 3)

        // Longer than the archive keeps: the latest 90 days.
        let long = LogbookExport.Period.days(from: day(-200), to: day(-1), now: referenceNow, calendar: utc)
        XCTAssertEqual(long.days, LogbookExport.maximumDays)
        XCTAssertEqual(long.lastDay(calendar: utc), day(-1))
        XCTAssertEqual(long.start, day(-90))

        let one = LogbookExport.Period.days(from: day(-4).addingTimeInterval(3600), to: day(-4).addingTimeInterval(7200),
                                            now: referenceNow, calendar: utc)
        XCTAssertEqual(one.days, 1)
        XCTAssertEqual(LogbookExport.periodLine(one, calendar: utc).hasSuffix("(1 day)"), true)
    }

    // MARK: Summary

    func testSteadyFortnight() throws {
        let p = LogbookExport.Period.days(from: day(-14), to: day(-1), now: referenceNow, calendar: utc)
        let s = try XCTUnwrap(LogbookExport.summary(readings: series(from: day(-20), to: referenceNow), period: p, low: 70, high: 180))
        XCTAssertEqual(s.timeInRange, 1, accuracy: 0.0001)
        XCTAssertEqual(s.meanMgdl, 120, accuracy: 0.0001)
        XCTAssertEqual(s.sdMgdl, 0, accuracy: 0.0001)
        XCTAssertEqual(s.lows, 0)
        XCTAssertEqual(s.coverage, 1, accuracy: 0.0001)
        XCTAssertEqual(s.daysWithReadings, 14)
        XCTAssertEqual(s.readings, 14 * 288)
        XCTAssertEqual(s.gmiPercent, 3.31 + 0.02392 * 120, accuracy: 0.0001)
    }

    func testBandsLowsAndCoverage() throws {
        // One day: 40 minutes at 50 (very low) from 3 am, an hour at 300 (very high) from 6 pm, the
        // rest 120, and readings only for the first half of the day after noon is skipped.
        let p = LogbookExport.Period.days(from: day(-1), to: day(-1), now: referenceNow, calendar: utc)
        let start = day(-1)
        let readings = series(from: start, to: day(0)) { d in
            let m = d.timeIntervalSince(start) / 60
            if m >= 180 && m < 220 { return 50 }
            if m >= 18 * 60 && m < 19 * 60 { return 300 }
            return 120
        }.filter { r in
            let m = r.timestamp.timeIntervalSince(start) / 60
            return m < 12 * 60 || m >= 18 * 60
        }
        let s = try XCTUnwrap(LogbookExport.summary(readings: readings, period: p, low: 70, high: 180))
        XCTAssertEqual(s.lows, 1)
        XCTAssertEqual(s.buckets, 18 * 12)
        XCTAssertEqual(s.veryLow, 8.0 / 216, accuracy: 0.0001)
        XCTAssertEqual(s.below, s.veryLow, accuracy: 0.0001)
        XCTAssertEqual(s.veryHigh, 12.0 / 216, accuracy: 0.0001)
        XCTAssertEqual(s.above, s.veryHigh, accuracy: 0.0001)
        XCTAssertEqual(s.timeInRange + s.below + s.above, 1, accuracy: 0.0001)
        XCTAssertEqual(s.coverage, 0.75, accuracy: 0.0001)
    }

    func testNoReadingsInPeriod() {
        let p = LogbookExport.Period.days(from: day(-30), to: day(-20), now: referenceNow, calendar: utc)
        XCTAssertNil(LogbookExport.summary(readings: series(from: day(-5), to: referenceNow), period: p, low: 70, high: 180))
    }

    func testReportHasUsualDayOnlyWithEnoughDays() {
        let readings = series(from: day(-20), to: referenceNow)
        let fortnight = LogbookExport.Period.days(from: day(-14), to: day(-1), now: referenceNow, calendar: utc)
        let r = LogbookExport.report(readings: readings, entries: [], period: fortnight, unit: .mmol, low: 70, high: 180,
                                     now: referenceNow, calendar: utc)
        XCTAssertEqual(r.pattern?.days, 14)
        XCTAssertEqual(r.pattern?.filled.count, 48)
        let short = LogbookExport.Period.days(from: day(-3), to: day(-1), now: referenceNow, calendar: utc)
        XCTAssertNil(LogbookExport.report(readings: readings, entries: [], period: short, unit: .mmol, low: 70, high: 180,
                                          now: referenceNow, calendar: utc).pattern)
    }

    // MARK: Entries

    private var sample: [LogEntry] {
        let t = day(-2)
        return [
            .dose(InsulinDose(timestamp: t.addingTimeInterval(8 * 3600), units: 4.5, kind: .rapid, name: "NovoRapid",
                              site: .abdomenLeft, note: "before breakfast", purpose: .meal)),
            .meal(MealEntry(timestamp: t.addingTimeInterval(8 * 3600 + 60), carbs: 45, food: "Toast, jam", note: "")),
            .context(ContextEvent(timestamp: t.addingTimeInterval(15 * 3600), tags: [.hypoTreatment], note: "=3 jelly beans")),
            .siteChange(SiteChange(timestamp: t.addingTimeInterval(20 * 3600), site: .thighRight)),
            .context(ContextEvent(timestamp: t.addingTimeInterval(6 * 3600), tags: [.wokeUp])),
            // Outside the period.
            .meal(MealEntry(timestamp: day(-10), carbs: 30, food: "Old")),
        ]
    }

    func testEntriesOldestFirstWithinPeriod() {
        let p = LogbookExport.Period.days(from: day(-3), to: day(-1), now: referenceNow, calendar: utc)
        let e = LogbookExport.entries(sample, period: p)
        XCTAssertEqual(e.count, 5)
        XCTAssertEqual(e.map(\.timestamp), e.map(\.timestamp).sorted())
        let rows = e.map(LogbookExport.row)
        XCTAssertEqual(rows.map(\.type), ["Woke up", "Insulin", "Food", "Hypo treatment", "Site change"])
        XCTAssertEqual(rows[1].details, "NovoRapid, for a meal")
        XCTAssertEqual(rows[1].insulinUnits, 4.5)
        XCTAssertEqual(rows[1].site, "Abdomen, left")
        XCTAssertEqual(rows[2].carbs, 45)
        XCTAssertEqual(rows[4].site, "Thigh, right")

        let t = LogbookExport.totals(e)
        XCTAssertEqual(t.doses, 1)
        XCTAssertEqual(t.units, 4.5)
        XCTAssertEqual(t.meals, 1)
        XCTAssertEqual(t.carbs, 45)
        XCTAssertEqual(t.siteChanges, 1)
        XCTAssertEqual(t.hypoTreatments, 1)
        XCTAssertEqual(LogbookExport.loggedLines(t, days: 3).first,
                       "Insulin logged: 1 dose, 4.5 u in all (about 1.5 u a day).")
        XCTAssertEqual(LogbookExport.dayTotals(rows), "4.5 u · 45 g carbs")
        XCTAssertEqual(LogbookExport.days(rows, calendar: utc).count, 1)
    }

    func testCSV() {
        let p = LogbookExport.Period.days(from: day(-3), to: day(-1), now: referenceNow, calendar: utc)
        let csv = LogbookExport.csv(entries: sample, period: p, unit: .mmol, calendar: utc)
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertTrue(csv.hasSuffix("\r\n"))
        XCTAssertEqual(lines.first, "Date,Time,Type,Details,Insulin (u),Insulin type,Carbs (g),Site,Glucose (mmol/L),Note")
        XCTAssertEqual(lines.count, 6)
        XCTAssertTrue(lines[2].hasSuffix(",Insulin,\"NovoRapid, for a meal\",4.5,Rapid-acting,,\"Abdomen, left\",,before breakfast"), lines[2])
        XCTAssertTrue(lines[3].contains(",Food,\"Toast, jam\",,,45,"), lines[3])
        // A note that looks like a formula never runs as one.
        XCTAssertTrue(lines[4].hasSuffix(",'=3 jelly beans"), lines[4])
        XCTAssertFalse(csv.contains("Old"))

        let withReadings = LogbookExport.csv(entries: sample, readings: [reading(day(-2).addingTimeInterval(8 * 3600), 180.182)],
                                             period: p, unit: .mmol, calendar: utc)
        let rows = withReadings.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(rows.count, 7)
        // At the same minute the dose comes first, then the reading.
        XCTAssertTrue(rows[2].contains(",Insulin,"))
        XCTAssertTrue(rows[3].hasSuffix(",Glucose,,,,,,10.0,"), rows[3])
    }

    func testCSVField() {
        XCTAssertEqual(LogbookExport.csvField("plain"), "plain")
        XCTAssertEqual(LogbookExport.csvField("a,b"), "\"a,b\"")
        XCTAssertEqual(LogbookExport.csvField("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(LogbookExport.csvField("two\nlines"), "\"two\nlines\"")
        XCTAssertEqual(LogbookExport.csvField("-3"), "-3")
        XCTAssertEqual(LogbookExport.csvField("+SUM(A1)"), "'+SUM(A1)")
        XCTAssertEqual(LogFormat.plain(4.5), "4.5")
        XCTAssertEqual(LogFormat.plain(45), "45")
        XCTAssertEqual(LogFormat.plain(0.35), "0.35")
    }

    func testWords() {
        let p = LogbookExport.Period.days(from: day(-13), to: day(0), now: referenceNow, calendar: utc)
        let f = LogbookExport.dateFormatter("yyyy-MM-dd", calendar: utc)
        XCTAssertEqual(LogbookExport.fileName(p, format: .pdf, calendar: utc),
                       "GlucOS Logbook \(f.string(from: day(-13))) to \(f.string(from: day(0))).pdf")
        XCTAssertTrue(LogbookExport.periodLine(p, calendar: utc).hasSuffix("(14 days)"))
        XCTAssertEqual(LogbookExport.lowsValue(0), "None")
        XCTAssertEqual(LogbookExport.loggedLines(LogbookExport.totals([]), days: 14), ["Nothing was logged in these days."])
    }
}
