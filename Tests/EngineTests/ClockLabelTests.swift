import XCTest
@testable import GlucOSEngine

/// Times shown in the apps come from absolute instants and are only turned into a clock time, in
/// the device's own time zone, at the moment they're displayed. These pin that down with the
/// timestamps from a real report (a reading at 21:33 UTC and a dose at 02:46 UTC).
final class ClockLabelTests: XCTestCase {
    private let us = Locale(identifier: "en_US")

    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    /// Strips the narrow no-break space some ICU versions put before AM/PM.
    private func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
        calendar("UTC").date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    func testReadingTimeFollowsDeviceTimeZone() {
        let reading = utc(2026, 11, 11, 21, 33, 53)
        XCTAssertEqual(plain(ClockLabel.time(reading, calendar: calendar("Australia/Perth"), locale: us)), "5:33 AM")
        XCTAssertEqual(plain(ClockLabel.time(reading, calendar: calendar("Australia/Sydney"), locale: us)), "8:33 AM")
        XCTAssertEqual(plain(ClockLabel.time(reading, calendar: calendar("America/Halifax"), locale: us)), "5:33 PM")
        XCTAssertEqual(plain(ClockLabel.time(reading, calendar: calendar("UTC"), locale: us)), "9:33 PM")
    }

    func testAfternoonStaysPM() {
        let dose = utc(2026, 11, 11, 4, 56, 28)
        XCTAssertEqual(plain(ClockLabel.time(dose, calendar: calendar("Australia/Perth"), locale: us)), "12:56 PM")
        XCTAssertEqual(plain(ClockLabel.time(utc(2026, 11, 11, 9, 33), calendar: calendar("Australia/Perth"), locale: us)), "5:33 PM")
    }

    func testYesterdaysEntryIsLabelledYesterday() {
        let perth = calendar("Australia/Perth")
        let now = utc(2026, 11, 11, 21, 34)          // 5:34 am on the 12th in Perth
        let dose = utc(2026, 11, 11, 2, 46, 7)       // 10:46 am on the 11th in Perth
        XCTAssertEqual(ClockLabel.day(of: dose, now: now, calendar: perth), .yesterday)
        XCTAssertEqual(plain(ClockLabel.dayTime(dose, now: now, calendar: perth, locale: us)), "Yesterday 10:46 AM")
        XCTAssertEqual(ClockLabel.day(of: utc(2026, 11, 11, 20, 0), now: now, calendar: perth), .today)
        XCTAssertEqual(plain(ClockLabel.dayTime(utc(2026, 11, 11, 20, 0), now: now, calendar: perth, locale: us)), "4:00 AM")
        // The same dose seen from Sydney, where it's still the same day.
        XCTAssertEqual(ClockLabel.day(of: dose, now: utc(2026, 11, 11, 5, 0), calendar: calendar("Australia/Sydney")), .today)
    }

    func testOlderDaysNameTheDay() {
        let perth = calendar("Australia/Perth")
        let now = utc(2026, 11, 11, 21, 34)
        let older = utc(2026, 11, 9, 2, 0)
        guard case .other(let start) = ClockLabel.day(of: older, now: now, calendar: perth) else {
            return XCTFail("expected an earlier day")
        }
        XCTAssertEqual(start, perth.startOfDay(for: older))
        let title = ClockLabel.dayTitle(.other(start), calendar: perth, locale: us)
        XCTAssertTrue(title.contains("Mon") && title.contains("9") && title.contains("Nov"), title)
    }

    func testMidnightsInChartWindow() {
        let perth = calendar("Australia/Perth")
        let end = utc(2026, 11, 11, 21, 34)
        let marks = ClockLabel.midnights(from: end.addingTimeInterval(-12 * 3600), to: end, calendar: perth)
        XCTAssertEqual(marks, [utc(2026, 11, 11, 16, 0)])   // midnight in Perth
        XCTAssertEqual(ClockLabel.midnights(from: end.addingTimeInterval(-3 * 3600), to: end, calendar: perth), [])
    }

    func testLibreLinkUpFactoryTimestampIsUTCWithTwelveHourClock() {
        XCTAssertEqual(LibreLinkUpClient.factoryDate("11/11/2026 9:33:53 PM"), utc(2026, 11, 11, 21, 33, 53))
        XCTAssertEqual(LibreLinkUpClient.factoryDate("11/11/2026 2:46:07 AM"), utc(2026, 11, 11, 2, 46, 7))
        XCTAssertEqual(LibreLinkUpClient.factoryDate("11/12/2026 12:05:00 AM"), utc(2026, 11, 12, 0, 5))
        XCTAssertEqual(LibreLinkUpClient.factoryDate("11/12/2026 12:05:00 PM"), utc(2026, 11, 12, 12, 5))
        XCTAssertNil(LibreLinkUpClient.factoryDate("2026-11-12T12:05:00Z"))
    }
}
