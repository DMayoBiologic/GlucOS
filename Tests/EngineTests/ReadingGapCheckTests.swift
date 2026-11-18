import XCTest
@testable import GlucOSEngine

/// "Check now" on a gap card: which gaps offer it, the 30-second limit, the button's words and
/// what the result says.
final class ReadingGapCheckTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    private func gap(_ start: Double, _ reason: ReadingGaps.Reason) -> ReadingGaps.Gap {
        ReadingGaps.Gap(start: at(start), end: at(start + 1200), startMgdl: 110, endMgdl: 120, reason: reason)
    }

    func testOnlyNoSignalAndCantConnectOfferIt() {
        XCTAssertTrue(ReadingGapCheck.offers(.noSignal))
        XCTAssertTrue(ReadingGapCheck.offers(.cantConnect))
        for r in [ReadingGaps.Reason.warmUp, .sensorEnded, .asleep(.mac), .asleep(.iPhone), .unknown] {
            XCTAssertFalse(ReadingGapCheck.offers(r), "\(r)")
        }
    }

    func testOnlyTheNewestGapOffersIt() {
        let old = gap(0, .noSignal), newest = gap(5000, .cantConnect)
        XCTAssertFalse(ReadingGapCheck.offers(old, among: [old, newest]))
        XCTAssertTrue(ReadingGapCheck.offers(newest, among: [old, newest]))
        let asleep = gap(9000, .asleep(.mac))
        XCTAssertFalse(ReadingGapCheck.offers(newest, among: [old, newest, asleep]))
        XCTAssertFalse(ReadingGapCheck.offers(asleep, among: [old, newest, asleep]))
    }

    func testOneTapPerThirtySeconds() {
        var s = ReadingGapCheck.Status()
        XCTAssertTrue(s.canCheck(at: at(0)))
        XCTAssertTrue(s.start(at: at(0)))
        XCTAssertTrue(s.running)
        // A second tap while running, or within 30 s, does nothing.
        XCTAssertFalse(s.start(at: at(1)))
        s.finish(.upToDate)
        XCTAssertFalse(s.start(at: at(29)))
        XCTAssertEqual(s.outcome, .upToDate)
        XCTAssertEqual(s.wait(at: at(20)), 10)
        XCTAssertTrue(s.start(at: at(30)))
        XCTAssertNil(s.outcome, "a new check clears the last result")
    }

    func testButtonWords() {
        var s = ReadingGapCheck.Status()
        XCTAssertEqual(s.buttonTitle(at: at(0)), "Check Now")
        _ = s.start(at: at(0))
        XCTAssertEqual(s.buttonTitle(at: at(0.5)), "Checking…")
        s.finish(.newReading("6.1"))
        XCTAssertEqual(s.buttonTitle(at: at(17.2)), "Check again in 13 s")
        XCTAssertEqual(s.buttonTitle(at: at(30)), "Check Again")
        XCTAssertEqual(s.announcement, "Connected, new reading 6.1")
    }

    func testOutcome() {
        let r = GlucoseReading(timestamp: at(600), mgdl: 110, trend: .flat)
        XCTAssertEqual(ReadingGapCheck.outcome(before: at(0), latest: r, problem: nil, unit: .mmol), .newReading("6.1"))
        XCTAssertEqual(ReadingGapCheck.outcome(before: at(0), latest: r, problem: nil, unit: .mgdl), .newReading("110"))
        XCTAssertEqual(ReadingGapCheck.outcome(before: nil, latest: r, problem: nil, unit: .mgdl), .newReading("110"))
        XCTAssertEqual(ReadingGapCheck.outcome(before: at(600), latest: r, problem: nil, unit: .mmol), .upToDate)
        XCTAssertEqual(ReadingGapCheck.outcome(before: at(600), latest: r, problem: "Email or password not accepted",
                                               unit: .mmol), .failed("Email or password not accepted"))
        XCTAssertEqual(ReadingGapCheck.outcome(before: nil, latest: nil, problem: nil, unit: .mmol), .upToDate)
    }

    func testResultLines() {
        XCTAssertEqual(ReadingGapCheck.Outcome.newReading("6.1").line, "Connected, new reading 6.1")
        XCTAssertEqual(ReadingGapCheck.Outcome.upToDate.line, "Connected, no new reading yet")
        XCTAssertEqual(ReadingGapCheck.Outcome.failed("LibreLinkUp is having problems").line, "LibreLinkUp is having problems")
        XCTAssertTrue(ReadingGapCheck.Outcome.upToDate.succeeded)
        XCTAssertFalse(ReadingGapCheck.Outcome.failed("x").succeeded)
    }

    func testNeverWakesInTheBackground() {
        // The only timing is the cooldown and the spinner's minimum: nothing schedules a fetch.
        XCTAssertEqual(ReadingGapCheck.cooldown, 30)
        XCTAssertLessThan(ReadingGapCheck.minimumSpin, 1)
    }
}
