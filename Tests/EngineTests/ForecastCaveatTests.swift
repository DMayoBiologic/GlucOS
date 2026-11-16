import XCTest
@testable import GlucOSEngine

/// The one line that says why a forecast is hidden, trend-only, shorter or wider than usual.
final class ForecastCaveatTests: XCTestCase {
    let now = referenceNow
    let learned = EffectProfile(insulin: LearnedEffect(value: 50, standardError: 3, examples: 20),
                                carbs: LearnedEffect(value: 4, standardError: 0.3, examples: 20),
                                driftPerHour: [0, 0, 0, 0], days: 30, intervals: 1000, learnedAt: referenceNow)

    func flat(_ mgdl: Double = 120, endingAt end: Date? = nil) -> [GlucoseReading] {
        readings(endingAt: end ?? now, minutes: 30) { _ in mgdl }
    }

    func caveat(_ r: [GlucoseReading], doses: [InsulinDose] = [], meals: [MealEntry] = [],
                contexts: [ContextEvent] = [], profile: EffectProfile = .empty,
                calibration: ForecastCalibration? = nil) -> ForecastCaveat? {
        ForecastCaveat.pick(GlucoseForecaster.forecast(
            ForecastInputs(readings: GlucoseSeries(r), doses: doses, meals: meals, contexts: contexts,
                           profile: profile, calibration: calibration, now: now)))
    }

    func stats(_ m: Int, beats: Bool) -> HorizonStats {
        HorizonStats(minutes: m, samples: 40, meanAbsoluteError: beats ? 8 : 30, naiveError: 20, bias: 0,
                     lower: -Double(m), upper: Double(m))
    }

    /// Checked and good for every horizon, so nothing about the range or reach needs saying.
    var goodCalibration: ForecastCalibration {
        let all = ForecastCalibration.horizons.map { stats($0, beats: true) }
        return ForecastCalibration(byBasis: [.trend: all, .trendInsulinCarbs: all], origins: 100, computedAt: now)
    }

    func testAnOrdinaryForecastHasNoCaveat() {
        XCTAssertNil(caveat(flat(), calibration: goodCalibration))
    }

    func testStaleReadingIsHidden() {
        let c = caveat(flat(endingAt: now.addingTimeInterval(-40 * 60)))
        XCTAssertEqual(c?.kind, .hidden)
        XCTAssertEqual(c?.source, "unavailable:stale")
        XCTAssertEqual(c?.text, ForecastUnavailable.stale(age: 0).message)
    }

    func testFreshLogIsTrendOnly() {
        let meal = MealEntry(timestamp: now.addingTimeInterval(-20 * 60), carbs: 40)
        let c = caveat(flat(), meals: [meal], profile: learned, calibration: goodCalibration)
        XCTAssertEqual(c?.kind, .trendOnly)
        XCTAssertEqual(c?.source, ForecastLimitation.freshLog.code)
        XCTAssertEqual(c?.text, ForecastLimitation.freshLog.shortReason)
        XCTAssertEqual(c?.detail, ForecastLimitation.freshLog.message)
    }

    func testUncountedFoodOutranksStillLearning() {
        let dose = InsulinDose(timestamp: now.addingTimeInterval(-30 * 60), units: 3, kind: .rapid)
        let toast = MealEntry(timestamp: now.addingTimeInterval(-20 * 60), carbs: 0, food: "Toast")
        let c = caveat(flat(150), doses: [dose], meals: [toast])
        XCTAssertEqual(c?.kind, .trendOnly)
        XCTAssertEqual(c?.source, ForecastLimitation.uncountedFood.code)
    }

    func testUncheckedModelSaysWhyItStopsAtAnHour() {
        let meal = MealEntry(timestamp: now.addingTimeInterval(-70 * 60), carbs: 40)
        let c = caveat(flat(), meals: [meal], profile: learned)
        XCTAssertEqual(c?.kind, .shortened)
        XCTAssertEqual(c?.source, "uncalibratedHorizon")
        XCTAssertTrue(c?.text.hasPrefix("Drawn only 1 h ahead") == true, c?.text ?? "")
    }

