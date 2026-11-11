import XCTest
@testable import GlucOSEngine

/// The bolus calculator's maths and safety gates. Settings in mg/dL so the expected numbers are
/// easy to check by hand: 1 unit per 10 g, 1 unit lowers 40 mg/dL, target 100 mg/dL.
final class BolusCalculatorTests: XCTestCase {
    let now = referenceNow

    func settings(ratio: Double = 10, cf: Double = 40, target: Double = 100, increment: Double = 0.05,
                  max: Double = 15) -> BolusSettings {
        BolusSettings(blocks: [BolusScheduleBlock(startMinute: 0, carbRatio: ratio, correctionFactor: cf, targetMgdl: target)],
                      increment: increment, maxBolus: max, confirmedAt: now.addingTimeInterval(-86_400))
    }

    /// Steady readings at `mgdl` for the last 30 minutes.
    func steady(_ mgdl: Double, endingAgo: TimeInterval = 0) -> [GlucoseReading] {
        readings(endingAt: now.addingTimeInterval(-endingAgo), minutes: 30, step: 1) { _ in mgdl }
    }

    /// Readings changing by `rate` mg/dL per minute, reaching `mgdl` now.
    func moving(to mgdl: Double, rate: Double, trend: Trend = .flat) -> [GlucoseReading] {
        stride(from: 30, through: 0, by: -1).map { m in
            reading(now.addingTimeInterval(-Double(m) * 60), mgdl - rate * Double(m), trend)
        }
    }

    func bolus(_ units: Double, minutesAgo: Double, kind: InsulinKind = .rapid) -> InsulinDose {
        InsulinDose(timestamp: now.addingTimeInterval(-minutesAgo * 60), units: units, kind: kind)
    }

    func suggest(carbs: Double, readings: [GlucoseReading], doses: [InsulinDose] = [], manual: Double? = nil,
                 contexts: [ContextEvent] = [], therapy: TherapyType = .injections,
                 settings s: BolusSettings? = nil) -> BolusSuggestion {
        BolusCalculator.suggest(BolusRequest(carbs: carbs, now: now, readings: readings, manualGlucose: manual,
                                             doses: doses, contexts: contexts, lowMgdl: 70, therapy: therapy),
                                settings: s ?? settings(), calendar: utc)
    }

    func iob(_ doses: [InsulinDose]) -> Double { InsulinActivity.compute(doses: doses, at: now).onBoard }

    // MARK: The sums

    func testFoodOnlyAtTarget() {
        let s = suggest(carbs: 60, readings: steady(100))
        XCTAssertEqual(s.foodUnits, 6, accuracy: 1e-9)
        XCTAssertEqual(s.correctionUnits, 0, accuracy: 1e-9)
        XCTAssertEqual(s.units, 6)
        XCTAssertEqual(s.level, .info)
        XCTAssertFalse(s.isBlocked)
    }

    func testFoodPlusCorrectionAboveTarget() {
        let s = suggest(carbs: 60, readings: steady(180))
        XCTAssertEqual(s.correctionUnits, 2, accuracy: 1e-9)
        XCTAssertEqual(s.units, 8)
    }

    func testInsulinOnBoardComesOffTheCorrectionFirst() {
        let doses = [bolus(3, minutesAgo: 150)]
        let onBoard = iob(doses)
        XCTAssertGreaterThan(onBoard, 0.5)
        XCTAssertLessThan(onBoard, 2)
        let s = suggest(carbs: 60, readings: steady(180), doses: doses)
        XCTAssertEqual(s.insulinOnBoard, onBoard, accuracy: 1e-9)
        XCTAssertEqual(s.insulinOnBoardApplied, onBoard, accuracy: 1e-9)
        XCTAssertEqual(s.calculated, 6 + 2 - onBoard, accuracy: 1e-9)
        XCTAssertEqual(s.units, BolusCalculator.roundDown(8 - onBoard, to: 0.05))
    }

