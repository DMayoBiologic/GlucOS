import XCTest
@testable import GlucOSEngine

final class DayCompareTests: XCTestCase {
    private var sydney: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return c
    }

    private var today: Date { utc.startOfDay(for: referenceNow) }
    private func daysAgo(_ n: Int) -> Date { today.addingTimeInterval(-Double(n) * 86_400) }

    private func every(_ step: Int, from start: Date, to end: Date, _ mgdl: (Date) -> Double = { _ in 120 }) -> [GlucoseReading] {
        stride(from: start.timeIntervalSince1970, to: end.timeIntervalSince1970, by: Double(step) * 60)
            .map { let d = Date(timeIntervalSince1970: $0); return reading(d, mgdl(d)) }
    }

    // MARK: Time of day

    func testMinuteOfDayIsWallClock() {
        XCTAssertEqual(DayCompare.minuteOfDay(today, calendar: utc), 0)
        XCTAssertEqual(DayCompare.minuteOfDay(today.addingTimeInterval(18 * 3600 + 90), calendar: utc), 1_081.5)
    }

    func testOverlaySpansMidnightToMidnight() {
        let day = daysAgo(2)
        let r = every(5, from: day, to: day.addingTimeInterval(86_400))
        let runs = DayCompare.overlay(DayChart.segments(r, from: day, to: day.addingTimeInterval(86_400)), calendar: utc)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].first?.minute, 0)
        XCTAssertEqual(runs[0].last?.minute, 1_435)
        XCTAssertEqual(runs[0].count, 288)
    }

    func testGapStillBreaksTheLine() {
        let day = daysAgo(2)
        let r = every(5, from: day, to: day.addingTimeInterval(3 * 3600))
            + every(5, from: day.addingTimeInterval(5 * 3600), to: day.addingTimeInterval(8 * 3600))
        let runs = DayCompare.overlay(DayChart.segments(r, from: day, to: day.addingTimeInterval(86_400)), calendar: utc)
        XCTAssertEqual(runs.count, 2)
    }

    // MARK: Clock changes (Sydney)

    func testSpringForwardSkipsTheMissingHour() throws {
        let cal = sydney
        let start = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 10, day: 4)))
        let end = DayChart.end(of: start, calendar: cal)
        XCTAssertEqual(end.timeIntervalSince(start), 23 * 3600)
        let r = every(5, from: start, to: end)
        let runs = DayCompare.overlay(DayChart.segments(r, from: start, to: end), calendar: cal)
        let minutes = runs.joined().map(\.minute)
        XCTAssertEqual(minutes.count, 276)
        XCTAssertFalse(minutes.contains { $0 >= 120 && $0 < 180 }, "2–3 am never happened")
        XCTAssertEqual(runs.count, 2, "the line breaks across the skipped hour")
        XCTAssertTrue(minutes.allSatisfy { $0 >= 0 && $0 < 1_440 })
        // 6 pm sits at 6 pm, not an hour off.
        XCTAssertTrue(minutes.contains(1_080))
    }

    func testFallBackDrawsTheRepeatedHourAsItsOwnRun() throws {
        let cal = sydney
        let start = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 4, day: 5)))
        let end = DayChart.end(of: start, calendar: cal)
        XCTAssertEqual(end.timeIntervalSince(start), 25 * 3600)
        let r = every(5, from: start, to: end)
        let runs = DayCompare.overlay(DayChart.segments(r, from: start, to: end), calendar: cal)
        XCTAssertEqual(runs.joined().count, 300)
        XCTAssertEqual(runs.count, 2)
        for run in runs {
            XCTAssertTrue(zip(run, run.dropFirst()).allSatisfy { $0.minute < $1.minute }, "no run doubles back")
        }
        XCTAssertTrue(runs.joined().allSatisfy { $0.minute >= 0 && $0.minute < 1_440 })
    }

    func testClockChangeDayFiguresUseTheWholeDay() throws {
        let cal = sydney
        let start = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 4, day: 5)))
        let r = every(5, from: start, to: DayChart.end(of: start, calendar: cal))
        let d = DayCompare.day(start.addingTimeInterval(12 * 3600), readings: r, low: 70, high: 180,
                               now: start.addingTimeInterval(40 * 86_400), calendar: cal)
        XCTAssertEqual(d.start, start)
        XCTAssertEqual(try XCTUnwrap(d.inRange).inRange, 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(d.averageMgdl), 120, accuracy: 1e-9)
    }

    // MARK: Figures

    func testSteadyDay() throws {
        let day = daysAgo(2)
        let d = DayCompare.day(day, readings: every(5, from: day, to: day.addingTimeInterval(86_400)),
                               low: 70, high: 180, now: referenceNow, calendar: utc)
        XCTAssertTrue(d.hasReadings)
        XCTAssertEqual(try XCTUnwrap(d.inRange).inRange, 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(d.averageMgdl), 120, accuracy: 1e-9)
        XCTAssertEqual(d.lows, 0)
        XCTAssertEqual(d.highs, 0)
    }

    func testCountsLowsAndHighs() {
        let day = daysAgo(2)
        let lowAt = day.addingTimeInterval(4 * 3600), highAt = day.addingTimeInterval(14 * 3600)
        let r = every(5, from: day, to: day.addingTimeInterval(86_400)) { t in
            if t >= lowAt && t < lowAt.addingTimeInterval(30 * 60) { return 60 }
            if t >= highAt && t < highAt.addingTimeInterval(30 * 60) { return 250 }
            return 120
        }
        let d = DayCompare.day(day, readings: r, low: 70, high: 180, now: referenceNow, calendar: utc)
        XCTAssertEqual(d.lows, 1)
        XCTAssertEqual(d.highs, 1)
    }

    func testOnlyTheDaysOwnReadings() throws {
        let day = daysAgo(2)
        let r = every(5, from: day.addingTimeInterval(-86_400), to: day.addingTimeInterval(2 * 86_400)) { t in
            t >= day && t < day.addingTimeInterval(86_400) ? 120 : 300
        }
        let d = DayCompare.day(day, readings: r, low: 70, high: 180, now: referenceNow, calendar: utc)
        XCTAssertEqual(try XCTUnwrap(d.averageMgdl), 120, accuracy: 1e-9)
        XCTAssertEqual(d.highs, 0)
    }

    func testTodayRunsUpToNow() {
        let now = today.addingTimeInterval(3 * 3600)
        let r = every(5, from: today, to: today.addingTimeInterval(86_400))
        let d = DayCompare.day(today, readings: r, low: 70, high: 180, now: now, calendar: utc)
        XCTAssertEqual(d.runs.joined().count, 36)
        XCTAssertNotNil(d.inRange)
    }

    func testEmptyDay() {
        let d = DayCompare.day(daysAgo(3), readings: [], low: 70, high: 180, now: referenceNow, calendar: utc)
        XCTAssertFalse(d.hasReadings)
        XCTAssertNil(d.inRange)
        XCTAssertNil(d.averageMgdl)
    }

    // MARK: Picking days

    func testReadingDaysNeedEnoughReadings() {
        let full = daysAgo(3), sparse = daysAgo(2)
        let r = every(5, from: full, to: full.addingTimeInterval(86_400))
            + every(5, from: sparse, to: sparse.addingTimeInterval(25 * 60))
        let days = DayCompare.readingDays(r.shuffled(), calendar: utc)
        XCTAssertEqual(days, [full: 288])
    }

    func testReadingDaysAcrossAClockChange() throws {
        let cal = sydney
        let start = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 4, day: 5)))
        let r = every(5, from: start, to: DayChart.end(of: start, calendar: cal).addingTimeInterval(3600))
        let days = DayCompare.readingDays(r, calendar: cal)
        XCTAssertEqual(days[start], 300)
        // An hour of 5-minute readings is the floor, and lands on the next day by its own midnight.
        XCTAssertEqual(days[DayChart.end(of: start, calendar: cal)], 12)
    }

    func testSteppingSkipsTheFirstDayAndStopsAtToday() {
        let days: Set<Date> = [daysAgo(5), daysAgo(4), daysAgo(2), daysAgo(1), today]
        let step = { (second: Date, by: Int) in
            DayCompare.stepped(second, by: by, first: self.daysAgo(1), days: days, now: referenceNow, calendar: utc)
        }
        XCTAssertEqual(step(daysAgo(2), 1), today, "skips the day it was opened from")
        XCTAssertNil(step(today, 1), "never past today")
        XCTAssertEqual(step(daysAgo(2), -1), daysAgo(4), "skips a day with no readings")
        XCTAssertEqual(step(daysAgo(4), -1), daysAgo(5))
        XCTAssertNil(step(daysAgo(5), -1))
        XCTAssertNil(step(daysAgo(5), 0))
    }

    func testPairIDNamesBothDays() {
        let a = DayComparePair(first: daysAgo(1), second: daysAgo(2), days: [])
        let b = DayComparePair(first: daysAgo(1), second: daysAgo(3), days: [])
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: Words

    private func sample(inRange: DayInRange? = DayInRange(below: 0.04, inRange: 0.78, above: 0.18),
                        average: Double? = 129.7, lows: Int = 1, highs: Int = 2, empty: Bool = false) -> DayCompareDay {
        DayCompareDay(start: today, runs: empty ? [] : [[DayComparePoint(minute: 0, mgdl: 120)]],
                      inRange: inRange, averageMgdl: empty ? nil : average, lows: lows, highs: highs)
    }

    func testSpokenSummaryPerDay() {
        XCTAssertEqual(DayCompareText.spoken(sample(), spokenDay: "Today", unit: .mmol),
                       "Today: 78% in range, average 7.2 mmol/L, 1 low, 2 highs.")
        XCTAssertEqual(DayCompareText.spoken(sample(inRange: nil, average: 120, lows: 0, highs: 0), spokenDay: "Today", unit: .mgdl),
                       "Today: too few readings for time in range, average 120 mg/dL, no lows, no highs.")
        XCTAssertEqual(DayCompareText.spoken(sample(empty: true), spokenDay: "Monday 11 November", unit: .mmol),
                       "Monday 11 November: no readings.")
    }

    func testFiguresOnScreen() {
        XCTAssertEqual(DayCompareText.inRange(sample()), "78%")
        XCTAssertEqual(DayCompareText.average(sample(), unit: .mmol), "7.2")
        XCTAssertEqual(DayCompareText.average(sample(empty: true), unit: .mmol), "–")
        XCTAssertEqual(DayCompareText.inRange(sample(inRange: nil)), "–")
    }

    func testChartAndAnnouncementWords() {
        XCTAssertEqual(DayCompareText.chartSpoken(first: "Today", second: "Monday 11 November", unit: .mmol, low: 70, high: 180),
                       "Chart of Today and Monday 11 November, overlaid by time of day, midnight to midnight. Target 3.9 to 10.0.")
        XCTAssertEqual(DayCompareText.announcement(first: "Today", second: "Yesterday"), "Comparing Today with Yesterday.")
        XCTAssertEqual(DayCompare.tickMinutes.map(DayCompareText.tick), ["midnight", "6 am", "noon", "6 pm", "midnight"])
    }

    /// Shows what happened on each day: never which was better, nor what to change.
    func testNoAdviceWords() {
        let words = ["better", "worse", "should", "dose", "insulin", "bolus", "try ", "improve", "good", "bad", "doctor"]
        let texts = [
            DayCompareText.spoken(sample(), spokenDay: "Today", unit: .mmol),
            DayCompareText.spoken(sample(inRange: nil), spokenDay: "Today", unit: .mgdl),
            DayCompareText.spoken(sample(empty: true), spokenDay: "Today", unit: .mmol),
            DayCompareText.chartSpoken(first: "Today", second: "Yesterday", unit: .mmol, low: 70, high: 180),
            DayCompareText.announcement(first: "Today", second: "Yesterday"),
            DayCompareText.prompt(spokenDay: "Today"),
            DayCompareText.calendarFootnote, DayCompareText.menuName, DayCompareText.title,
        ]
        for text in texts {
            for w in words { XCTAssertFalse(text.lowercased().contains(w), "\"\(text)\" says \"\(w)\"") }
        }
    }
}
