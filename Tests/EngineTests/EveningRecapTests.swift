import XCTest
@testable import GlucOSEngine

final class EveningRecapTests: XCTestCase {
    // referenceNow is 14:00 UTC; the recap goes out at 9 pm UTC, seven hours later.
    private let evening = referenceNow.addingTimeInterval(7 * 3600)
    private var todayStart: Date { utc.startOfDay(for: referenceNow) }

    /// Readings every `step` minutes from `startMinute` after today's midnight to `endMinute`,
    /// following `value` (minute of the day) -> mg/dL.
    private func day(from startMinute: Int = 0, to endMinute: Int = 21 * 60, step: Int = 5,
                     _ value: (Int) -> Double = { _ in 120 }) -> [GlucoseReading] {
        stride(from: startMinute, through: endMinute, by: step).map { m in
            reading(todayStart.addingTimeInterval(Double(m) * 60), value(m))
        }
    }

    private func recap(_ readings: [GlucoseReading], minute: Int = EveningRecap.defaultMinute,
                       now: Date? = nil) -> EveningRecap? {
        EveningRecap.compute(readings: readings, low: 70, high: 180, minute: minute, now: now ?? evening, calendar: utc)
    }

    // MARK: Figures

    func testAllInRange() throws {
        let r = try XCTUnwrap(recap(day()))
        XCTAssertEqual(r.minute, 21 * 60)
        XCTAssertEqual(r.timeInRange, 1, accuracy: 0.001)
        XCTAssertEqual(r.meanMgdl, 120, accuracy: 0.001)
        XCTAssertEqual(r.lows, 0)
        XCTAssertEqual(r.highs, 0)
        XCTAssertEqual(r.day, todayStart)
    }

    func testCountsLowsAndHighsAsRunsOfFifteenMinutes() throws {
        // A 30-minute low at 3 am, two hour-long highs after lunch and dinner, and a 10-minute dip
        // at 5 pm that's too short to count.
        let r = try XCTUnwrap(recap(day { m in
            switch m {
            case 180..<210: return 60
            case 780..<840, 1140..<1200: return 220
            case 1020..<1030: return 65
            default: return 120
            }
        }))
        XCTAssertEqual(r.lows, 1)
        XCTAssertEqual(r.highs, 2)
        XCTAssertLessThan(r.timeInRange, 1)
        XCTAssertGreaterThan(r.timeInRange, 0.85)
    }

    func testStopsAtTheRecapTime() throws {
        // A high after 9 pm isn't in a 9 pm recap, even when it's worked out later.
        let readings = day(to: 23 * 60) { m in m >= 21 * 60 + 5 ? 250 : 120 }
        let r = try XCTUnwrap(recap(readings, now: evening.addingTimeInterval(2 * 3600)))
        XCTAssertEqual(r.minute, 21 * 60)
        XCTAssertEqual(r.highs, 0)
    }

    func testBeforeTheRecapTimeRunsToTheNewestReading() throws {
        // Scheduled at 2 pm: the figures so far, which say so.
        let r = try XCTUnwrap(recap(day(to: 14 * 60), now: referenceNow))
        XCTAssertEqual(r.minute, 14 * 60)
        XCTAssertEqual(EveningRecapText.period(r), "Midnight to 2 pm")
    }

    func testNothingWithoutEnoughReadings() {
        // Under an hour of the day.
        XCTAssertNil(recap(day(to: 45), now: todayStart.addingTimeInterval(50 * 60)))
        // Readings in under half of the day's slots.
        XCTAssertNil(recap(day(from: 18 * 60)))
        // Only yesterday's readings.
        XCTAssertNil(recap(day().map { reading($0.timestamp.addingTimeInterval(-86_400), $0.mgdl) }))
    }

    func testLibreLinkUpFifteenMinuteHistoryIsEnough() throws {
        let r = try XCTUnwrap(recap(day(step: 15)))
        XCTAssertEqual(r.timeInRange, 1, accuracy: 0.001)
    }

    // MARK: Words

