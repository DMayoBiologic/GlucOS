import XCTest
@testable import GlucOSEngine

final class SpokenDayTests: XCTestCase {
    // referenceNow is 14:00 UTC.
    private var todayStart: Date { utc.startOfDay(for: referenceNow) }

    /// Readings every `step` minutes from `startMinute` after today's midnight to `endMinute`.
    private func day(from startMinute: Int = 0, to endMinute: Int = 14 * 60, step: Int = 5,
                     _ value: (Int) -> Double = { _ in 120 }) -> [GlucoseReading] {
        stride(from: startMinute, through: endMinute, by: step).map { m in
            reading(todayStart.addingTimeInterval(Double(m) * 60), value(m))
        }
    }

    private func answer(_ readings: [GlucoseReading], unit: GlucoseUnit = .mgdl, now: Date = referenceNow) -> String {
        SpokenDay.answer(readings: readings, low: 70, high: 180, unit: unit, now: now, calendar: utc)
    }

    func testSaysTheDaySoFarWithLowsAndHighs() {
        // A 30-minute low at 3 am and an hour-long high after breakfast.
        let text = answer(day { m in
            switch m {
            case 180..<210: return 60
            case 480..<540: return 220
            default: return 120
            }
        })
        XCTAssertTrue(text.hasPrefix("So far today, midnight to 2 pm: "), text)
        XCTAssertTrue(text.contains("% in range, average "), text)
        XCTAssertTrue(text.hasSuffix("1 low and 1 high."), text)
    }

    func testAllInRangeInMmol() {
        let text = answer(day(), unit: .mmol)
        XCTAssertEqual(text, "So far today, midnight to 2 pm: 100% in range, average \(GlucoseUnit.mmol.format(mgdl: 120, withUnit: true)). No lows and no highs.")
    }

    func testMatchesTheEveningRecapFigures() throws {
        let readings = day { m in m % 120 < 30 ? 200 : 110 }
        let recap = try XCTUnwrap(EveningRecap.compute(readings: readings, low: 70, high: 180,
                                                       minute: SpokenDay.endOfDayMinute, now: referenceNow, calendar: utc))
        XCTAssertEqual(answer(readings), SpokenDay.text(recap, unit: .mgdl))
    }

    func testNamesTheHoursWhenTheLastReadingIsOld() {
        // Readings stop at 9:40 am; it's 2 pm.
        let text = answer(day(to: 9 * 60 + 40))
        XCTAssertTrue(text.hasPrefix("So far today, midnight to 9:40 am: "), text)
    }

    func testIgnoresYesterday() {
        let yesterday = (0..<288).map { reading(todayStart.addingTimeInterval(Double($0 - 288) * 300), 300) }
        let text = answer(yesterday + day())
        XCTAssertTrue(text.contains("100% in range"), text)
        XCTAssertTrue(text.hasSuffix("No lows and no highs."), text)
    }

    func testTooFewReadingsToday() {
        XCTAssertEqual(answer(day(to: 40)), SpokenDay.tooFewToday)
        // An hour gone but readings in under half of its slots.
        XCTAssertEqual(answer([reading(todayStart, 120), reading(todayStart.addingTimeInterval(13 * 3600), 120)]),
                       SpokenDay.tooFewToday)
    }

    func testNoReadingsTodayOrAtAll() {
        XCTAssertEqual(answer([]), SpokenDay.noReadings)
        XCTAssertEqual(answer([reading(todayStart.addingTimeInterval(-3600), 120)]), SpokenDay.noneToday)
    }

    func testNeverGivesAdvice() {
        let advice = ["dose", "bolus", "insulin", "should", "inject", "take ", "try ", "correct"]
        for text in [answer(day { $0 < 60 ? 50 : 250 }), answer(day()), SpokenDay.noReadings, SpokenDay.signedOut,
                     SpokenDay.noneToday, SpokenDay.tooFewToday] {
            for word in advice { XCTAssertFalse(text.lowercased().contains(word), "\(text) says \(word)") }
        }
    }
}
