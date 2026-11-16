import XCTest
@testable import GlucOSEngine

/// The "last logged" line under the chart on iPhone Today and in the Mac popover.
final class LastLoggedTests: XCTestCase {
    /// Wednesday 25 November 2026, 2 pm in Perth.
    private let now = Date(timeIntervalSince1970: 1_795_586_400)

    private func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    private func meal(_ minutes: Double, carbs: Double = 45, food: String = "") -> LogEntry {
        .meal(MealEntry(timestamp: ago(minutes), carbs: carbs, food: food))
    }

    private func dose(_ minutes: Double, units: Double = 4) -> LogEntry {
        .dose(InsulinDose(timestamp: ago(minutes), units: units, kind: .rapid, name: "NovoRapid", note: ""))
    }

    func testTheNewestEntryWins() {
        let entries = [meal(100), dose(25), meal(300)]
        let line = LastLogged.latest(entries, now: now)
        XCTAssertEqual(line?.entryID, entries[1].id)
        XCTAssertEqual(line?.text(now: now), "Dose 25 m ago · 4 u")
    }

    func testAMealSaysItsCarbs() {
        let line = LastLogged.latest([meal(100)], now: now)
        XCTAssertEqual(line?.kind, .meal)
        XCTAssertEqual(line?.text(now: now), "Meal 1 h 40 m ago · 45 g")
        XCTAssertEqual(line?.spoken(now: now), "Last logged: meal, 1 hour 40 minutes ago, 45 grams")
    }

    func testAMealWithoutCarbsSaysWhatWasEaten() {
        XCTAssertEqual(LastLogged.latest([meal(10, carbs: 0, food: "Salad")], now: now)?.text(now: now),
                       "Meal 10 m ago · Salad")
        XCTAssertEqual(LastLogged.latest([meal(10, carbs: 0, food: "  ")], now: now)?.text(now: now),
                       "Meal 10 m ago")
    }

    func testOtherKinds() {
        let site = LogEntry.siteChange(SiteChange(timestamp: ago(60), site: .abdomenLeft))
        XCTAssertEqual(LastLogged.latest([site], now: now)?.title, "Site change")
        XCTAssertEqual(LastLogged.latest([site], now: now)?.kind, .site)

        let wake = LogEntry.context(ContextEvent(timestamp: ago(0.5), tags: [.wokeUp]))
        XCTAssertEqual(LastLogged.latest([wake], now: now)?.text(now: now), "Woke up just now")

        let note = LogEntry.context(ContextEvent(timestamp: ago(5), tags: [], note: "Felt off"))
        XCTAssertEqual(LastLogged.latest([note], now: now)?.text(now: now), "Note 5 m ago")
    }

    func testItHidesAfterTwelveHours() {
        XCTAssertNotNil(LastLogged.latest([meal(12 * 60)], now: now))
        XCTAssertNil(LastLogged.latest([meal(12 * 60 + 1)], now: now))
        XCTAssertNil(LastLogged.latest([], now: now))
    }

    func testAFutureTimeIsNotTheLastThingLogged() {
        // A synced clock a minute ahead still counts, as "just now".
        let slightlyAhead = LogEntry.meal(MealEntry(timestamp: now.addingTimeInterval(60), carbs: 20))
        XCTAssertEqual(LastLogged.latest([slightlyAhead], now: now)?.text(now: now), "Meal just now · 20 g")
        // An hour ahead is a planned or mistyped time: the entry before it shows instead.
        let planned = LogEntry.meal(MealEntry(timestamp: now.addingTimeInterval(3600), carbs: 60))
        let earlier = dose(30)
        XCTAssertEqual(LastLogged.latest([planned, earlier], now: now)?.entryID, earlier.id)
    }

    func testTiesGoToTheFirstListed() {
        let a = meal(15), b = dose(15)
        XCTAssertEqual(LastLogged.latest([a, b], now: now)?.entryID, a.id)
    }

    func testAgeRoundsDownToWholeMinutes() {
        XCTAssertEqual(LastLogged.ago(59), "just now")
        XCTAssertEqual(LastLogged.ago(60), "1 m ago")
        XCTAssertEqual(LastLogged.ago(119), "1 m ago")
        XCTAssertEqual(LastLogged.ago(3599), "59 m ago")
        XCTAssertEqual(LastLogged.ago(3600), "1 h ago")
        XCTAssertEqual(LastLogged.ago(6000), "1 h 40 m ago")
        XCTAssertEqual(LastLogged.ago(-30), "just now")
        XCTAssertEqual(LastLogged.spokenAgo(60), "1 minute ago")
        XCTAssertEqual(LastLogged.spokenAgo(3600), "1 hour ago")
        XCTAssertEqual(LastLogged.spokenAgo(2 * 3600 + 60), "2 hours 1 minute ago")
    }

    func testOneUnitIsSpokenSingular() {
        XCTAssertEqual(LastLogged.latest([dose(5, units: 1)], now: now)?.spoken(now: now),
                       "Last logged: dose, 5 minutes ago, 1 unit")
    }
}
