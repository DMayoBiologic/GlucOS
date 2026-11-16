import XCTest
@testable import GlucOSEngine

/// How the main reading on the app's own screens changes to the next one (`ReadingRoll`).
final class ReadingRollTests: XCTestCase {
    private enum Band: Equatable { case inRange, high }

    func testNewFigureInTheSameRangeRolls() {
        XCTAssertEqual(ReadingRoll.between(from: (mgdl: 120, band: Band.inRange), to: (mgdl: 126, band: .inRange),
                                           reduceMotion: false), .roll)
    }

    func testCrossingARangeEdgeMovesFigureAndColourTogether() {
        XCTAssertEqual(ReadingRoll.between(from: (mgdl: 178, band: Band.inRange), to: (mgdl: 184, band: .high),
                                           reduceMotion: false), .recolour)
        // The colour alone changing (going stale, say) takes the colour fade too.
        XCTAssertEqual(ReadingRoll.between(from: (mgdl: 184, band: Band.high), to: (mgdl: 184, band: .inRange),
                                           reduceMotion: false), .recolour)
    }

    func testNothingChangedPlaysNothing() {
        XCTAssertEqual(ReadingRoll.between(from: (mgdl: 120, band: Band.inRange), to: (mgdl: 120, band: .inRange),
                                           reduceMotion: false), .none)
        XCTAssertEqual(ReadingRoll.between(from: (mgdl: 120, band: Band.inRange), to: (mgdl: 120, band: .inRange),
                                           reduceMotion: true), .none)
    }

    func testFirstFigureDrawnDoesNotRoll() {
        XCTAssertEqual(ReadingRoll.between(from: nil, to: (mgdl: 120, band: Band.inRange), reduceMotion: false), .none)
    }

    func testReduceMotionJustChanges() {
        XCTAssertEqual(ReadingRoll.between(from: (mgdl: 120, band: Band.inRange), to: (mgdl: 126, band: .inRange),
                                           reduceMotion: true), .instant)
        XCTAssertEqual(ReadingRoll.between(from: (mgdl: 178, band: Band.inRange), to: (mgdl: 184, band: .high),
                                           reduceMotion: true), .instant)
    }
}
