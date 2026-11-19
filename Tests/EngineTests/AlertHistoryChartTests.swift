import XCTest
@testable import GlucOSEngine

/// An Alert History row opened into its chart (docs/AlertHistory.md, "Chart in a row").
final class AlertHistoryChartTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Perth")!
        return c
    }()

    private let locale = Locale(identifier: "en_AU")

    /// Wed 18 Nov 2026, 3 pm in Perth.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 15))!
    }

    private func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    private func item(_ minutes: Double, mgdl: Double? = 60, id: UUID = UUID()) -> AlertHistory.Item {
        AlertHistory.Item(id: id, kind: .low, firedAt: at(minutes), readingMgdl: mgdl,
                          outcome: .noResponse, respondedAt: nil)
    }

    private func readings(from start: Double, to end: Double, every step: Double = 5,
                          mgdl: (Double) -> Double) -> [GlucoseReading] {
        stride(from: start, through: end, by: step).map {
            GlucoseReading(timestamp: at($0), mgdl: mgdl($0), trend: .flat)
        }
    }

    // MARK: Window

    func testWindowIsAnHourEitherSide() {
        let i = item(-180)
        let w = AlertHistoryChart.window(for: i)
        XCTAssertEqual(w.start, at(-240))
        XCTAssertEqual(w.end, at(-120))
        XCTAssertEqual(w.duration, 2 * 3600)
        XCTAssertFalse(AlertHistoryChart.isFilling(i, now: now))
    }

    func testTraceStopsAtNowForARecentAlert() {
        let i = item(-20)
        XCTAssertEqual(AlertHistoryChart.traceEnd(for: i, now: now), now)
        XCTAssertTrue(AlertHistoryChart.isFilling(i, now: now))
        // The window itself stays two hours, so the line doesn't stretch to fill it.
        XCTAssertEqual(AlertHistoryChart.window(for: i).end, at(40))
    }

    func testSegmentsKeepOnlyTheWindow() {
        let i = item(-180)
        let all = readings(from: -300, to: 0) { _ in 100 }
        let points = AlertHistoryChart.segments(all, for: i, now: now).joined()
        XCTAssertFalse(points.isEmpty)
        XCTAssertTrue(points.allSatisfy { $0.date >= at(-240) && $0.date < at(-120) })
    }

    func testSegmentsBreakAtAGap() {
        let i = item(-180)
        let all = readings(from: -240, to: -200) { _ in 100 } + readings(from: -160, to: -120) { _ in 120 }
        XCTAssertEqual(AlertHistoryChart.segments(all, for: i, now: now).count, 2)
    }

    func testLoggedTimesInsideTheWindowOnly() {
        let i = item(-30)
        XCTAssertTrue(AlertHistoryChart.contains(at(-90), for: i, now: now))
        XCTAssertTrue(AlertHistoryChart.contains(at(-5), for: i, now: now))
        XCTAssertFalse(AlertHistoryChart.contains(at(-91), for: i, now: now))
        // Nothing after now, even though the window runs on.
        XCTAssertFalse(AlertHistoryChart.contains(at(10), for: i, now: now))
    }

    // MARK: Open row

    func testOneRowOpenAtATime() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(AlertHistoryChart.toggled(open: nil, tapped: a), a)
        XCTAssertNil(AlertHistoryChart.toggled(open: a, tapped: a))
        XCTAssertEqual(AlertHistoryChart.toggled(open: a, tapped: b), b)
    }

    func testOpenRowClosesWhenNoLongerListed() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(AlertHistoryChart.stillOpen(a, among: [a, b]), a)
        XCTAssertNil(AlertHistoryChart.stillOpen(a, among: [b]))
        XCTAssertNil(AlertHistoryChart.stillOpen(nil, among: [a]))
    }

    // MARK: Words

    func testSpokenSummaryForAPastAlert() {
        let i = item(-180)
        let all = readings(from: -240, to: -125) { m in m == -175 ? 56 : (m == -130 ? 140 : 100) }
        let segments = AlertHistoryChart.segments(all, for: i, now: now)
        let text = AlertHistoryChartText.spoken(i, segments: segments, logged: 2, unit: .mgdl, now: now,
                                                calendar: calendar, locale: locale)
        XCTAssertTrue(text.hasPrefix("Chart from 11:00"), text)
        XCTAssertTrue(text.contains("to 1:00"), text)
        XCTAssertTrue(text.contains("lowest 56 mg/dL at 12:05"), text)
        XCTAssertTrue(text.contains("highest 140 mg/dL at 12:50"), text)
        XCTAssertTrue(text.hasSuffix("2 entries logged."), text)
        XCTAssertFalse(text.contains("\n"))
    }

    func testSpokenSummarySaysSoFarWhileFilling() {
        let i = item(-20)
        let segments = AlertHistoryChart.segments(readings(from: -80, to: 0) { _ in 90 }, for: i, now: now)
        let text = AlertHistoryChartText.spoken(i, segments: segments, logged: 1, unit: .mgdl, now: now,
                                                calendar: calendar, locale: locale)
        XCTAssertTrue(text.contains("to now"), text)
        XCTAssertTrue(text.contains("so far"), text)
        XCTAssertTrue(text.hasSuffix("1 entry logged."), text)
    }

    func testSpokenSummaryWithNothingStored() {
        let i = item(-180, mgdl: nil)
        let text = AlertHistoryChartText.spoken(i, segments: [], logged: 0, unit: .mmol, now: now,
                                                calendar: calendar, locale: locale)
        XCTAssertTrue(text.contains("no readings stored"), text)
        XCTAssertTrue(text.hasSuffix("nothing logged."), text)
        XCTAssertEqual(AlertHistoryChartText.caption([], unit: .mmol), AlertHistoryChartText.noReadings)
    }

    /// The row's words describe what happened; they never suggest what to do.
    func testWordsStayObservational() {
        let i = item(-180)
        let segments = AlertHistoryChart.segments(readings(from: -240, to: -125) { _ in 60 }, for: i, now: now)
        let all = [AlertHistoryChartText.spoken(i, segments: segments, logged: 3, unit: .mmol, now: now,
                                                calendar: calendar, locale: locale),
                   AlertHistoryChartText.caption(segments, unit: .mmol),
                   AlertHistoryChartText.showHint, AlertHistoryChartText.hideHint,
                   AlertHistoryChartText.openLogbook, AlertHistoryChartText.openLogbookHint]
            .joined(separator: " ").lowercased()
        for word in ["dose", "bolus", "units", "should", "take", "eat"] {
            XCTAssertFalse(all.contains(word), word)
        }
    }
}