    func testNotificationText() throws {
        let r = EveningRecap(day: todayStart, minute: 20 * 60 + 57, timeInRange: 0.784, meanMgdl: 133,
                             lows: 1, highs: 0)
        XCTAssertEqual(EveningRecapText.title, "Evening recap")
        XCTAssertEqual(EveningRecapText.period(r), "Midnight to 8:55 pm")
        XCTAssertEqual(EveningRecapText.body(r, unit: .mmol), "78% in range, average 7.4 mmol/L. 1 low and no highs.")
        XCTAssertEqual(EveningRecapText.body(r, unit: .mgdl), "78% in range, average 133 mg/dL. 1 low and no highs.")
        XCTAssertEqual(EveningRecapText.spoken(r, unit: .mmol),
                       "Today, midnight to 8:55 pm. 78 percent in range, average 7.4 mmol/L. 1 low and no highs.")
    }

    func testCountsWording() {
        func counts(_ lows: Int, _ highs: Int) -> String {
            EveningRecapText.counts(EveningRecap(day: todayStart, minute: 1260, timeInRange: 1, meanMgdl: 120,
                                                 lows: lows, highs: highs))
        }
        XCTAssertEqual(counts(0, 0), "No lows and no highs")
        XCTAssertEqual(counts(0, 2), "No lows and 2 highs")
        XCTAssertEqual(counts(3, 1), "3 lows and 1 high")
        XCTAssertEqual(EveningRecapText.countValue(0), "None")
        XCTAssertEqual(EveningRecapText.countValue(4), "4")
    }

    func testTimeAndSettingsFooter() {
        XCTAssertEqual(EveningRecapText.time(21 * 60), "9 pm")
        XCTAssertEqual(EveningRecapText.time(20 * 60 + 30), "8:30 pm")
        XCTAssertEqual(EveningRecapText.settingsFooter(minute: 21 * 60),
                       "At 9 pm each day: time in range, lows, highs and the average since midnight. Observations, not advice.")
    }

    // MARK: Schedule

    func testSanitizedDefaultsToNinePm() {
        XCTAssertEqual(EveningRecap.sanitized(nil), 21 * 60)
        XCTAssertEqual(EveningRecap.sanitized(-5), 21 * 60)
        XCTAssertEqual(EveningRecap.sanitized(1440), 21 * 60)
        XCTAssertEqual(EveningRecap.sanitized(19 * 60 + 10), 19 * 60 + 10)
    }

    func testFireDateIsTodayUntilItPasses() {
        XCTAssertEqual(EveningRecap.fireDate(minute: 21 * 60, now: referenceNow, calendar: utc), evening)
        XCTAssertNil(EveningRecap.fireDate(minute: 21 * 60, now: evening, calendar: utc))
        XCTAssertNil(EveningRecap.fireDate(minute: 9 * 60, now: referenceNow, calendar: utc))
    }

    func testKeyMovesEveryFiveMinutesOfReadings() {
        func key(_ readings: [GlucoseReading]) -> EveningRecap.Key {
            EveningRecap.key(readings: readings, low: 70, high: 180, unit: .mmol, minute: 1260, now: referenceNow, calendar: utc)
        }
        let base = day(to: 14 * 60 - 5)
        let oneMinuteLater = base + [reading(todayStart.addingTimeInterval(Double(14 * 60 - 4) * 60), 121)]
        let fiveMinutesLater = base + [reading(todayStart.addingTimeInterval(Double(14 * 60) * 60), 121)]
        XCTAssertEqual(key(base), key(oneMinuteLater))
        XCTAssertNotEqual(key(base), key(fiveMinutesLater))
        XCTAssertNotEqual(key(base),
                          EveningRecap.key(readings: base, low: 70, high: 180, unit: .mmol, minute: 1200,
                                           now: referenceNow, calendar: utc))
    }

    func testRecognisesItsOwnNotification() {
        XCTAssertEqual(EveningRecap.kind, "recap")
        XCTAssertEqual(EveningRecap.identifier, "glucos.recap")
    }
}
