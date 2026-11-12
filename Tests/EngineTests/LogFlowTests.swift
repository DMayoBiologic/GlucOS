import XCTest
@testable import GlucOSEngine

final class LogFlowTests: XCTestCase {
    private let injections = LogFlow.parts(logsInsulin: true, pump: false)
    private let pump = LogFlow.parts(logsInsulin: true, pump: true)
    private let noInsulin = LogFlow.parts(logsInsulin: false, pump: false)

    func testPartsFollowTherapyWithFoodFirst() {
        XCTAssertEqual(injections, [.food, .insulin, .event])
        XCTAssertEqual(pump, [.food, .insulin, .site, .event])
        XCTAssertEqual(noInsulin, [.food, .event])
    }

    func testFoodIsShownAboveInsulinWhateverWasPickedFirst() {
        // Insulin was on first and food was added after: food still leads.
        XCTAssertEqual(LogFlow.ordered([.insulin, .food], available: injections), [.food, .insulin])
        XCTAssertEqual(LogFlow.ordered([.event, .site, .insulin], available: pump), [.insulin, .site, .event])
        // A part the therapy doesn't have is never shown.
        XCTAssertEqual(LogFlow.ordered([.insulin, .food], available: noInsulin), [.food])
    }

    func testFocusGoesToThePartJustAdded() {
        XCTAssertEqual(LogFlow.focusPart(from: [.insulin], to: [.insulin, .food], available: injections), .food)
        XCTAssertEqual(LogFlow.focusPart(from: [.food], to: [.food, .insulin], available: injections), .insulin)
        XCTAssertNil(LogFlow.focusPart(from: [.food, .insulin], to: [.food], available: injections))
        // A preset can add several at once: the first shown one wins.
        XCTAssertEqual(LogFlow.focusPart(from: [], to: [.event, .insulin, .food], available: injections), .food)
    }

    func testNextStepOffersInsulinAfterCarbs() {
        XCTAssertEqual(LogFlow.nextStep(picked: [.food], available: injections, carbs: 45, mealtimeDose: true),
                       .addInsulin(carbs: 45))
        XCTAssertNil(LogFlow.nextStep(picked: [.food], available: injections, carbs: 0, mealtimeDose: true))
        XCTAssertNil(LogFlow.nextStep(picked: [.food], available: noInsulin, carbs: 45, mealtimeDose: true))
        XCTAssertNil(LogFlow.nextStep(picked: [.food, .insulin], available: injections, carbs: 45, mealtimeDose: true))
    }

    func testNextStepOffersFoodForAMealtimeDoseOnly() {
        XCTAssertEqual(LogFlow.nextStep(picked: [.insulin], available: injections, carbs: 0, mealtimeDose: true), .addFood)
        XCTAssertNil(LogFlow.nextStep(picked: [.insulin], available: injections, carbs: 0, mealtimeDose: false))
        XCTAssertNil(LogFlow.nextStep(picked: [.event], available: injections, carbs: 0, mealtimeDose: true))
    }

    func testSummaryReadsInFlowOrder() {
        XCTAssertEqual(LogFlow.summary(carbs: 45, units: 4), "Log 45 g + 4 u")
        XCTAssertEqual(LogFlow.summary(carbs: nil, units: 4.5), "Log 4.5 u")
        XCTAssertEqual(LogFlow.summary(carbs: 0, foodName: " Salad ", units: nil), "Log Salad")
        XCTAssertEqual(LogFlow.summary(carbs: 0, units: nil), "Log food")
        XCTAssertEqual(LogFlow.summary(carbs: nil, units: nil, newSite: true, events: ["Exercise"]), "Log new site + Exercise")
        XCTAssertEqual(LogFlow.summary(carbs: nil, units: nil, events: ["Exercise", "Stress"]), "Log 2 events")
        XCTAssertEqual(LogFlow.summary(carbs: nil, units: nil), "Log")
    }

