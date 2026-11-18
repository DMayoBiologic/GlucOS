import XCTest
@testable import GlucOSEngine

/// The forecast details card's contents (`ForecastDetails`, round 73).
final class ForecastDetailsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A forecast every 5 minutes out to `minutes`, rising 1 mg/dL a minute from 120, with a range
    /// widening 0.5 mg/dL a minute either side.
    private func outlook(minutes: Int = 60, basis: ForecastBasis = .trend, insulin: Double? = nil,
                         carbs: Double? = nil) -> OutlookSnapshot {
        let samples = stride(from: 0, through: minutes, by: 5).map { m -> ForecastSample in
            let mid = 120 + Double(m)
            return ForecastSample(date: t0.addingTimeInterval(Double(m) * 60), mgdl: mid,
                                  lowerMgdl: mid - Double(m) * 0.5, upperMgdl: mid + Double(m) * 0.5)
        }
        return OutlookSnapshot(issuedAt: t0, basis: basis, forecast: samples, insulinOnBoard: insulin,
                               carbsOnBoard: carbs)
    }

    private let held = [ForecastDetails.HitRate(minutes: 15, share: 0.81, checks: 96),
                        ForecastDetails.HitRate(minutes: 30, share: 0.742, checks: 64),
                        ForecastDetails.HitRate(minutes: 60, share: 0.66, checks: 31)]

    func testNoForecastNoCard() {
        XCTAssertNil(ForecastDetails(outlook: OutlookSnapshot(issuedAt: t0, basis: .trend), held: held))
        XCTAssertNil(ForecastDetails(outlook: outlook(minutes: 0), held: held))
    }

    func testShows30And60WithTheirRangeAndHitRate() throws {
        let d = try XCTUnwrap(ForecastDetails(outlook: outlook(), held: held))
        XCTAssertEqual(d.horizons.map(\.minutes), [30, 60])
        let h30 = d.horizons[0]
        XCTAssertEqual(h30.mgdl, 150)
        XCTAssertEqual(h30.lowerMgdl, 135)
        XCTAssertEqual(h30.upperMgdl, 165)
        XCTAssertEqual(h30.held?.percent, 74)
        XCTAssertEqual(h30.held?.checks, 64)
        XCTAssertEqual(d.horizons[1].held?.percent, 66)
        XCTAssertEqual(ForecastDetails.heading(h30), "In 30 min")
        XCTAssertEqual(ForecastDetails.value(h30, unit: .mgdl), "150 mg/dL")
        XCTAssertEqual(ForecastDetails.range(h30, unit: .mgdl), "Likely 135–165")
        XCTAssertEqual(ForecastDetails.range(h30, unit: .mmol), "Likely 7.5–9.2")
        XCTAssertEqual(ForecastDetails.held(h30), "Range held 74% of 64 recent checks")
    }

    func testAHorizonWithTooFewChecksSaysSo() throws {
        let d = try XCTUnwrap(ForecastDetails(outlook: outlook(), held: Array(held.prefix(2))))
        XCTAssertNil(d.horizons[1].held)
        XCTAssertEqual(ForecastDetails.held(d.horizons[1]), "Too few recent checks to say how often the range held")
        // No scorecard yet at all: every row says so, and the card still opens.
        let none = try XCTUnwrap(ForecastDetails(outlook: outlook(), held: []))
        XCTAssertTrue(none.horizons.allSatisfy { $0.held == nil })
    }

    func testAShortenedForecastShowsWhatItReaches() throws {
        // Cut at 45 minutes: 30 only.
        let d45 = try XCTUnwrap(ForecastDetails(outlook: outlook(minutes: 45), held: held))
        XCTAssertEqual(d45.horizons.map(\.minutes), [30])
        // Cut at 20 minutes: its last point, with no hit rate for a distance the scorecard doesn't keep.
        let d20 = try XCTUnwrap(ForecastDetails(outlook: outlook(minutes: 20), held: held))
        XCTAssertEqual(d20.horizons.map(\.minutes), [20])
        XCTAssertNil(d20.horizons[0].held)
        // Cut at 15: the scorecard's 15-minute figure.
        let d15 = try XCTUnwrap(ForecastDetails(outlook: outlook(minutes: 15), held: held))
        XCTAssertEqual(d15.horizons.first?.held?.percent, 81)
    }

    func testDriverFollowsWhatMovedTheForecast() throws {
        XCTAssertEqual(try XCTUnwrap(ForecastDetails(outlook: outlook(), held: held)).driver, .trend)
        let both = outlook(basis: .trendInsulinCarbs, insulin: 2.1, carbs: 30)
        XCTAssertEqual(try XCTUnwrap(ForecastDetails(outlook: both, held: held)).driver, .trendMealAndInsulin)
        XCTAssertEqual(ForecastDetails.Driver.of(basis: .trendInsulinCarbs, insulinActing: true, carbsActing: false), .trendAndInsulin)
        XCTAssertEqual(ForecastDetails.Driver.of(basis: .trendInsulinCarbs, insulinActing: false, carbsActing: true), .trendAndMeal)
        XCTAssertEqual(ForecastDetails.Driver.of(basis: .trendInsulinCarbs, insulinActing: false, carbsActing: false), .trend)
        // A trend-only forecast with insulin logged: the insulin didn't move it.
        let trendOnly = outlook(basis: .trend, insulin: 2.1, carbs: 30)
        XCTAssertEqual(try XCTUnwrap(ForecastDetails(outlook: trendOnly, held: held)).driver, .trend)
        // Tiny leftovers don't count, as elsewhere (`showsInsulin`, `showsCarbs`).
        let tiny = outlook(basis: .trendInsulinCarbs, insulin: 0.01, carbs: 0.5)
        XCTAssertEqual(try XCTUnwrap(ForecastDetails(outlook: tiny, held: held)).driver, .trend)
    }

    func testNeverAdvice() throws {
        let d = try XCTUnwrap(ForecastDetails(outlook: outlook(basis: .trendInsulinCarbs, insulin: 2, carbs: 20), held: held))
        let lines = ForecastDetails.Driver.allCases.map(\.line)
            + [ForecastDetails.footnote, ForecastDetails.spoken(d, unit: .mmol)]
            + d.horizons.map(ForecastDetails.held)
        let advice = ["should", "take ", "eat", "dose", "bolus", "correct", "treat", "recommend", "need"]
        for line in lines {
            for word in advice {
                XCTAssertFalse(line.lowercased().contains(word), "\"\(line)\" contains \"\(word)\"")
            }
        }
    }

    func testVoiceOverReadsTheWholeCardInOneSentence() throws {
        let d = try XCTUnwrap(ForecastDetails(outlook: outlook(), held: Array(held.prefix(2))))
        XCTAssertEqual(ForecastDetails.spoken(d, unit: .mgdl),
                       "Forecast. In 30 minutes, about 150 milligrams per decilitre, likely between 135 and 165. "
                       + "The range held 74% of the time in 64 recent checks. "
                       + "In 60 minutes, about 180 milligrams per decilitre, likely between 150 and 210. "
                       + "Too few recent checks to say how often the range held. "
                       + "Based on the recent trend. An estimate, not a reading.")
    }

    func testOutlinePadsAThinRangeAroundTheLine() {
        // y grows downwards: top < line < bottom.
        let points = [ForecastDetails.PlotPoint(x: 0, top: 100, bottom: 100, line: 100),
                      ForecastDetails.PlotPoint(x: 50, top: 40, bottom: 120, line: 80)]
        let outline = ForecastDetails.outline(points, slop: 12, minimumHalfHeight: 16)
        XCTAssertEqual(outline.map(\.x), [0, 50, 50, 0])
        // A range with no width still gets the minimum either side of the line.
        XCTAssertEqual(outline[0].y, 84)
        XCTAssertEqual(outline[3].y, 116)
        // A wide one gets the slop past its edges.
        XCTAssertEqual(outline[1].y, 28)
        XCTAssertEqual(outline[2].y, 132)
        XCTAssertTrue(ForecastDetails.outline(Array(points.prefix(1))).isEmpty)
    }

    func testAnchorIsTheTappedPointOrThirtyMinutes() {
        let f = outlook().forecast
        XCTAssertEqual(ForecastDetails.anchor(tapped: t0.addingTimeInterval(17 * 60), in: f)?.date,
                       t0.addingTimeInterval(15 * 60))
        XCTAssertEqual(ForecastDetails.anchor(tapped: nil, in: f)?.date, t0.addingTimeInterval(30 * 60))
        // Shorter than 30 minutes: its end.
        XCTAssertEqual(ForecastDetails.anchor(tapped: nil, in: outlook(minutes: 20).forecast)?.date,
                       t0.addingTimeInterval(20 * 60))
        XCTAssertNil(ForecastDetails.anchor(tapped: nil, in: []))
    }
}
