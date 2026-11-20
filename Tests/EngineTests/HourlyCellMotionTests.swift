import XCTest
@testable import GlucOSEngine

/// The hourly in-range card's fill wave and period cross-fade timing (`HourlyCellMotion`).
final class HourlyCellMotionTests: XCTestCase {
    func testFillRunsLeftToRight() {
        let delays = (0..<24).map { HourlyCellMotion.fillDelay(position: $0, count: 24) }
        XCTAssertEqual(delays.first!, HourlyCellMotion.fillLead, accuracy: 1e-9)
        XCTAssertEqual(delays.last!, HourlyCellMotion.fillLead + HourlyCellMotion.fillSpread, accuracy: 1e-9)
        XCTAssertEqual(delays, delays.sorted())
        XCTAssertEqual(Set(delays).count, 24)
    }

    func testOneRowAndTwoRowsTakeTheSameTime() {
        XCTAssertEqual(HourlyCellMotion.fillDelay(position: 23, count: 24),
                       HourlyCellMotion.fillDelay(position: 11, count: 12), accuracy: 1e-9)
        XCTAssertEqual(HourlyCellMotion.recolourDelay(position: 23, count: 24),
                       HourlyCellMotion.recolourDelay(position: 11, count: 12), accuracy: 1e-9)
    }

    func testRecolourStaggerIsShort() {
        XCTAssertEqual(HourlyCellMotion.recolourDelay(position: 0, count: 24), 0)
        XCTAssertLessThan(HourlyCellMotion.recolourDelay(position: 23, count: 24)
                          + HourlyCellMotion.recolourDuration, 0.6)
        let delays = (0..<12).map { HourlyCellMotion.recolourDelay(position: $0, count: 12) }
        XCTAssertEqual(delays, delays.sorted())
    }

    func testOutOfRangePositionsClamp() {
        XCTAssertEqual(HourlyCellMotion.fillDelay(position: -3, count: 24), HourlyCellMotion.fillLead)
        XCTAssertEqual(HourlyCellMotion.fillDelay(position: 99, count: 24),
                       HourlyCellMotion.fillDelay(position: 23, count: 24))
        XCTAssertEqual(HourlyCellMotion.recolourDelay(position: 0, count: 1), 0)
    }

    func testReduceMotionFadesEveryCellTogether() {
        let fills = Set((0..<24).map { HourlyCellMotion.fillDelay(position: $0, count: 24, reduceMotion: true) })
        XCTAssertEqual(fills, [HourlyCellMotion.fillLead])
        let recolours = Set((0..<12).map { HourlyCellMotion.recolourDelay(position: $0, count: 12, reduceMotion: true) })
        XCTAssertEqual(recolours, [0])
        XCTAssertEqual(HourlyCellMotion.recolourLength(reduceMotion: true), HourlyCellMotion.reducedFade)
        XCTAssertLessThanOrEqual(HourlyCellMotion.reducedFade, 0.3)
    }

    func testWithoutReduceMotionTheWaveIsUnchanged() {
        for p in 0..<24 {
            XCTAssertEqual(HourlyCellMotion.fillDelay(position: p, count: 24, reduceMotion: false),
                           HourlyCellMotion.fillDelay(position: p, count: 24))
            XCTAssertEqual(HourlyCellMotion.recolourDelay(position: p, count: 24, reduceMotion: false),
                           HourlyCellMotion.recolourDelay(position: p, count: 24))
        }
        XCTAssertEqual(HourlyCellMotion.recolourLength(reduceMotion: false), HourlyCellMotion.recolourDuration)
    }
}