    func testHorizonCutByPastAccuracyIsShortened() {
        var cal = goodCalibration
        cal.byBasis[.trendInsulinCarbs] = ForecastCalibration.horizons.map { stats($0, beats: $0 <= 45) }
        let meal = MealEntry(timestamp: now.addingTimeInterval(-70 * 60), carbs: 40)
        let c = caveat(flat(), meals: [meal], profile: learned, calibration: cal)
        XCTAssertEqual(c?.kind, .shortened)
        XCTAssertEqual(c?.source, "calibratedHorizon")
        XCTAssertTrue(c?.text.hasPrefix("Drawn only 45 min ahead") == true, c?.text ?? "")
    }

    func testNotAccurateEnoughIsHidden() {
        var cal = goodCalibration
        cal.byBasis[.trend] = ForecastCalibration.horizons.map { stats($0, beats: false) }
        let c = caveat(flat(), calibration: cal)
        XCTAssertEqual(c?.kind, .hidden)
        XCTAssertEqual(c?.source, "unavailable:notAccurateEnough")
    }

    func testContextWidensAndSaysWhich() {
        let run = ContextEvent(timestamp: now.addingTimeInterval(-3600), tags: [.exercise])
        let c = caveat(flat(), contexts: [run])
        XCTAssertEqual(c?.kind, .widened)
        XCTAssertEqual(c?.source, ForecastLimitation.context(.exercise).code)
        XCTAssertEqual(c?.text, "Wider range: \(ContextTag.exercise.title) is logged.")
    }

    func testUncheckedTrendSaysTheRangeIsCautious() {
        let c = caveat(flat())
        XCTAssertEqual(c?.kind, .widened)
        XCTAssertEqual(c?.source, ForecastLimitation.uncalibrated.code)
    }

    func testEveryLimitationHasOneShortLine() {
        let all: [ForecastLimitation] = [.insulinNotLearned, .carbsNotLearned, .uncountedFood, .deliveryProblem,
                                         .context(.exercise), .rapidChange, .backgroundInsulin, .uncalibrated, .freshLog,
                                         .liveHorizon(shownMinutes: 150, failedAt: 180), .liveHorizon(shownMinutes: 0, failedAt: 15)]
        for l in all {
            XCTAssertFalse(l.shortReason.contains("\n"), l.code)
            XCTAssertLessThanOrEqual(l.shortReason.count, 80, l.code)
            XCTAssertLessThan(l.shortReason.count, l.message.count, l.code)
        }
    }

    func testSnapshotCarriesTheCaveat() {
        let meal = MealEntry(timestamp: now.addingTimeInterval(-20 * 60), carbs: 40)
        var model = OutlookModel.empty
        model.profile = learned
        model.calibration = goodCalibration
        let o = OutlookEngine.outlook(readings: flat(), doses: [], meals: [meal], contexts: [], model: model, now: now)
        XCTAssertEqual(o.snapshot(lowMgdl: 70).caveat?.source, ForecastLimitation.freshLog.code)
    }

    // MARK: Cut by this device's live checks

    func liveCaveat(_ cut: ForecastLiveHorizon.Cut) -> ForecastCaveat? {
        var input = ForecastInputs(readings: GlucoseSeries(flat()), doses: [], meals: [], contexts: [], profile: .empty,
                                   calibration: goodCalibration, now: now)
        input.liveHorizon = ForecastLiveHorizon(byBasis: [.trend: cut])
        return ForecastCaveat.pick(GlucoseForecaster.forecast(input))
    }

    func testLiveCutIsShortenedAndSaysWhy() {
        let c = liveCaveat(.init(shownMinutes: 15, failedAt: 30))
        XCTAssertEqual(c?.kind, .shortened)
        XCTAssertEqual(c?.text, "Drawn only 15 min ahead: recent 30-min forecasts here lost to no change.")
        XCTAssertEqual(c?.source, "liveHorizon:15")
    }

    func testLiveCutToNothingIsHidden() {
        let c = liveCaveat(.init(shownMinutes: 0, failedAt: 15))
        XCTAssertEqual(c?.kind, .hidden)
        XCTAssertEqual(c?.text, "Hidden: recent 15-min forecasts here lost to no change.")
    }
}