    func testInsulinOnBoardNeverReducesTheFoodDoseWhenHigh() {
        // 1 unit of correction, about 3 on board: the correction goes, the food dose stays.
        let doses = [bolus(4, minutesAgo: 45)]
        XCTAssertGreaterThan(iob(doses), 1)
        let s = suggest(carbs: 60, readings: steady(140), doses: doses)
        XCTAssertEqual(s.correctionUnits, 1, accuracy: 1e-9)
        XCTAssertEqual(s.insulinOnBoardApplied, 1, accuracy: 1e-9)
        XCTAssertEqual(s.units, 6)
    }

    func testBelowTargetReducesTheFoodDose() {
        let s = suggest(carbs: 60, readings: steady(80))
        XCTAssertEqual(s.correctionUnits, -0.5, accuracy: 1e-9)
        XCTAssertEqual(s.units, 5.5)
    }

    func testBelowTargetInsulinOnBoardAlsoComesOffTheFood() {
        let doses = [bolus(2, minutesAgo: 120)]
        let onBoard = iob(doses)
        let s = suggest(carbs: 60, readings: steady(80), doses: doses)
        XCTAssertEqual(s.calculated, 6 - 0.5 - onBoard, accuracy: 1e-9)
        XCTAssertEqual(s.insulinOnBoardApplied, onBoard, accuracy: 1e-9)
    }

    func testNeverNegative() {
        let s = suggest(carbs: 10, readings: steady(75), doses: [bolus(5, minutesAgo: 30)])
        XCTAssertEqual(s.units, 0)
        XCTAssertEqual(s.calculated, 0)
        XCTAssertLessThanOrEqual(s.insulinOnBoardApplied, s.foodUnits + max(0, s.correctionUnits) + 1e-9)
    }

    func testCorrectionOnly() {
        XCTAssertEqual(suggest(carbs: 0, readings: steady(220)).units, 3)
        XCTAssertEqual(suggest(carbs: 0, readings: steady(90)).units, 0)
    }

    func testOnlyFastInsulinGivenBeforeNowCounts() {
        let long = bolus(20, minutesAgo: 60, kind: .long)
        let future = InsulinDose(timestamp: now.addingTimeInterval(600), units: 5, kind: .rapid)
        let s = suggest(carbs: 60, readings: steady(100), doses: [long, future])
        XCTAssertEqual(s.insulinOnBoard, 0, accuracy: 1e-9)
        XCTAssertEqual(s.units, 6)
    }

    // MARK: Rounding and the cap

    func testRoundsDownToTheIncrement() {
        XCTAssertEqual(suggest(carbs: 47, readings: steady(100), settings: settings(increment: 0.5)).units, 4.5)
        XCTAssertEqual(suggest(carbs: 47, readings: steady(100), settings: settings(increment: 1)).units, 4)
        XCTAssertEqual(suggest(carbs: 47, readings: steady(100), settings: settings(increment: 0.1)).units, 4.7)
        XCTAssertEqual(suggest(carbs: 47, readings: steady(100), settings: settings(increment: 0.05)).units, 4.7)
        XCTAssertEqual(suggest(carbs: 49.9, readings: steady(100), settings: settings(increment: 0.5)).units, 4.5)
    }

    func testRoundingIgnoresFloatingPointDust() {
        XCTAssertEqual(BolusCalculator.roundDown(0.3, to: 0.1), 0.3)
        XCTAssertEqual(BolusCalculator.roundDown(0.1 + 0.2, to: 0.1), 0.3)
        XCTAssertEqual(BolusCalculator.roundDown(2.9999999999, to: 0.5), 3)
        XCTAssertEqual(BolusCalculator.roundDown(1.15, to: 0.05), 1.15)
        XCTAssertEqual(BolusCalculator.roundDown(0.04, to: 0.05), 0)
        XCTAssertEqual(BolusCalculator.roundDown(-1, to: 0.5), 0)
        XCTAssertEqual(BolusCalculator.roundDown(.nan, to: 0.5), 0)
    }

