import XCTest
@testable import GlucOSEngine

/// `TimelineView(.explicit(_:))` draws its first date straight away, future or not. These pin down
/// that every explicit schedule starts with now, so nothing is drawn as if it were later.
final class RedrawMomentsTests: XCTestCase {
    private let perth = TimeZone(identifier: "Australia/Perth")!

    private func perthDate(_ d: Int, _ h: Int, _ m: Int) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = perth
        return c.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
    }

    func testStartsWithNowThenFutureMomentsInOrder() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let later = now.addingTimeInterval(60), latest = now.addingTimeInterval(120)
        let past = now.addingTimeInterval(-60)
        XCTAssertEqual(RedrawMoments.explicit([latest, past, later, later, now], now: now), [now, later, latest])
        XCTAssertEqual(RedrawMoments.explicit([], now: now), [now])
    }

    /// Declan's popover on 19 Nov at 2:49 pm Perth: a live 8.7 reading at 2:48 pm and a sensor
    /// ending at 8:59 pm on 20 Nov. The hero's first redraw moment used to be the end itself, so
    /// it drew "Your sensor has ended · Ended at 8:59 pm" with the live reading "Yesterday 2:48 pm".
    func testHeroDrawsTheLiveReadingBeforeTheSensorEnds() throws {
        let now = perthDate(19, 14, 49)
        let ends = perthDate(20, 20, 59)
        var snap = GlucoseSnapshot()
        snap.sensor = SensorInfo(serial: "0M0001ABCDE", activated: ends.addingTimeInterval(-15 * 86_400), lifetimeDays: 15)
        snap.current = GlucoseReading(timestamp: perthDate(19, 14, 48), mgdl: 157, trend: .flat)

        let moments = snap.heroRedrawMoments(at: now)
        XCTAssertEqual(moments.first, now)
        XCTAssertEqual(moments, [now, ends.addingTimeInterval(1)])
        // What the hero draws at each moment: the reading now, the ended card once it's over.
        XCTAssertNil(snap.sensorEnded(at: try XCTUnwrap(moments.first)))
        XCTAssertNotNil(snap.sensorEnded(at: moments[1]))
    }

    func testHeroMomentsForAReadingPastTheEndGoingStale() {
        let ends = perthDate(18, 20, 59)
        let now = perthDate(18, 21, 10)
        var snap = GlucoseSnapshot()
        snap.sensor = SensorInfo(serial: "0M0001ABCDE", activated: ends.addingTimeInterval(-15 * 86_400), lifetimeDays: 15)
        let read = perthDate(18, 21, 8)
        snap.current = GlucoseReading(timestamp: read, mgdl: 110, trend: .flat)

        let stale = read.addingTimeInterval(GlucoseSnapshot.staleAfter + 1)
        XCTAssertEqual(snap.heroRedrawMoments(at: now), [now, stale])
        XCTAssertNil(snap.sensorEnded(at: now))
        XCTAssertNotNil(snap.sensorEnded(at: stale))
    }

    func testWarmUpMomentsStartWithNow() throws {
        let start = perthDate(19, 9, 0)
        let now = perthDate(19, 9, 20)
        var snap = GlucoseSnapshot()
        snap.sensor = SensorInfo(serial: "0M0001ABCDE", activated: start, lifetimeDays: 15)
        let warmUp = try XCTUnwrap(snap.warmUp(at: now))
        let moments = RedrawMoments.explicit(warmUp.changeMoments(from: now), now: now)
        XCTAssertEqual(moments.first, now)
        // Drawn at now, the ring shows the minutes actually left, not one fewer.
        XCTAssertEqual(warmUp.minutesLeft(at: try XCTUnwrap(moments.first)), warmUp.minutesLeft(at: now))
        XCTAssertTrue(moments.dropFirst().allSatisfy { $0 > now })
    }
}
