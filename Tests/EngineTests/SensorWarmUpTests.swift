import XCTest
@testable import GlucOSEngine

final class SensorWarmUpTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func sensor(_ activated: Date) -> SensorInfo {
        SensorInfo(serial: "0M0001ABCDE", activated: activated, lifetimeDays: 15)
    }

    func testNewSensorWithOnlyTheOldSensorsReadingIsWarmingUp() throws {
        let old = GlucoseReading(timestamp: start.addingTimeInterval(-2 * 3600), mgdl: 110, trend: .flat)
        let now = start.addingTimeInterval(18 * 60)
        let w = try XCTUnwrap(SensorWarmUp.current(sensor: sensor(start), current: old, at: now))
        XCTAssertEqual(w.endsAt, start.addingTimeInterval(3600))
        XCTAssertEqual(w.minutesLeft(at: now), 42)
        XCTAssertEqual(w.headline(at: now), "Readings start in about 42 min")
        XCTAssertEqual(w.fraction(at: now), 0.3, accuracy: 0.0001)
    }

    func testNoReadingAtAllDuringTheHourIsWarmingUp() {
        XCTAssertNotNil(SensorWarmUp.current(sensor: sensor(start), current: nil, at: start.addingTimeInterval(60)))
    }

    func testMinutesRoundUpAndNeverSayZeroEarly() throws {
        let w = SensorWarmUp(startedAt: start)
        XCTAssertEqual(w.minutesLeft(at: start.addingTimeInterval(3600 - 20)), 1)
        XCTAssertEqual(w.headline(at: start.addingTimeInterval(3600 - 20)), "Readings start in about 1 min")
        XCTAssertEqual(w.headline(at: start.addingTimeInterval(3600 + 60)), "Readings start any minute now")
        XCTAssertEqual(w.fraction(at: start.addingTimeInterval(2 * 3600)), 1)
    }

    func testTheFirstReadingOfTheNewSensorEndsTheWarmUp() {
        let first = GlucoseReading(timestamp: start.addingTimeInterval(3600), mgdl: 120, trend: .flat)
        XCTAssertNil(SensorWarmUp.current(sensor: sensor(start), current: first, at: start.addingTimeInterval(3610)))
    }

    func testGivesUpAfterTheGraceAndIgnoresOldSensorsAndFutureStarts() {
        XCTAssertNotNil(SensorWarmUp.current(sensor: sensor(start), current: nil,
                                             at: start.addingTimeInterval(SensorWarmUp.duration + SensorWarmUp.grace - 1)))
        XCTAssertNil(SensorWarmUp.current(sensor: sensor(start), current: nil,
                                          at: start.addingTimeInterval(SensorWarmUp.duration + SensorWarmUp.grace)))
        XCTAssertNil(SensorWarmUp.current(sensor: sensor(start.addingTimeInterval(-3 * 86_400)), current: nil, at: start))
        XCTAssertNil(SensorWarmUp.current(sensor: sensor(start.addingTimeInterval(10 * 60)), current: nil, at: start))
        XCTAssertNil(SensorWarmUp.current(sensor: nil, current: nil, at: start))
    }

    func testWarmUpCardCountsDownAndStaysFreshUntilTheReadingIsOverdue() throws {
        var s = GlucoseSnapshot()
        s.sensor = sensor(start)
        let w = try XCTUnwrap(s.warmUp(at: start.addingTimeInterval(5 * 60)))
        let state = GlucoseActivityState.makeWarmUp(w, snapshot: s)
        XCTAssertTrue(state.isWarmingUp)
        XCTAssertEqual(state.warmUpEnd, start.addingTimeInterval(3600))
        XCTAssertEqual(state.warmUpStart, start)
        XCTAssertEqual(state.range, .inRange, "the placeholder reading sits mid-range")
        XCTAssertTrue(state.history.isEmpty)
        XCTAssertFalse(state.isStale(at: start.addingTimeInterval(3600 + 60)))
        XCTAssertTrue(state.isStale(at: start.addingTimeInterval(3600 + SensorWarmUp.grace + 1)))
    }

    func testCardsWithoutTheFieldStillDecode() throws {
        // What the relay sends: no warmUpEndsAt, so a pushed reading replaces the countdown.
        let json = #"{"mgdl":100,"trend":3,"readingAt":1800000000,"unit":"mmol","lowMgdl":70,"highMgdl":180,"history":[100],"forecast":[],"source":"relay"}"#
        let state = try JSONDecoder().decode(GlucoseActivityState.self, from: Data(json.utf8))
        XCTAssertFalse(state.isWarmingUp)
        let encoded = try JSONEncoder().encode(state)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("warmUpEndsAt"))
    }
}
