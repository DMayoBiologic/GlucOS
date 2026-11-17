import XCTest
@testable import GlucOSEngine

final class TargetRangePreviewTests: XCTestCase {
    private var midnight: Date { utc.startOfDay(for: referenceNow) }

    /// One reading every 5 minutes from midnight for `minutes`, cycling through `values`.
    private func today(_ values: [Double], minutes: Int) -> [GlucoseReading] {
        (0..<(minutes / 5)).map { i in reading(midnight.addingTimeInterval(Double(i * 5 + 1) * 60), values[i % values.count]) }
    }

    func testNilUntilHalfAnHour() {
        let now = midnight.addingTimeInterval(3600)
        XCTAssertNil(TargetRangePreview.today([], now: now, calendar: utc))
        XCTAssertNil(TargetRangePreview.today(today([120], minutes: 25), now: now, calendar: utc))
        XCTAssertNotNil(TargetRangePreview.today(today([120], minutes: 30), now: now, calendar: utc))
    }

    func testOnlyTodayCounts() throws {
        let yesterday = (1...60).map { reading(midnight.addingTimeInterval(Double(-$0) * 300), 300) }
        let now = midnight.addingTimeInterval(4 * 3600)
        let p = try XCTUnwrap(TargetRangePreview.today(yesterday + today([120], minutes: 60), now: now, calendar: utc))
        XCTAssertEqual(p.start, midnight)
        XCTAssertEqual(p.end, now)
        XCTAssertEqual(p.points.count, 12)
        XCTAssertEqual(p.timeInRange(low: 70, high: 180), 1)
    }

    func testFigureFollowsTheRangeBeingSet() throws {
        // A quarter each at 65, 100, 150 and 200.
        let r = today([65, 100, 150, 200], minutes: 240)
        let p = try XCTUnwrap(TargetRangePreview.today(r, now: midnight.addingTimeInterval(5 * 3600), calendar: utc))
        XCTAssertEqual(p.timeInRange(low: 70, high: 180), 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.timeInRange(low: 63, high: 180), 0.75, accuracy: 1e-9)
        XCTAssertEqual(p.timeInRange(low: 63, high: 250), 1, accuracy: 1e-9)
        // Inclusive at both limits, like everywhere else.
        XCTAssertEqual(p.timeInRange(low: 100, high: 150), 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.spoken(low: 70, high: 180), "Today so far, 50% in range with this target range")
    }

    func testAxisStaysStillAcrossEveryAllowedRange() throws {
        let p = try XCTUnwrap(TargetRangePreview.today(today([120], minutes: 60),
                                                       now: midnight.addingTimeInterval(3600), calendar: utc))
        XCTAssertLessThan(p.yDomain.lowerBound, 54)
        XCTAssertGreaterThan(p.yDomain.upperBound, 300)
        let high = try XCTUnwrap(TargetRangePreview.today(today([380], minutes: 60),
                                                          now: midnight.addingTimeInterval(3600), calendar: utc))
        XCTAssertGreaterThan(high.yDomain.upperBound, 380)
    }

    func testEndReachesALateReading() throws {
        let r = today([120], minutes: 60)
        let early = midnight.addingTimeInterval(30 * 60)
        let p = try XCTUnwrap(TargetRangePreview.today(r, now: early, calendar: utc))
        XCTAssertEqual(p.end, try XCTUnwrap(p.points.last).date)
    }
}