    func testCappedAtTheMaximum() {
        let s = suggest(carbs: 200, readings: steady(100), settings: settings(max: 12))
        XCTAssertEqual(s.calculated, 20, accuracy: 1e-9)
        XCTAssertEqual(s.units, 12)
        XCTAssertTrue(s.notices.contains(.capped(calculated: 20, max: 12)))
        XCTAssertEqual(s.level, .caution)
    }

    func testCapIsRoundedDownToo() {
        let s = suggest(carbs: 200, readings: steady(100), settings: settings(increment: 1, max: 7.5))
        XCTAssertEqual(s.units, 7)
    }

    // MARK: Safety gates

    func testBlockedWhenLow() {
        let s = suggest(carbs: 40, readings: steady(65))
        XCTAssertTrue(s.isBlocked)
        XCTAssertEqual(s.units, 0)
        XCTAssertTrue(s.notices.contains(.low(mgdl: 65)))
    }

    func testLowGateNeverBelow3Point9() {
        let request = BolusRequest(carbs: 30, now: now, readings: steady(66), doses: [], lowMgdl: 55, therapy: .injections)
        XCTAssertTrue(BolusCalculator.suggest(request, settings: settings(), calendar: utc).isBlocked)
    }

    func testBlockedWhenFallingFastTowardsALow() {
        // 90 now, falling 3 a minute: about 30 in 20 minutes.
        let s = suggest(carbs: 40, readings: moving(to: 90, rate: -3))
        XCTAssertTrue(s.isBlocked)
        XCTAssertEqual(s.units, 0)
        XCTAssertEqual(s.ratePerMinute ?? 0, -3, accuracy: 0.01)
        XCTAssertTrue(s.notices.contains(.fallingFastTowardsLow))
    }

    func testFallingFastWhileHighLeavesTheCorrectionOutAndTakesInsulinOffTheFood() {
        let doses = [bolus(2, minutesAgo: 90)]
        let onBoard = iob(doses)
        let s = suggest(carbs: 60, readings: moving(to: 250, rate: -2.5), doses: doses)
        XCTAssertFalse(s.isBlocked)
        XCTAssertTrue(s.correctionWithheld)
        XCTAssertTrue(s.notices.contains(.fallingFast))
        XCTAssertEqual(s.calculated, 6 - onBoard, accuracy: 1e-9)
    }

    func testSlowFallDoesNotWithholdTheCorrection() {
        let s = suggest(carbs: 0, readings: moving(to: 220, rate: -1))
        XCTAssertFalse(s.correctionWithheld)
        XCTAssertEqual(s.units, 3)
    }

    func testArrowUsedWhenTooFewReadingsForARate() {
        let one = [reading(now.addingTimeInterval(-60), 90, .fallingQuickly)]
        let s = suggest(carbs: 30, readings: one)
        XCTAssertEqual(s.ratePerMinute, -2.5)
        XCTAssertTrue(s.isBlocked, "90 − 2.5 × 20 is under the low threshold")
    }

    func testStaleReadingGivesNoCorrectionButStillSubtractsInsulinOnBoard() {
        let doses = [bolus(2, minutesAgo: 120)]
        let onBoard = iob(doses)
        let s = suggest(carbs: 60, readings: steady(250, endingAgo: 30 * 60), doses: doses)
        XCTAssertNil(s.glucose)
        XCTAssertEqual(s.correctionUnits, 0)
        XCTAssertEqual(s.calculated, 6 - onBoard, accuracy: 1e-9)
        XCTAssertTrue(s.notices.contains(.staleReading(minutes: 30)))
        XCTAssertEqual(s.level, .caution)
    }

    func testStaleLowIsNotTreatedAsCurrent() {
        // An old low doesn't block (it isn't current), but there's no correction either.
        let s = suggest(carbs: 30, readings: steady(60, endingAgo: 40 * 60))
        XCTAssertFalse(s.isBlocked)
        XCTAssertEqual(s.units, 3)
    }

    func testNoReadings() {
        let s = suggest(carbs: 30, readings: [])
        XCTAssertTrue(s.notices.contains(.noReading))
        XCTAssertEqual(s.units, 3)
    }

