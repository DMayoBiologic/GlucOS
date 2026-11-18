import XCTest
@testable import GlucOSEngine

/// Gaps in readings: what counts as one, why it happened, what the card and VoiceOver say, the
/// record of checks behind it, and the bridge drawing in once.
final class ReadingGapsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private func readings(_ minutes: [Double]) -> [GlucoseReading] {
        minutes.map { GlucoseReading(timestamp: at($0), mgdl: 120, trend: .flat) }
    }

    /// Checking every minute over `range` (in minutes from t0).
    private func polls(_ ranges: ClosedRange<Double>...) -> PollLog {
        var log = PollLog()
        for r in ranges {
            var m = r.lowerBound
            while m <= r.upperBound { log.record(at(m)); m += 1 }
        }
        return log
    }

    private func context(sensor: SensorInfo? = nil, polls: PollLog = PollLog(), device: ReadingGaps.Device = .mac) -> ReadingGaps.Context {
        ReadingGaps.Context(sensor: sensor, polls: polls, device: device)
    }

    // MARK: What counts as a gap

    func testTenMinutesOrMoreIsAGap() {
        XCTAssertFalse(ReadingGaps.isGap(60))
        XCTAssertFalse(ReadingGaps.isGap(9 * 60 + 59))
        XCTAssertTrue(ReadingGaps.isGap(10 * 60))
        XCTAssertTrue(ReadingGaps.isGap(12 * 60))
        XCTAssertTrue(ReadingGaps.isGap(40 * 60))
    }

    /// LibreLinkUp's 15-minute history (filled in while the app wasn't checking) isn't a gap.
    func testFifteenMinuteHistoryStepsAreNotGaps() {
        XCTAssertFalse(ReadingGaps.isGap(15 * 60))
        XCTAssertFalse(ReadingGaps.isGap(15 * 60 + 80))
        XCTAssertFalse(ReadingGaps.isGap(15 * 60 - 80))
        XCTAssertTrue(ReadingGaps.isGap(17 * 60))
        let gaps = ReadingGaps.find(in: readings([0, 15, 30, 45, 46, 47]), context: context())
        XCTAssertTrue(gaps.isEmpty)
    }

    func testFindsEachGapWithItsEnds() {
        let gaps = ReadingGaps.find(in: readings([0, 1, 2, 30, 31, 32, 50]), context: context())
        XCTAssertEqual(gaps.map(\.start), [at(2), at(32)])
        XCTAssertEqual(gaps.map(\.end), [at(30), at(50)])
        XCTAssertEqual(gaps[0].duration, 28 * 60)
        XCTAssertTrue(ReadingGaps.find(in: readings([0]), context: context()).isEmpty)
        XCTAssertTrue(ReadingGaps.find(in: [], context: context()).isEmpty)
    }

    // MARK: Why

    func testWarmUpWhenTheGapReachesIntoANewSensorsFirstHour() {
        // The old sensor's last reading at 0, the new one started at 5, first reading at 70.
        let sensor = SensorInfo(serial: "X", activated: at(5), lifetimeDays: 15)
        XCTAssertEqual(ReadingGaps.reason(from: at(0), to: at(70), context: context(sensor: sensor)), .warmUp)
        // A gap well after the warm-up isn't one.
        XCTAssertNotEqual(ReadingGaps.reason(from: at(200), to: at(230), context: context(sensor: sensor)), .warmUp)
        // Nor one that ended before the new sensor started.
        XCTAssertNotEqual(ReadingGaps.reason(from: at(-60), to: at(-30), context: context(sensor: sensor)), .warmUp)
    }

    func testSensorEndedWhenTheGapStartsAtItsEnd() {
        let sensor = SensorInfo(serial: "X", activated: at(-15 * 1440), lifetimeDays: 15)
        XCTAssertEqual(ReadingGaps.reason(from: at(0), to: at(40), context: context(sensor: sensor)), .sensorEnded)
        XCTAssertEqual(ReadingGaps.reason(from: at(-4), to: at(40), context: context(sensor: sensor)), .sensorEnded)
        XCTAssertNotEqual(ReadingGaps.reason(from: at(-60), to: at(-30), context: context(sensor: sensor)), .sensorEnded)
    }

    func testNoSignalWhenGlucOSKeptChecking() {
        let log = polls(-30...60)
        XCTAssertEqual(ReadingGaps.reason(from: at(0), to: at(25), context: context(polls: log)), .noSignal)
    }

    func testAsleepWhenGlucOSWasntChecking() {
        // Checked until 1 min after the last reading, then again only on waking at 38.
        let log = polls(-30...1, 38...45)
        XCTAssertEqual(ReadingGaps.reason(from: at(0), to: at(40), context: context(polls: log)), .asleep(.mac))
        XCTAssertEqual(ReadingGaps.reason(from: at(0), to: at(40), context: context(polls: log, device: .iPhone)),
                       .asleep(.iPhone))
    }

    /// Before the record of checks began, GlucOS can't say: no guessing that it was asleep.
    func testUnknownBeforeTheRecordBegan() {
        let log = polls(100...120)
        XCTAssertEqual(ReadingGaps.reason(from: at(0), to: at(40), context: context(polls: log)), .unknown)
        XCTAssertEqual(ReadingGaps.reason(from: at(0), to: at(40), context: context()), .unknown)
    }

    // MARK: Record of checks

    func testChecksJoinIntoStretches() {
        var log = PollLog()
        log.record(at(0)); log.record(at(1)); log.record(at(2))
        log.record(at(30)); log.record(at(31))
        XCTAssertEqual(log.spans.count, 2)
        XCTAssertEqual(log.began, at(0))
        XCTAssertEqual(log.covered(from: at(0), to: at(40)), 3 * 60)
        XCTAssertEqual(log.covered(from: at(1), to: at(30.5)), 1.5 * 60)
        XCTAssertEqual(log.covered(from: at(5), to: at(5)), 0)
    }

    func testALongPollIntervalStillJoins() {
        var log = PollLog()
        log.record(at(0), interval: 300)
        log.record(at(10), interval: 300)
        XCTAssertEqual(log.spans.count, 1)
    }

    func testOldStretchesAreDroppedButTheStartIsKept() {
        var log = PollLog()
        log.record(at(0))
        log.record(at(3 * 1440))
        XCTAssertEqual(log.spans.count, 1)
        XCTAssertEqual(log.began, at(0))
    }

    func testRecordSurvivesSaving() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ReadingGapsTests"))
        defaults.removePersistentDomain(forName: "ReadingGapsTests")
        let log = polls(0...5, 30...31)
        log.save(defaults)
        XCTAssertEqual(PollLog.load(defaults), log)
        defaults.removePersistentDomain(forName: "ReadingGapsTests")
        XCTAssertEqual(PollLog.load(defaults), PollLog())
    }

    // MARK: Words

    func testCardTitlesFitAndDetailsAreOneSentence() {
        let reasons: [ReadingGaps.Reason] = [.warmUp, .sensorEnded, .noSignal, .asleep(.mac), .asleep(.iPhone), .unknown]
        XCTAssertEqual(ReadingGaps.Reason.asleep(.mac).title, "Mac was asleep")
        XCTAssertEqual(ReadingGaps.Reason.asleep(.iPhone).title, "iPhone was asleep")
        XCTAssertEqual(ReadingGaps.Reason.unknown.title, "No readings")
        for r in reasons {
            XCTAssertLessThanOrEqual(r.title.count, 40, r.title)
            XCTAssertTrue(r.detail.hasSuffix("."), r.detail)
            XCTAssertFalse(r.systemImage.isEmpty)
            for banned in ["suggest", "recommend", "correction", "bolus", "should", "dose"] {
                XCTAssertFalse(r.detail.lowercased().contains(banned), r.detail)
            }
        }
    }

    func testLength() {
        XCTAssertEqual(ReadingGaps.length(10 * 60), "10 min")
        XCTAssertEqual(ReadingGaps.length(60 * 60), "1 hr")
        XCTAssertEqual(ReadingGaps.length(65 * 60), "1 hr 5 min")
        XCTAssertEqual(ReadingGaps.length(3 * 3600 + 20), "3 hr")
    }

    func testSpanLine() {
        let gap = ReadingGaps.Gap(start: at(0), end: at(32), startMgdl: 100, endMgdl: 110, reason: .unknown)
        let from = ClockLabel.time(at(0), calendar: utc)
        let to = ClockLabel.time(at(32), calendar: utc)
        XCTAssertEqual(ReadingGaps.span(gap, calendar: utc), "\(from) – \(to) · 32 min")
    }

    func testOneVoiceOverLine() {
        XCTAssertNil(ReadingGaps.spoken([]))
        let a = ReadingGaps.Gap(start: at(0), end: at(30), startMgdl: 100, endMgdl: 110, reason: .asleep(.mac))
        let b = ReadingGaps.Gap(start: at(60), end: at(80), startMgdl: 100, endMgdl: 110, reason: .noSignal)
        let t = { (d: Date) in ClockLabel.time(d, calendar: self.utc) }
        XCTAssertEqual(ReadingGaps.spoken([a], calendar: utc),
                       "Gap in readings from \(t(at(0))) to \(t(at(30))): Mac was asleep.")
        XCTAssertEqual(ReadingGaps.spoken([a, b], calendar: utc),
                       "2 gaps in readings; the latest from \(t(at(60))) to \(t(at(80))): No signal from LibreLinkUp.")
    }

    // MARK: Drawing in

    func testEachBridgeDrawsInOnceAndNeverUnderReduceMotion() {
        var log = ReadingGapDrawIn()
        XCTAssertTrue(log.shouldDraw(at(0), reduceMotion: false))
        XCTAssertFalse(log.shouldDraw(at(0), reduceMotion: false))
        XCTAssertFalse(log.shouldDraw(at(10), reduceMotion: true))
        XCTAssertFalse(log.shouldDraw(at(10), reduceMotion: false))
    }

    // MARK: What's New

    func testWhatsNewHighlightFits() throws {
        let release = try XCTUnwrap(WhatsNewCatalog.releases.first { $0.version == "1.74.0" })
        XCTAssertLessThanOrEqual(release.highlights.count, 4)
        for h in release.highlights {
            XCTAssertLessThanOrEqual(h.title.count, 40)
            XCTAssertTrue(h.detail.hasSuffix("."))
        }
    }
}
