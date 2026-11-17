import XCTest
@testable import GlucOSEngine

/// Grouped Logbook rows (`LogbookGrouping`): a meal and its insulin, logged within 15 minutes of
/// each other, show as one row that opens out into the entries.
final class LogbookGroupingTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Perth")!
        return c
    }()

    /// 8:00 am in Perth on a fixed day, plus `minutes`.
    private func at(_ minutes: Double) -> Date {
        let base = calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 8))!
        return base.addingTimeInterval(minutes * 60)
    }

    private func meal(_ m: Double, carbs: Double = 45, food: String = "Toast") -> LogEntry {
        .meal(MealEntry(timestamp: at(m), carbs: carbs, food: food))
    }

    private func dose(_ m: Double, units: Double = 4) -> LogEntry {
        .dose(InsulinDose(timestamp: at(m), units: units, kind: .rapid, name: "NovoRapid"))
    }

    private func moment(_ m: Double) -> LogEntry {
        .context(ContextEvent(timestamp: at(m), tags: [.exercise]))
    }

    /// A stand-in for a list row: an entry, or something else (an alert row) at a time.
    private enum Row {
        case entry(LogEntry)
        case other(Date)
        var entry: LogEntry? { if case .entry(let e) = self { return e } else { return nil } }
        var timestamp: Date {
            switch self {
            case .entry(let e): return e.timestamp
            case .other(let d): return d
            }
        }
    }

    /// Newest first, as the Logbooks list them.
    private func runs(_ rows: [Row]) -> [LogbookRun<Row>] {
        LogbookGrouping.runs(rows.sorted { $0.timestamp > $1.timestamp }, entry: \.entry, calendar: calendar)
    }

    private func runs(_ entries: [LogEntry]) -> [LogbookRun<Row>] { runs(entries.map(Row.entry)) }

    private func groups(_ runs: [LogbookRun<Row>]) -> [LogbookGroup] {
        runs.compactMap { if case .group(let g) = $0 { return g } else { return nil } }
    }

    private func singles(_ runs: [LogbookRun<Row>]) -> Int {
        runs.filter { if case .single = $0 { return true } else { return false } }.count
    }

    // MARK: The rule

    func testMealAndItsInsulinGroup() {
        let m = meal(0), d = dose(5)
        let out = runs([m, d])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(groups(out).first?.ids, [m.id, d.id], "oldest first inside the group")
    }

    func testDoseBeforeTheMealStillGroups() {
        let d = dose(0), m = meal(12)
        XCTAssertEqual(groups(runs([d, m])).first?.ids, [d.id, m.id])
    }

    func testExactlyFifteenMinutesGroupsButSixteenDoesNot() {
        XCTAssertEqual(groups(runs([meal(0), dose(15)])).count, 1)
        let apart = runs([meal(0), dose(16)])
        XCTAssertTrue(groups(apart).isEmpty)
        XCTAssertEqual(singles(apart), 2)
    }

    func testTheWholeGroupFitsInTheWindowFromItsFirstEntry() {
        // 0, 10, 20: the third is 20 min after the first, so it starts afresh (and, alone, stands alone).
        let m = meal(0), d = dose(10), late = dose(20, units: 2)
        let out = runs([m, d, late])
        XCTAssertEqual(groups(out).map(\.ids), [[m.id, d.id]])
        XCTAssertEqual(singles(out), 1)
        // Newest first: the late dose's row comes before the group.
        if case .single(let r) = out.first { XCTAssertEqual(r.entry?.id, late.id) } else { XCTFail("late dose first") }
    }

    func testTwoDosesNeverFoldTogether() {
        let out = runs([dose(0), dose(5, units: 2)])
        XCTAssertTrue(groups(out).isEmpty, "a second dose is always its own row")
        XCTAssertEqual(singles(out), 2)
    }

    func testTwoMealsAloneDoNotGroup() {
        XCTAssertTrue(groups(runs([meal(0), meal(6, carbs: 20, food: "Juice")])).isEmpty)
    }

    func testMoreThanTwoEntriesGroupWhenMixed() {
        let g = groups(runs([meal(0), dose(4), meal(9, carbs: 15, food: "Yoghurt")])).first
        XCTAssertEqual(g?.members.count, 3)
        XCTAssertEqual(g?.title, "2 meals and insulin")
    }

    func testSomethingInBetweenKeepsThemApart() {
        let alertBetween = runs([.entry(meal(0)), .other(at(3)), .entry(dose(6))])
        XCTAssertTrue(groups(alertBetween).isEmpty)
        XCTAssertEqual(alertBetween.count, 3)
        let momentBetween = runs([meal(0), moment(3), dose(6)])
        XCTAssertTrue(groups(momentBetween).isEmpty)
    }

    func testSiteChangesAndMomentsNeverGroup() {
        let site = LogEntry.siteChange(SiteChange(timestamp: at(2), site: .abdomenLeft))
        XCTAssertFalse(LogbookGrouping.joins(site))
        XCTAssertFalse(LogbookGrouping.joins(moment(0)))
        XCTAssertTrue(groups(runs([site, dose(5)])).isEmpty)
    }

    func testNoGroupAcrossMidnight() {
        let late = LogEntry.meal(MealEntry(timestamp: at(15 * 60 + 55), carbs: 30))  // 11:55 pm
        let early = LogEntry.dose(InsulinDose(timestamp: at(16 * 60 + 5), units: 3, kind: .rapid)) // 12:05 am
        XCTAssertTrue(groups(runs([late, early])).isEmpty)
    }

    func testListOrderIsKept() {
        let older = moment(-60), m = meal(0), d = dose(5), newer = moment(60)
        let out = runs([older, m, d, newer])
        XCTAssertEqual(out.count, 3)
        if case .single(let r) = out[0] { XCTAssertEqual(r.entry?.id, newer.id) } else { XCTFail() }
        if case .group(let g) = out[1] { XCTAssertEqual(g.ids, [m.id, d.id]) } else { XCTFail() }
        if case .single(let r) = out[2] { XCTAssertEqual(r.entry?.id, older.id) } else { XCTFail() }
    }

    // MARK: Filters work per entry

    func testAFilteredListOnlyGroupsWhatShows() {
        // The Insulin chip leaves the doses only: nothing to pair them with.
        let insulinOnly = runs([dose(0), dose(5)])
        XCTAssertTrue(groups(insulinOnly).isEmpty)
        // A search that finds only the meal shows it alone.
        XCTAssertEqual(singles(runs([meal(0)])), 1)
    }

    // MARK: Ids, opening and closing

    func testGroupIdIsStableAndNotAnEntryId() {
        let m = meal(0), d = dose(5)
        let before = groups(runs([m, d]))[0]
        XCTAssertFalse(before.ids.contains(before.id))
        XCTAssertEqual(before.id, LogbookGroup.id(for: m.id))
        // A second meal logged a few minutes later joins: same group, so it stays open.
        let after = groups(runs([m, d, meal(10, carbs: 10, food: "Juice")]))[0]
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(LogbookGroup.id(for: m.id), LogbookGroup.id(for: m.id))
    }

    func testListedShowsEntriesUnderAnOpenGroup() {
        let m = meal(0), d = dose(5), other = moment(60)
        let out = runs([m, d, other])
        let g = groups(out)[0]

        let closed = LogbookGrouping.listed(out, expanded: [])
        XCTAssertEqual(closed.count, 2)
        if case .group(_, let open) = closed[1] { XCTAssertFalse(open) } else { XCTFail() }

        let open = LogbookGrouping.listed(out, expanded: [g.id])
        XCTAssertEqual(open.count, 4)
        if case .group(_, let isOpen) = open[1] { XCTAssertTrue(isOpen) } else { XCTFail() }
        // Under it, newest first like the rest of the list.
        if case .member(let e, let id) = open[2] { XCTAssertEqual(e.id, d.id); XCTAssertEqual(id, g.id) } else { XCTFail() }
        if case .member(let e, _) = open[3] { XCTAssertEqual(e.id, m.id) } else { XCTFail() }
    }

    func testFindsTheGroupAnEntryIsIn() {
        let m = meal(0), d = dose(5), other = moment(60)
        let out = runs([m, d, other])
        XCTAssertEqual(LogbookGrouping.group(containing: d.id, in: out)?.id, LogbookGroup.id(for: m.id))
        XCTAssertNil(LogbookGrouping.group(containing: other.id, in: out))
        XCTAssertEqual(LogbookGrouping.memberships(out), [m.id: LogbookGroup.id(for: m.id), d.id: LogbookGroup.id(for: m.id)])
    }

    // MARK: Words

    func testRowWords() {
        let g = LogbookGroup(members: [dose(5), meal(0)])
        XCTAssertEqual(g.title, "Meal and insulin")
        XCTAssertEqual(g.parts, "45 g · Toast + 4 u NovoRapid")
        XCTAssertEqual(g.totals, "45 g carbs · 4 u")
        XCTAssertEqual(g.spoken, "Meal and insulin, 2 entries: 45 g · Toast, 4 u NovoRapid")
        XCTAssertEqual(g.actionName(expanded: false), "Expand")
        XCTAssertEqual(g.actionName(expanded: true), "Collapse")
        XCTAssertEqual(g.spokenState(expanded: false), "Collapsed")
        XCTAssertEqual(g.announcement(expanded: true), "Showing 2 entries")
        XCTAssertEqual(g.timeRange { _ in "8:00 am" }, "8:00 am")
        XCTAssertEqual(g.timeRange { $0 == self.at(0) ? "8:00" : "8:05" }, "8:00 – 8:05")
    }

    func testTotalsLeaveOutWhatWasNotLogged() {
        let described = LogEntry.meal(MealEntry(timestamp: at(0), carbs: 0, food: "Salad"))
        XCTAssertEqual(LogbookGroup(members: [described, dose(3, units: 2)]).totals, "2 u")
    }
}