    func testTypedGlucoseIsUsedInsteadOfTheSensor() {
        let s = suggest(carbs: 0, readings: steady(250, endingAgo: 30 * 60), manual: 180)
        XCTAssertEqual(s.glucose, 180)
        XCTAssertEqual(s.units, 2)
        XCTAssertTrue(s.notices.contains(.manualGlucose))
        let low = suggest(carbs: 30, readings: steady(150), manual: 60)
        XCTAssertTrue(low.isBlocked, "a typed low blocks too")
    }

    func testNeedsConfirmedValidSettings() {
        var unconfirmed = settings()
        unconfirmed.confirmedAt = nil
        XCTAssertTrue(suggest(carbs: 30, readings: steady(100), settings: unconfirmed).notices.contains(.notSetUp))
        XCTAssertTrue(BolusCalculator.suggest(BolusRequest(carbs: 30, now: now, readings: steady(100), doses: [],
                                                           lowMgdl: 70, therapy: .injections),
                                              settings: nil).isBlocked)
        var off = settings()
        off.disabled = true
        XCTAssertTrue(suggest(carbs: 30, readings: steady(100), settings: off).notices.contains(.turnedOff))
        let bad = settings(ratio: 0)
        let s = suggest(carbs: 30, readings: steady(100), settings: bad)
        XCTAssertTrue(s.isBlocked)
        XCTAssertEqual(s.units, 0)
        XCTAssertFalse(BolusSettings.blank.isUsable, "the starting values can't be used until confirmed")
    }

    func testCarbsOutOfRangeBlocked() {
        XCTAssertTrue(suggest(carbs: 600, readings: steady(100)).notices.contains(.carbsOutOfRange))
        XCTAssertTrue(suggest(carbs: -5, readings: steady(100)).isBlocked)
        XCTAssertTrue(suggest(carbs: .nan, readings: steady(100)).isBlocked)
    }

    // MARK: Notices

    func testNotices() {
        XCTAssertTrue(suggest(carbs: 0, readings: steady(320)).notices.contains(.veryHigh))
        XCTAssertTrue(suggest(carbs: 30, readings: steady(100), therapy: .pump).notices.contains(.pumpInsulinOnBoard))
        XCTAssertTrue(suggest(carbs: 30, readings: steady(100), doses: [bolus(1, minutesAgo: 20)])
            .notices.contains(.recentBolus(minutes: 20)))
        let hypo = ContextEvent(timestamp: now.addingTimeInterval(-20 * 60), tags: [.hypoTreatment])
        XCTAssertTrue(suggest(carbs: 30, readings: steady(100), contexts: [hypo]).notices.contains(.recentLow))
        var dip = steady(100)
        dip[5] = reading(dip[5].timestamp, 62)
        XCTAssertTrue(suggest(carbs: 30, readings: dip).notices.contains(.recentLow))
        let run = ContextEvent(timestamp: now.addingTimeInterval(-2 * 3600), tags: [.exercise])
        XCTAssertTrue(suggest(carbs: 30, readings: steady(100), contexts: [run]).notices.contains(.exercise))
        for n in suggest(carbs: 200, readings: steady(320), therapy: .pump, settings: settings(max: 5)).notices {
            XCTAssertFalse(n.text(unit: .mmol).isEmpty)
        }
    }

    // MARK: Time of day

    func testScheduleBlocksFollowTheClock() {
        let s = BolusSettings(blocks: [
            BolusScheduleBlock(startMinute: 0, carbRatio: 12, correctionFactor: 50, targetMgdl: 110),
            BolusScheduleBlock(startMinute: 6 * 60, carbRatio: 8, correctionFactor: 40, targetMgdl: 100),
            BolusScheduleBlock(startMinute: 18 * 60 + 30, carbRatio: 10, correctionFactor: 45, targetMgdl: 100),
        ], increment: 0.05, maxBolus: 15, confirmedAt: now)
        let midnight = utc.startOfDay(for: now)
        func ratio(_ h: Double) -> Double? { s.block(at: midnight.addingTimeInterval(h * 3600), calendar: utc)?.carbRatio }
        XCTAssertEqual(ratio(0), 12)
        XCTAssertEqual(ratio(5.99), 12)
        XCTAssertEqual(ratio(6), 8)
        XCTAssertEqual(ratio(18.49), 8)
        XCTAssertEqual(ratio(18.5), 10)
        XCTAssertEqual(ratio(23.99), 10)
        XCTAssertTrue(s.problems.isEmpty)
    }

