import XCTest
@testable import GlucOSEngine

/// "Log Again Now" (iPhone swipe right, Mac right-click): `LogEntry.copied` is a straight copy of
/// what was logged, at a new time and with a new id. No amount ever changes.
final class LogAgainTests: XCTestCase {
    private let then = Date(timeIntervalSince1970: 1_800_000_000)
    private let now = Date(timeIntervalSince1970: 1_800_020_000)

    private func calculation() throws -> BolusCalculation {
        let json = """
        {"carbs": 45, "glucose": 160, "carbRatio": 10, "correctionFactor": 50, "targetMgdl": 110,
         "foodUnits": 4.5, "correctionUnits": 1, "insulinOnBoard": 0.5, "suggestedUnits": 5}
        """
        return try JSONDecoder().decode(BolusCalculation.self, from: Data(json.utf8))
    }

    func testDoseKeepsEveryAmountAndDetail() throws {
        var dose = InsulinDose(timestamp: then, units: 4.35, kind: .rapid, name: "NovoRapid",
                               site: .abdomenLeft, viaPump: false, note: "before lunch")
        dose.calculation = try calculation()
        dose.purpose = .meal
        let original = LogEntry.dose(dose)

        let copy = original.copied(at: now)
        guard case .dose(let d) = copy else { return XCTFail("a dose copies to a dose") }
        XCTAssertNotEqual(d.id, dose.id)
        XCTAssertEqual(d.timestamp, now)
        XCTAssertEqual(d.units, 4.35)
        XCTAssertEqual(d.kind, .rapid)
        XCTAssertEqual(d.name, "NovoRapid")
        XCTAssertEqual(d.site, .abdomenLeft)
        XCTAssertFalse(d.viaPump)
        XCTAssertEqual(d.note, "before lunch")
        // The calculator's working was for the original moment, and the meal question may be
        // asked again about the new dose. Neither changes the units.
        XCTAssertNil(d.calculation)
        XCTAssertNil(d.purpose)
    }

    func testPumpBolusStaysAPumpBolus() {
        let dose = InsulinDose(timestamp: then, units: 0.35, kind: .ultraRapid, site: nil, viaPump: true)
        guard case .dose(let d) = LogEntry.dose(dose).copied(at: now) else { return XCTFail() }
        XCTAssertEqual(d.units, 0.35)
        XCTAssertTrue(d.viaPump)
        XCTAssertNil(d.site)
    }

    func testMealKeepsCarbsFoodAndItems() {
        let bread = FoodItem(id: "t:1", name: "Bread", carbsPer100g: 45,
                             portions: [FoodPortion(name: "slice", grams: 30)], source: .custom)
        let item = MealItem(food: bread, grams: 60, portion: "2 × slice")
        // The user confirmed 30 g, not the items' 27 g: the copy keeps what they confirmed.
        let meal = MealEntry(timestamp: then, carbs: 30, food: "Toast", note: "with butter", items: [item])

        guard case .meal(let m) = LogEntry.meal(meal).copied(at: now) else { return XCTFail() }
        XCTAssertNotEqual(m.id, meal.id)
        XCTAssertEqual(m.timestamp, now)
        XCTAssertEqual(m.carbs, 30)
        XCTAssertEqual(m.food, "Toast")
        XCTAssertEqual(m.note, "with butter")
        XCTAssertEqual(m.items, [item])
    }

    func testSiteChangeAndContextKeepWhatWasLogged() {
        let site = SiteChange(timestamp: then, site: .thighRight, note: "new set")
        guard case .siteChange(let s) = LogEntry.siteChange(site).copied(at: now) else { return XCTFail() }
        XCTAssertNotEqual(s.id, site.id)
        XCTAssertEqual(s.timestamp, now)
        XCTAssertEqual(s.site, .thighRight)
        XCTAssertEqual(s.note, "new set")

        let context = ContextEvent(timestamp: then, tags: [.exercise, .stress], note: "run")
        guard case .context(let c) = LogEntry.context(context).copied(at: now) else { return XCTFail() }
        XCTAssertNotEqual(c.id, context.id)
        XCTAssertEqual(c.timestamp, now)
        XCTAssertEqual(c.tags, [.exercise, .stress])
        XCTAssertEqual(c.note, "run")
    }

    func testOnlyIdAndTimeDifferForEveryKindExceptDoseWorking() {
        let entries: [LogEntry] = [
            .dose(InsulinDose(timestamp: then, units: 12, kind: .long, name: "Toujeo", site: .thighLeft)),
            .meal(MealEntry(timestamp: then, carbs: 0, food: "Coffee")),
            .siteChange(SiteChange(timestamp: then, site: .armLeft)),
            .context(ContextEvent(timestamp: then, tags: [.wokeUp])),
        ]
        let id = UUID()
        for entry in entries {
            let copy = entry.copied(at: now, id: id)
            XCTAssertEqual(copy.id, id)
            XCTAssertEqual(copy.timestamp, now)
            XCTAssertEqual(copy.shortTitle, entry.shortTitle, "same thing logged: \(entry.shortTitle)")
            // Putting the old id and time back gives the original exactly.
            XCTAssertEqual(copy.copied(at: then, id: entry.id), entry)
        }
    }

    func testCopyingLeavesTheOriginalAlone() {
        let dose = InsulinDose(timestamp: then, units: 3, kind: .rapid)
        let original = LogEntry.dose(dose)
        _ = original.copied(at: now)
        XCTAssertEqual(original, .dose(dose))
    }

    func testDeleteHasItsOwnQuietFeel() {
        // A delete is acknowledged like Undo (a light tap), never like a success.
        XCTAssertEqual(HapticEvent.deleted.feel, HapticEvent.undone.feel)
        XCTAssertEqual(HapticEvent.deleted.priority, HapticEvent.undone.priority)
        XCTAssertFalse(HapticEvent.deleted.isTick)
    }
}
