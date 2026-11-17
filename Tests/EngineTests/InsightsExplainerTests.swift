import XCTest
@testable import GlucOSEngine

final class InsightsExplainerTests: XCTestCase {
    private func stats(count: Int = 2016, mean: Double = 150, sd: Double = 45, tir: Double = 0.72,
                       below: Double = 0.03, span: Double = 14 * 24) -> GlucoseStats {
        GlucoseStats(count: count, meanMgdl: mean, minMgdl: 50, maxMgdl: 300, sdMgdl: sd,
                     timeInRange: tir, timeBelowRange: below, timeAboveRange: 1 - tir - below,
                     spanHours: span)
    }

    private func context(_ s: GlucoseStats? = nil, unit: GlucoseUnit = .mmol,
                         period: String = "the last 14 days") -> InsightsExplainer.Context {
        InsightsExplainer.Context(stats: s ?? stats(), unit: unit, lowMgdl: 70, highMgdl: 180, period: period)
    }

    // MARK: Every figure has an explainer

    func testEveryGlanceFigureHasAnExplainer() {
        XCTAssertEqual(Set(InsightsFigure.allCases),
                       [.timeInRange, .average, .gmi, .variability, .lows])
        let all = InsightsExplainer.all(context())
        XCTAssertEqual(all.map(\.figure), InsightsFigure.allCases)
        for e in all {
            XCTAssertFalse(e.title.isEmpty, "\(e.figure) has no title")
            XCTAssertFalse(e.meaning.isEmpty, "\(e.figure) has no meaning")
            XCTAssertFalse(e.workedOut.isEmpty, "\(e.figure) has no worked-out line")
            XCTAssertTrue(e.workedOut.contains("the last 14 days"), "\(e.figure) doesn't name the period")
        }
    }

    func testExplainersAreDistinct() {
        let all = InsightsExplainer.all(context())
        XCTAssertEqual(Set(all.map(\.meaning)).count, all.count)
        XCTAssertEqual(Set(all.map(\.title)).count, all.count)
        XCTAssertEqual(Set(InsightsFigure.allCases.map(\.buttonLabel)).count, InsightsFigure.allCases.count)
    }

    // MARK: Describes the figure, never advises

    func testNoAdviceOrDosingWords() {
        let words = ["dose", "insulin", "bolus", "should", "you must", "take ", "eat ", "doctor", "units of"]
        for unit in GlucoseUnit.allCases {
            for e in InsightsExplainer.all(context(stats(count: 5, span: 3), unit: unit)) {
                let text = e.spoken.lowercased()
                for w in words {
                    XCTAssertFalse(text.contains(w), "\(e.figure) says \"\(w)\"")
                }
            }
        }
    }

    // MARK: Worked out for the period

    func testTimeInRangeQuotesTheRangeAndShare() {
        let e = InsightsExplainer.make(.timeInRange, context())
        XCTAssertEqual(e.workedOut,
                       "Of the 2016 readings over the last 14 days, 72% were between 3.9 mmol/L and 10.0 mmol/L. Readings above or below that count as out of range. You can change the range in Settings.")
        XCTAssertNil(e.note)
    }

    func testAverageInMgdl() {
        let e = InsightsExplainer.make(.average, context(unit: .mgdl))
        XCTAssertTrue(e.workedOut.hasPrefix("All 2016 readings over the last 14 days added together and divided by 2016, which gives 150 mg/dL."))
    }

    func testGMIShowsTheFormulaAndItsResult() {
        let e = InsightsExplainer.make(.gmi, context())
        // 3.31 + 0.02392 × 150 = 6.898
        XCTAssertEqual(e.workedOut,
                       "3.31 + 0.02392 × your average in mg/dL. Over the last 14 days your average was 150 mg/dL, which gives 6.9%.")
        XCTAssertEqual(e.note, "It can differ from a lab A1c, which measures something different over about three months.")
    }

    func testGMIUnderTwoWeeksIsARoughGuide() {
        let e = InsightsExplainer.make(.gmi, context(stats(span: 7 * 24)))
        XCTAssertTrue(e.note?.hasPrefix("Your readings cover less than 14 days") == true)
    }

    func testVariabilityShowsSDOverMean() {
        let e = InsightsExplainer.make(.variability, context(unit: .mgdl))
        XCTAssertTrue(e.workedOut.contains("(45 mg/dL) divided by the average (150 mg/dL), which gives 30%"))
    }

    func testLowsQuotesTheBottomOfRange() {
        let e = InsightsExplainer.make(.lows, context())
        XCTAssertTrue(e.workedOut.hasPrefix("Of the 2016 readings over the last 14 days, 3% were under 3.9 mmol/L."))
        XCTAssertTrue(e.workedOut.contains("3.0 mmol/L"))
    }

    func testFewReadingsAddsANote() {
        let e = InsightsExplainer.make(.average, context(stats(count: 1, span: 0)))
        XCTAssertEqual(e.note, "With only 1 reading so far, this figure may change a lot as more arrive.")
        XCTAssertTrue(e.workedOut.contains("All 1 reading"))
    }

    // MARK: VoiceOver

    func testSpokenReadsEverythingInOrder() {
        let e = InsightsExplainer.make(.gmi, context())
        XCTAssertEqual(e.spoken, [e.title + ".", e.meaning, "How it's worked out.", e.workedOut, e.note!].joined(separator: " "))
        XCTAssertEqual(InsightsFigure.timeInRange.buttonLabel, "About time in range")
        XCTAssertEqual(InsightsFigure.gmi.buttonLabel, "About GMI")
        XCTAssertEqual(InsightsFigure.lows.buttonLabel, "About time below range")
    }

    // MARK: Period phrase

    func testPeriodPhrase() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Australia/Perth")!
        let locale = Locale(identifier: "en_AU")
        let midnight = cal.date(from: DateComponents(year: 2026, month: 11, day: 3))!
        XCTAssertEqual(InsightsExplainer.period(hours: 24, end: midnight, isLatest: true, calendar: cal, locale: locale),
                       "the last 24 hours")
        XCTAssertEqual(InsightsExplainer.period(hours: 168, end: midnight, isLatest: true, calendar: cal, locale: locale),
                       "the last 7 days")
        XCTAssertEqual(InsightsExplainer.period(hours: 3, end: midnight, isLatest: true, calendar: cal, locale: locale),
                       "the last 3 hours")
        // Whole days ending at midnight name the last day they cover.
        let earlier = InsightsExplainer.period(hours: 168, end: midnight, isLatest: false, calendar: cal, locale: locale)
        XCTAssertTrue(earlier.hasPrefix("the 7 days ending 2"), earlier)
        XCTAssertTrue(earlier.contains("Nov"), earlier)
    }

    // MARK: Entrance

    func testEntranceScalesInAndOnlyFadesUnderReduceMotion() {
        XCTAssertLessThan(InsightsExplainerEntrance.scale(shown: false, reduceMotion: false), 1)
        XCTAssertGreaterThan(InsightsExplainerEntrance.startScale, 0.9)
        XCTAssertEqual(InsightsExplainerEntrance.scale(shown: true, reduceMotion: false), 1)
        XCTAssertEqual(InsightsExplainerEntrance.scale(shown: false, reduceMotion: true), 1)
        XCTAssertEqual(InsightsExplainerEntrance.opacity(shown: false), 0)
        XCTAssertEqual(InsightsExplainerEntrance.opacity(shown: true), 1)
    }
}
