import XCTest
@testable import GlucOSEngine

/// How the popover's forecast draws in and bends from one forecast into the next.
final class ForecastMorphTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// A forecast every 5 minutes from `from`, `count` points, rising by `step` each.
    private func forecast(from: Date, count: Int, base: Double = 120, step: Double = 2) -> [ForecastSample] {
        (0..<count).map { i in
            let mg = base + Double(i) * step
            return ForecastSample(date: from.addingTimeInterval(Double(i) * 300), mgdl: mg,
                                  lowerMgdl: mg - Double(i) * 3, upperMgdl: mg + Double(i) * 3)
        }
    }

    private func strictlyIncreasing(_ f: [ForecastSample]) -> Bool {
        zip(f, f.dropFirst()).allSatisfy { $0.date < $1.date }
    }

    func testBlendEndsAreTheTwoForecasts() {
        let a = forecast(from: start, count: 13)
        let b = forecast(from: start.addingTimeInterval(300), count: 13, base: 130, step: -1)
        XCTAssertEqual(ForecastMorph.blend(from: a, to: b, t: 0), a)
        XCTAssertEqual(ForecastMorph.blend(from: a, to: b, t: 1), b)
        XCTAssertEqual(ForecastMorph.blend(from: a, to: b, t: 1.3), b)   // a spring's overshoot
    }

    func testHalfwaySlidesAndBendsEveryPoint() {
        let a = forecast(from: start, count: 13)
        let b = forecast(from: start.addingTimeInterval(300), count: 13, base: 140, step: 0)
        let mid = ForecastMorph.blend(from: a, to: b, t: 0.5)
        XCTAssertEqual(mid.count, 13)
        XCTAssertEqual(mid[0].date, start.addingTimeInterval(150))
        XCTAssertEqual(mid[0].mgdl, 130, accuracy: 1e-9)
        XCTAssertEqual(mid[12].mgdl, (144 + 140) / 2, accuracy: 1e-9)
        XCTAssertEqual(mid[12].upperMgdl, (180 + 176) / 2, accuracy: 1e-9)
    }

    func testLongerForecastReachesOutFromTheOldEnd() {
        let a = forecast(from: start, count: 7)     // 30 minutes
        let b = forecast(from: start, count: 13)    // 60 minutes
        let early = ForecastMorph.blend(from: a, to: b, t: 0.01)
        XCTAssertTrue(strictlyIncreasing(early))
        XCTAssertEqual(early.last!.date.timeIntervalSince(a.last!.date), 0.01 * 1800, accuracy: 1e-6)
        let mid = ForecastMorph.blend(from: a, to: b, t: 0.5)
        XCTAssertEqual(mid.count, 13)
        XCTAssertTrue(strictlyIncreasing(mid))
    }

    func testShorterForecastPullsBackIntoTheNewEnd() {
        let a = forecast(from: start, count: 13)
        let b = forecast(from: start, count: 7)
        let mid = ForecastMorph.blend(from: a, to: b, t: 0.5)
        XCTAssertEqual(mid.count, 13)
        XCTAssertTrue(strictlyIncreasing(mid))
        let late = ForecastMorph.blend(from: a, to: b, t: 0.999)
        XCTAssertTrue(strictlyIncreasing(late))
        XCTAssertEqual(ForecastMorph.blend(from: a, to: b, t: 1), b)
    }

    func testNothingToBlendFromOrToJustChanges() {
        let b = forecast(from: start, count: 13)
        XCTAssertEqual(ForecastMorph.blend(from: [], to: b, t: 0.3), b)
        XCTAssertEqual(ForecastMorph.blend(from: b, to: [], t: 0.3), [])
    }

    func testRevealGrowsFromTheStartingReading() {
        let f = forecast(from: start, count: 13)
        XCTAssertEqual(ForecastMorph.revealed(f, progress: 0), [f[0]])
        XCTAssertEqual(ForecastMorph.revealed(f, progress: 1), f)
        XCTAssertEqual(ForecastMorph.revealed(f, progress: 2), f)
        let part = ForecastMorph.revealed(f, progress: 0.5)        // 30 of 60 minutes
        XCTAssertEqual(part.count, 7)
        XCTAssertEqual(part.last, f[6])
        let between = ForecastMorph.revealed(f, progress: 0.55)   // 33 minutes: 7 samples + an end
        XCTAssertEqual(between.count, 8)
        XCTAssertEqual(between.last!.date, start.addingTimeInterval(33 * 60))
        XCTAssertEqual(between.last!.mgdl, f[6].mgdl + 0.6 * 2, accuracy: 1e-9)
        XCTAssertTrue(strictlyIncreasing(between))
    }

    func testRevealLeavesTinyForecastsAlone() {
        XCTAssertEqual(ForecastMorph.revealed([], progress: 0.5), [])
        let one = forecast(from: start, count: 1)
        XCTAssertEqual(ForecastMorph.revealed(one, progress: 0), one)
    }
}
