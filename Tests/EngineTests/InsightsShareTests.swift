import XCTest
@testable import GlucOSEngine

/// The footer on a shared Insights card picture (`InsightsShare`, docs/InsightsShare.md).
final class InsightsShareTests: XCTestCase {
    private let locale = Locale(identifier: "en_AU")
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Perth")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func defaults() -> UserDefaults {
        let name = "InsightsShareTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testFooterNamesCardPeriodAndDates() {
        let now = date(2026, 11, 17)
        let text = InsightsShare.footer(card: .lows, period: .days(14), now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(text, "Lows · Last 14 days · 3–17 Nov 2026")
    }

    func testFooterAcrossMonthsAndYears() {
        XCTAssertEqual(InsightsShare.footer(card: .highs, period: .days(30), now: date(2026, 11, 17),
                                            calendar: calendar, locale: locale),
                       "Highs · Last 30 days · 18 Oct – 17 Nov 2026")
        XCTAssertEqual(InsightsShare.footer(card: .overnight, period: .days(14), now: date(2027, 1, 5),
                                            calendar: calendar, locale: locale),
                       "Overnight · Last 14 days · 22 Dec 2026 – 5 Jan 2027")
    }

    func testFooterForHoursWeeksAndEverything() {
        let now = date(2026, 11, 17, 9)
        XCTAssertEqual(InsightsShare.footer(card: .glance, period: .hours(24), now: now, calendar: calendar, locale: locale),
                       "At a glance · Last 24 hours · 16–17 Nov 2026")
        XCTAssertEqual(InsightsShare.footer(card: .weekInReview, period: .twoWeeks, now: now, calendar: calendar, locale: locale),
                       "Week in review · This week and last week · 3–17 Nov 2026")
        XCTAssertEqual(InsightsShare.footer(card: .mornings, period: .allStored(since: date(2026, 9, 1)), now: now,
                                            calendar: calendar, locale: locale),
                       "Mornings · All readings kept · 1 Sept – 17 Nov 2026".replacingOccurrences(
                           of: "Sept", with: shortMonth(9)))
        // Nothing stored yet: no dates to give.
        XCTAssertEqual(InsightsShare.footer(card: .mornings, period: .allStored(since: nil), now: now,
                                            calendar: calendar, locale: locale),
                       "Mornings · All readings kept")
    }

    func testOneDayRangeIsASingleDate() {
        let now = date(2026, 11, 17, 20)
        XCTAssertEqual(InsightsShare.dateRange(from: date(2026, 11, 17, 2), to: now, calendar: calendar, locale: locale),
                       "17 Nov 2026")
    }

    func testFooterNeverCarriesMoreThanCardPeriodAndDates() {
        let now = date(2026, 11, 17)
        for card in InsightsCard.allCases {
            let text = InsightsShare.footer(card: card, period: .days(7), now: now, calendar: calendar, locale: locale)
            let parts = text.components(separatedBy: " · ")
            XCTAssertEqual(parts, [card.title, "Last 7 days", "10–17 Nov 2026"], "\(card)")
            XCTAssertFalse(text.contains("@"))
        }
        XCTAssertEqual(InsightsShare.credit, "Shared from GlucOS")
    }

    func testPeriodFollowsEachCardsPicker() {
        let d = defaults()
        // Never changed: each card's own default.
        XCTAssertEqual(InsightsShare.period(for: .lows, defaults: d, firstReading: nil), .days(14))
        XCTAssertEqual(InsightsShare.period(for: .glance, defaults: d, firstReading: nil), .hours(24))
        XCTAssertEqual(InsightsShare.period(for: .dayPattern, defaults: d, firstReading: nil), .days(14))
        d.set(7, forKey: InsightsShare.Key.lows)
        d.set(30, forKey: InsightsShare.Key.dayPattern)
        d.set(168, forKey: InsightsShare.Key.glanceHours)
        XCTAssertEqual(InsightsShare.period(for: .lows, defaults: d, firstReading: nil), .days(7))
        XCTAssertEqual(InsightsShare.period(for: .dayPattern, defaults: d, firstReading: nil), .days(30))
        XCTAssertEqual(InsightsShare.period(for: .glance, defaults: d, firstReading: nil), .days(7))
        // Fixed spans.
        XCTAssertEqual(InsightsShare.period(for: .days, defaults: d, firstReading: nil), .days(7))
        XCTAssertEqual(InsightsShare.period(for: .weekInReview, defaults: d, firstReading: nil), .twoWeeks)
        XCTAssertEqual(InsightsShare.period(for: .forecastAccuracy, defaults: d, firstReading: nil), .days(7))
        let first = date(2026, 10, 1)
        XCTAssertEqual(InsightsShare.period(for: .mornings, defaults: d, firstReading: first), .allStored(since: first))
    }

    func testFileName() {
        XCTAssertEqual(InsightsShare.fileName(card: .bestDays, now: date(2026, 11, 17), calendar: calendar, locale: locale),
                       "GlucOS Best and toughest days 17 Nov 2026.png")
    }

    /// The short month name in this locale (Foundation versions differ on "Sep" and "Sept").
    private func shortMonth(_ m: Int) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "MMM"
        return f.string(from: date(2026, m, 1))
    }

    // MARK: Rendering inputs and the lift

    func testRenderWidthPerPlatform() {
        XCTAssertEqual(InsightsShare.renderWidth(phone: true), 390)
        XCTAssertEqual(InsightsShare.renderWidth(phone: false), 560)
    }

    func testRenderScaleIsAtLeastTwoAndAtMostThree() {
        XCTAssertEqual(InsightsShare.renderScale(displayScale: 1), 2)
        XCTAssertEqual(InsightsShare.renderScale(displayScale: 2), 2)
        XCTAssertEqual(InsightsShare.renderScale(displayScale: 3), 3)
        XCTAssertEqual(InsightsShare.renderScale(displayScale: 4), 3)
        XCTAssertEqual(InsightsShare.renderScale(displayScale: 0), 2)
        XCTAssertEqual(InsightsShare.renderScale(displayScale: .nan), 2)
    }

    func testLiftRaisesTheCardAndRestsWhenDone() {
        let up = InsightsShareLift.style(lifted: true, reduceMotion: false)
        XCTAssertGreaterThan(up.scale, 1)
        XCTAssertLessThanOrEqual(up.scale, 1.03, "a slight lift, not a zoom")
        XCTAssertTrue(up.raised)
        XCTAssertEqual(up.outline, 0)
        XCTAssertEqual(InsightsShareLift.style(lifted: false, reduceMotion: false), .rest)
        XCTAssertEqual(InsightsShareLift.style(lifted: false, reduceMotion: true), .rest)
    }

    func testReduceMotionFadesAnOutlineAndMovesNothing() {
        let style = InsightsShareLift.style(lifted: true, reduceMotion: true)
        XCTAssertEqual(style.scale, 1)
        XCTAssertFalse(style.raised)
        XCTAssertGreaterThan(style.outline, 0)
        XCTAssertLessThan(InsightsShareLift.presentDelay(reduceMotion: true),
                          InsightsShareLift.presentDelay(reduceMotion: false))
        XCTAssertLessThan(InsightsShareLift.presentDelay(reduceMotion: false), 0.3, "the sheet never waits long")
    }
}
