import XCTest
@testable import GlucOSEngine

/// The iPhone Logbook's search and quick filters (docs/LogbookSearch.md).
final class LogbookSearchTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Perth")!
        c.firstWeekday = 2 // Monday
        c.locale = Locale(identifier: "en_AU")
        return c
    }()

    /// Thursday 19 November 2026, 2 pm in Perth.
    private var now: Date { day(19, hour: 14) }

    private func day(_ d: Int, hour: Int = 12, minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: hour, minute: minute))!
    }

    private func parse(_ text: String) -> LogbookQuery { LogbookQuery.parse(text, now: now, calendar: cal) }

    private func meal(_ food: String, at date: Date, carbs: Double = 60, note: String = "") -> LogEntry {
        .meal(MealEntry(timestamp: date, carbs: carbs, food: food, note: note))
    }

    private func dose(_ units: Double, at date: Date, name: String = "NovoRapid", note: String = "") -> LogEntry {
        .dose(InsulinDose(timestamp: date, units: units, kind: .rapid, name: name, note: note))
    }

    // MARK: Reading the search

    func testThatPizzaLastWeekFindsThePizzaFromLastWeek() {
        let q = parse("that pizza last week")
        XCTAssertEqual(q.terms, ["pizza"])
        XCTAssertEqual(q.period?.label, "Since last week")
        XCTAssertEqual(q.withoutPeriod, "that pizza")

        let lastTuesday = meal("Pizza, ham and pineapple", at: day(10, hour: 19))
        let thisMonday = meal("pizza", at: day(16, hour: 19))
        let aMonthAgo = meal("Pizza", at: day(1, hour: 19))
        let toast = meal("Toast", at: day(11, hour: 8))
        let found = [lastTuesday, thisMonday, aMonthAgo, toast].filter { LogbookSearch.matches($0, q) }
        // Last week and this week so far (it may have been on Monday), not three weeks ago.
        XCTAssertEqual(found.map(\.id), [lastTuesday.id, thisMonday.id])
    }

    func testDaysAreReadFromTheSearch() {
        XCTAssertEqual(parse("today").period?.interval, DateInterval(start: day(19, hour: 0), end: day(20, hour: 0)))
        XCTAssertEqual(parse("yesterday").period?.interval, DateInterval(start: day(18, hour: 0), end: day(19, hour: 0)))
        XCTAssertEqual(parse("this week").period?.interval.start, day(16, hour: 0))
        XCTAssertEqual(parse("last week").period?.interval.start, day(9, hour: 0))
        XCTAssertEqual(parse("this month").period?.interval.start, day(1, hour: 0))
        XCTAssertEqual(parse("last 3 days").period?.interval.start, day(17, hour: 0))
        XCTAssertEqual(parse("2 days ago").period?.interval, DateInterval(start: day(17, hour: 0), end: day(18, hour: 0)))
        let night = parse("last night").period!.interval
        XCTAssertEqual(night.start, day(18, hour: 17))
        XCTAssertEqual(night.end, day(19, hour: 7))
    }

    func testAWeekdayIsTheLatestOne() {
        // Monday the 16th, three days ago.
        let monday = parse("pizza monday")
        XCTAssertEqual(monday.period?.interval.start, day(16, hour: 0))
        XCTAssertEqual(monday.period?.label, "Monday")
        XCTAssertEqual(monday.terms, ["pizza"])
        // "Thursday" is today; "last thursday" is the week before.
        XCTAssertEqual(parse("thursday").period?.interval.start, day(19, hour: 0))
        XCTAssertEqual(parse("last thursday").period?.interval.start, day(12, hour: 0))
        XCTAssertEqual(parse("fri").period?.interval.start, day(13, hour: 0))
        XCTAssertEqual(parse("on Wednesday").period?.interval.start, day(18, hour: 0))
        XCTAssertEqual(parse("on Wednesday").period?.label, "Yesterday")
        XCTAssertEqual(parse("pizza on friday").withoutPeriod, "pizza")
    }

    func testFoodWordsAreNotReadAsDays() {
        XCTAssertNil(parse("sun dried tomato").period)
        XCTAssertNil(parse("sat").period)
        XCTAssertNil(parse("fried rice").period)
        XCTAssertNil(parse("4 u").period)
        XCTAssertNil(parse("last").period)
        XCTAssertEqual(parse("fried rice").terms, ["fried", "rice"])
    }

    func testPunctuationAndFillersAreIgnored() {
        XCTAssertEqual(parse("  Pizza,  the  ").terms, ["pizza"])
        XCTAssertEqual(parse("4.5 u").terms, ["4.5", "u"])
        XCTAssertTrue(parse("   ").isEmpty)
    }

    // MARK: Matching

    func testEveryWordHasToBeFoundAnywhereInTheEntry() {
        let entry = meal("Pizza", at: day(18), note: "Friday night with the team")
        XCTAssertTrue(LogbookSearch.matches(entry, parse("pizza team")))
        XCTAssertFalse(LogbookSearch.matches(entry, parse("pizza pasta")))
        XCTAssertTrue(LogbookSearch.matches(entry, parse("PIZZAS")), "case and plurals")
        XCTAssertTrue(LogbookSearch.matches(meal("Crème brûlée", at: day(18)), parse("creme brulee")), "accents")
    }

    func testInsulinIsFoundByAmountNameAndType() {
        let entry = dose(4, at: day(18), note: "before lunch")
        XCTAssertTrue(LogbookSearch.matches(entry, parse("4 u")))
        XCTAssertTrue(LogbookSearch.matches(entry, parse("novorapid")))
        XCTAssertTrue(LogbookSearch.matches(entry, parse("rapid")))
        XCTAssertTrue(LogbookSearch.matches(entry, parse("insulin lunch")))
        XCTAssertFalse(LogbookSearch.matches(entry, parse("meal")))
    }

    func testAlertRowsAreSearchedByTheirTitle() {
        let row = AlertLog.rows([AlertRecord(kind: .urgentLow, firedAt: day(18, hour: 3))])[0]
        XCTAssertTrue(LogbookSearch.matches(row, parse("urgent low")))
        XCTAssertTrue(LogbookSearch.matches(row, parse("low yesterday")))
        XCTAssertFalse(LogbookSearch.matches(row, parse("low today")))
    }

    // MARK: Quick filters

    func testLowsAreHypoTreatmentsAndWhatWasLoggedWithThem() {
        let t = day(18, hour: 3, minute: 10)
        let jellyBeans = meal("Jelly beans", at: t, carbs: 15)
        let tag = LogEntry.context(ContextEvent(timestamp: t, tags: [.hypoTreatment]))
        let dinner = meal("Pasta", at: day(18, hour: 19))
        let ids = LogbookSearch.lowTreatmentIDs([jellyBeans, tag, dinner])
        XCTAssertEqual(ids, [jellyBeans.id, tag.id])
        XCTAssertTrue(LogbookFilter.lows.matches(jellyBeans, lowIDs: ids))
        XCTAssertFalse(LogbookFilter.lows.matches(dinner, lowIDs: ids))
        // "low" finds the jelly beans too.
        XCTAssertTrue(LogbookSearch.matches(jellyBeans, parse("low"), lowIDs: ids))
        XCTAssertFalse(LogbookSearch.matches(dinner, parse("low"), lowIDs: ids))
    }

    func testLowsAlsoShowLowAlertsButNotHighOnes() {
        let rows = AlertLog.rows([AlertRecord(kind: .low, firedAt: day(18, hour: 3)),
                                  AlertRecord(kind: .high, firedAt: day(18, hour: 21))])
        XCTAssertEqual(rows.filter(LogbookFilter.lows.matches).map(\.isLow), [true])
        XCTAssertEqual(rows.filter(LogbookFilter.alerts.matches).count, 2)
        XCTAssertTrue(rows.allSatisfy { !LogbookFilter.meals.matches($0) })
    }

    func testHighsAreHighAlertsAndCorrections() {
        var correction = InsulinDose(timestamp: day(18, hour: 21), units: 2, kind: .rapid, name: "NovoRapid", note: "")
        correction.purpose = .correction
        var forFood = InsulinDose(timestamp: day(18, hour: 12), units: 4, kind: .rapid, name: "NovoRapid", note: "")
        forFood.purpose = .meal
        let ids: Set<UUID> = []
        XCTAssertTrue(LogbookFilter.highs.matches(.dose(correction), lowIDs: ids))
        XCTAssertFalse(LogbookFilter.highs.matches(.dose(forFood), lowIDs: ids))
        XCTAssertFalse(LogbookFilter.highs.matches(dose(2, at: day(18)), lowIDs: ids))
        XCTAssertFalse(LogbookFilter.highs.matches(meal("Pizza", at: day(18)), lowIDs: ids))
        let rows = AlertLog.rows([AlertRecord(kind: .low, firedAt: day(18, hour: 3)),
                                  AlertRecord(kind: .veryHigh, firedAt: day(18, hour: 21))])
        XCTAssertEqual(rows.filter(LogbookFilter.highs.matches).map(\.isHigh), [true])
        XCTAssertEqual(LogbookFilter.available(entries: [.dose(correction)], alerts: []), [.insulin, .highs])
        XCTAssertEqual(LogbookFilter.available(entries: [], alerts: rows), [.lows, .highs, .alerts])
    }

    func testNotesAreEntriesWithANote() {
        let ids: Set<UUID> = []
        XCTAssertTrue(LogbookFilter.notes.matches(meal("Pizza", at: day(18), note: "felt off"), lowIDs: ids))
        XCTAssertFalse(LogbookFilter.notes.matches(meal("Pizza", at: day(18)), lowIDs: ids))
        XCTAssertTrue(LogbookFilter.insulin.matches(dose(2, at: day(18)), lowIDs: ids))
        XCTAssertFalse(LogbookFilter.meals.matches(dose(2, at: day(18)), lowIDs: ids))
    }

    func testOnlyChipsThatWouldShowSomethingAreOffered() {
        let entries = [meal("Pizza", at: day(18)), dose(4, at: day(18), note: "late")]
        XCTAssertEqual(LogbookFilter.available(entries: entries, alerts: []), [.meals, .insulin, .notes])
        let low = AlertLog.rows([AlertRecord(kind: .low, firedAt: day(18, hour: 3))])
        XCTAssertEqual(LogbookFilter.available(entries: entries, alerts: low), [.meals, .insulin, .lows, .notes, .alerts])
    }

    // MARK: Highlights and the empty list

    func testHighlightsMarkEachWordWhereverItIs() {
        let text = "45 g · Pizza, then more pizza"
        let ranges = LogbookSearch.highlights(in: text, terms: ["pizza"])
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["Pizza", "pizza"])
        // A plural lights the word that's there; overlapping words merge into one run.
        XCTAssertEqual(LogbookSearch.highlights(in: "Pizza", terms: ["pizzas"]).map { String("Pizza"[$0]) }, ["Pizza"])
        let merged = LogbookSearch.highlights(in: "Pineapple", terms: ["pine", "apple", "neap"])
        XCTAssertEqual(merged.map { String("Pineapple"[$0]) }, ["Pineapple"])
        XCTAssertTrue(LogbookSearch.highlights(in: "Toast", terms: []).isEmpty)
    }

    func testTheEmptyListSaysWhatWasSearched() {
        XCTAssertEqual(LogbookSearch.noMatchMessage(parse("pizza last week"), filter: .meals),
                       "Nothing in Meals matches “pizza” since last week.")
        XCTAssertEqual(LogbookSearch.noMatchMessage(parse("pizza on monday"), filter: nil),
                       "Nothing matches “pizza” on Monday.")
        XCTAssertEqual(LogbookSearch.noMatchMessage(parse("yesterday"), filter: .lows), "Nothing in Lows yesterday.")
        XCTAssertEqual(LogbookSearch.noMatchMessage(parse(""), filter: .notes), "Nothing in Notes logged yet.")
    }

    // MARK: The Mac Logbook

    func testOnTheMacAnySearchLooksPastTheToolbarPeriodButAChipAloneDoesNot() {
        XCTAssertFalse(LogbookSearch.looksPastToolbarPeriod(parse(""), allDates: false))
        XCTAssertTrue(LogbookSearch.looksPastToolbarPeriod(parse("pizza"), allDates: false))
        XCTAssertTrue(LogbookSearch.looksPastToolbarPeriod(parse("fri"), allDates: false))
        XCTAssertTrue(LogbookSearch.looksPastToolbarPeriod(parse(""), allDates: true))
    }

    func testOnTheMacSearchAllDatesIsOfferedOnlyWhenItCouldFindMore() {
        // The day narrowed it, and there are words (or a chip) to look for on other days.
        XCTAssertTrue(LogbookSearch.offersAllDates(parse("pizza last week"), filter: nil, allDates: false))
        XCTAssertTrue(LogbookSearch.offersAllDates(parse("yesterday"), filter: .lows, allDates: false))
        // A day on its own: dropping it would just show everything.
        XCTAssertFalse(LogbookSearch.offersAllDates(parse("yesterday"), filter: nil, allDates: false))
        // Words alone already search every date.
        XCTAssertFalse(LogbookSearch.offersAllDates(parse("pizza"), filter: .meals, allDates: false))
        // A chip kept to the toolbar's period, until All Dates is on.
        XCTAssertTrue(LogbookSearch.offersAllDates(parse(""), filter: .notes, allDates: false))
        XCTAssertFalse(LogbookSearch.offersAllDates(parse(""), filter: .notes, allDates: true))
        XCTAssertFalse(LogbookSearch.offersAllDates(parse(""), filter: nil, allDates: false))
    }

    // MARK: Switching chips

    func testAPickComparesTagsTheWayTagsMatch() {
        XCTAssertEqual(LogbookFilterPick(kind: .meals, tag: "exercise"), LogbookFilterPick(kind: .meals, tag: " Exercise "))
        XCTAssertNotEqual(LogbookFilterPick(kind: .meals, tag: nil), LogbookFilterPick(kind: .insulin, tag: nil))
        XCTAssertNotEqual(LogbookFilterPick(kind: nil, tag: "Sick"), LogbookFilterPick(kind: nil, tag: nil))
        XCTAssertEqual(LogbookFilterPick(kind: nil, tag: nil), LogbookFilterPick(kind: nil, tag: nil))
    }

    func testTheSwitchSaysHowManyRowsAreLeft() {
        XCTAssertEqual(LogbookFilterPick.announcement(count: 0), "No matches")
        XCTAssertEqual(LogbookFilterPick.announcement(count: 1), "1 entry")
        XCTAssertEqual(LogbookFilterPick.announcement(count: 12), "12 entries")
    }

    func testTheFadeIsShorterThanTheHighlightSpring() {
        // The rows settle before the highlight does, so the eye follows the chip.
        XCTAssertLessThan(LogbookFilterPick.fadeOut + LogbookFilterPick.fadeIn, 0.5)
    }
}