    func testMissingNamesTheFirstGap() {
        XCTAssertEqual(LogFlow.missing(picked: [], available: injections, foodValid: false, unitsValid: false, hasEvents: false),
                       "Choose what's happening")
        XCTAssertNil(LogFlow.missing(picked: [], available: injections, foodValid: false, unitsValid: false, hasEvents: true))
        XCTAssertEqual(LogFlow.missing(picked: [.insulin, .food], available: injections, foodValid: false, unitsValid: false, hasEvents: false),
                       "Add a food or its carbs")
        XCTAssertEqual(LogFlow.missing(picked: [.insulin, .food], available: injections, foodValid: true, unitsValid: false, hasEvents: false),
                       "Enter the units")
        XCTAssertEqual(LogFlow.missing(picked: [.event], available: injections, foodValid: false, unitsValid: false, hasEvents: false),
                       "Pick what's going on")
        XCTAssertNil(LogFlow.missing(picked: [.food, .site], available: pump, foodValid: true, unitsValid: false, hasEvents: false))
    }

    func testMomentsFollowTherapy() {
        XCTAssertEqual(LogFlow.moments(logsInsulin: true, pump: false), [.eating, .bolus, .basal, .wokeUp, .bedtime, .other])
        XCTAssertEqual(LogFlow.moments(logsInsulin: true, pump: true), [.eating, .bolus, .newSite, .wokeUp, .bedtime, .other])
        XCTAssertEqual(LogFlow.moments(logsInsulin: false, pump: false), [.eating, .wokeUp, .bedtime, .other])
    }

    func testBolusAndBasalShareTheDosePart() {
        XCTAssertTrue(LogFlow.isOn(.bolus, parts: [.insulin], mealtimeDose: true, tags: []))
        XCTAssertFalse(LogFlow.isOn(.basal, parts: [.insulin], mealtimeDose: true, tags: []))
        XCTAssertTrue(LogFlow.isOn(.basal, parts: [.insulin], mealtimeDose: false, tags: []))
        XCTAssertFalse(LogFlow.isOn(.bolus, parts: [.food], mealtimeDose: true, tags: []))
        XCTAssertTrue(LogFlow.isOn(.eating, parts: [.food], mealtimeDose: true, tags: []))
        XCTAssertTrue(LogFlow.isOn(.wokeUp, parts: [], mealtimeDose: true, tags: [.wokeUp]))
        XCTAssertFalse(LogFlow.isOn(.other, parts: [], mealtimeDose: true, tags: [.wokeUp]))
    }

    func testWakingAndSleepingAreNeverBothOn() {
        XCTAssertEqual(LogFlow.toggling(.bedtime, in: [.wokeUp, .exercise]), [.bedtime, .exercise])
        XCTAssertEqual(LogFlow.toggling(.wokeUp, in: [.wokeUp, .exercise]), [.exercise])
        XCTAssertEqual(LogFlow.toggling(.exercise, in: [.wokeUp]), [.wokeUp, .exercise])
    }

    func testSleepAndWakeOnlyMarkATime() {
        XCTAssertFalse(ContextTag.bedtime.affectsResponses)
        XCTAssertFalse(ContextTag.wokeUp.affectsResponses)
        XCTAssertTrue(ContextTag.exercise.affectsResponses)
        XCTAssertEqual(ContextTag.bedtime.reach, 0)
    }

    func testAnUnknownTagIsSkippedNotFatal() throws {
        let json = #"{"id":"6F1E7E0A-0000-4000-8000-000000000001","timestamp":1000,"tags":["exercise","fromTheFuture"],"note":"x"}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        let e = try d.decode(ContextEvent.self, from: Data(json.utf8))
        XCTAssertEqual(e.tags, [.exercise])
        XCTAssertEqual(e.note, "x")
    }

    func testBasalStartsOnTheLastBackgroundInsulin() {
        let rapid = SavedInsulin(name: "NovoRapid", kind: .rapid)
        let lantus = SavedInsulin(name: "Lantus", kind: .long)
        let nph = SavedInsulin(name: "Protaphane", kind: .intermediate)
        XCTAssertNil(InsulinLibrary.preferredBasal(in: [rapid], doses: []))
        XCTAssertEqual(InsulinLibrary.preferredBasal(in: [rapid, nph, lantus], doses: [])?.name, "Lantus")
        let dose = InsulinDose(timestamp: Date(), units: 10, kind: .intermediate, name: "protaphane")
        XCTAssertEqual(InsulinLibrary.preferredBasal(in: [rapid, nph, lantus], doses: [dose])?.name, "Protaphane")
    }
}