    func testSettingsProblems() {
        var s = settings()
        XCTAssertTrue(s.problems.isEmpty)
        s.blocks[0].startMinute = 60
        XCTAssertFalse(s.problems.isEmpty, "must start at midnight")
        s = settings()
        s.blocks.append(BolusScheduleBlock(startMinute: 0, carbRatio: 10, correctionFactor: 40, targetMgdl: 100))
        XCTAssertFalse(s.problems.isEmpty, "two blocks at the same time")
        XCTAssertFalse(settings(cf: 2).problems.isEmpty, "a mmol/L value typed as mg/dL")
        XCTAssertFalse(settings(target: 6).problems.isEmpty)
        XCTAssertFalse(settings(increment: 0.3).problems.isEmpty)
        XCTAssertFalse(settings(max: 0).problems.isEmpty)
        XCTAssertFalse(settings(max: 50).problems.isEmpty)
    }

    func testSettingsRoundTripThroughJSON() throws {
        let s = settings()
        let back = try JSONDecoder().decode(BolusSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    func testCalculationRecordsWhatWasUsed() {
        let s = suggest(carbs: 60, readings: steady(180))
        let c = BolusCalculation(s)
        XCTAssertEqual(c.carbs, 60)
        XCTAssertEqual(c.glucose, 180)
        XCTAssertEqual(c.carbRatio, 10)
        XCTAssertEqual(c.suggestedUnits, 8)
        let withheld = BolusCalculation(suggest(carbs: 60, readings: moving(to: 250, rate: -2.5)))
        XCTAssertEqual(withheld.correctionUnits, 0)
    }

    func testMmolSettingsGiveTheSameAnswer() {
        // 1:10, 2 mmol/L per unit, target 6 mmol/L; glucose 10 mmol/L → 6 + 2 = 8 units.
        let m = GlucoseUnit.mgdlPerMmol
        let s = suggest(carbs: 60, readings: steady(10 * m), settings: settings(cf: 2 * m, target: 6 * m))
        XCTAssertEqual(s.units, 8)
    }

    // MARK: A suggestion that was used

    func testUsedSuggestionFallsWhenANewLowArrives() {
        let used = suggest(carbs: 45, readings: steady(140))
        XCTAssertTrue(used.stillStands(given: used))
        XCTAssertFalse(used.stillStands(given: suggest(carbs: 45, readings: steady(60))))
        XCTAssertFalse(used.stillStands(given: nil))
    }

    func testUsedSuggestionFallsWhenItWouldNowBeLess() {
        let used = suggest(carbs: 45, readings: steady(180))
        XCTAssertFalse(used.stillStands(given: suggest(carbs: 45, readings: steady(120))))
        XCTAssertFalse(used.stillStands(given: suggest(carbs: 30, readings: steady(180))))
        XCTAssertFalse(used.stillStands(given: suggest(carbs: 45, readings: steady(180), settings: settings(ratio: 15))))
        XCTAssertTrue(used.stillStands(given: suggest(carbs: 45, readings: steady(200))))
    }

    func testUsedSuggestionFallsWhenItsReadingGoesStale() {
        // Taken with a 14-minute-old reading; by the time it's logged the reading is 16 minutes old.
        let used = suggest(carbs: 45, readings: steady(220, endingAgo: 14 * 60))
        XCTAssertGreaterThan(used.correctionUnits, 0)
        let later = suggest(carbs: 45, readings: steady(220, endingAgo: 16 * 60))
        XCTAssertFalse(used.stillStands(given: later))
    }
}

