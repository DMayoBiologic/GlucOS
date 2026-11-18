import XCTest
@testable import GlucOSEngine

/// Insights "Sensor coverage" (`SensorCoverage`): the share of the period with readings, the longest
/// gaps with their reasons, the period before, the Logbook around a gap, and the words.
final class SensorCoverageTests: XCTestCase {
    // referenceNow is on a 5-minute step. Readings every 5 minutes for 30 days up to it, minus any
    // the test skips.
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400

    private func history(from start: Date = referenceNow.addingTimeInterval(-30 * 86_400 + 300),
                         step: TimeInterval = 300, skip: (Date) -> Bool = { _ in false }) -> [GlucoseReading] {
        var out: [GlucoseReading] = []
        var t = start
        while t <= referenceNow {
            if !skip(t) { out.append(reading(t, 120)) }
            t = t.addingTimeInterval(step)
        }
        return out
    }

    /// Skips everything strictly between `start` and `start + length`: a gap of exactly `length`.
    private func gap(_ start: Date, _ length: TimeInterval) -> (Date) -> Bool {
        { $0 > start && $0 < start.addingTimeInterval(length) }
    }

    private func gaps(_ list: ((Date) -> Bool)...) -> (Date) -> Bool {
        { t in list.contains { $0(t) } }
    }

    private let none = ReadingGaps.Context(sensor: nil, polls: PollLog(), device: .mac)

    private func compute(_ readings: [GlucoseReading], period: SensorCoverage.Period = .fortnight,
                         context: ReadingGaps.Context? = nil) -> SensorCoverage? {
        SensorCoverage.compute(readings: readings, context: context ?? none, period: period)
    }

    // MARK: Coverage

    func testEveryReadingIsFullCoverageAndHidden() throws {
        let s = try XCTUnwrap(compute(history()))
        XCTAssertEqual(s.coverage, 1)
        XCTAssertTrue(s.gaps.isEmpty)
        XCTAssertFalse(s.shows)
        XCTAssertFalse(s.isPartial)
        XCTAssertEqual(s.start, referenceNow.addingTimeInterval(-14 * day))
        XCTAssertEqual(s.end, referenceNow)
        XCTAssertEqual(SensorCoverageText.headline(s), "Readings for 100% of the last 14 days.")
        XCTAssertEqual(SensorCoverageText.missingValue(s), "None")
        XCTAssertNil(SensorCoverageText.reasonLine(s))
        XCTAssertEqual(SensorCoverageText.spoken(s, now: referenceNow, calendar: utc),
                       "Sensor coverage, the last 14 days. Readings for 100 percent of the time. No gaps.")
    }

    func testGapsCountAgainstThePeriodLongestFirst() throws {
        let long = referenceNow.addingTimeInterval(-2 * day)
        let short = referenceNow.addingTimeInterval(-5 * day)
        let s = try XCTUnwrap(compute(history(skip: gaps(gap(long, 6 * hour), gap(short, 30 * 60)))))
        XCTAssertEqual(s.gaps.count, 2)
        XCTAssertEqual(s.missing, 6.5 * hour)
        XCTAssertEqual(s.coverage, 1 - 6.5 * hour / (14 * day), accuracy: 1e-9)
        XCTAssertTrue(s.shows)
        XCTAssertEqual(s.longest.map(\.start), [long, short])
        XCTAssertEqual(s.longest.first?.reason, .unknown)
        XCTAssertEqual(SensorCoverageText.headline(s), "Readings for 98% of the last 14 days.")
        XCTAssertEqual(SensorCoverageText.missingValue(s), "6 hr 30 min")
        XCTAssertEqual(SensorCoverageText.gaps(s.gaps.count), "2 gaps")
        XCTAssertTrue(SensorCoverageText.row(s.longest[0], in: s, now: referenceNow, calendar: utc).hasSuffix(" · 6 hr"))
        // No reason is known for gaps older than the record of checks.
        XCTAssertNil(SensorCoverageText.reasonLine(s))
        let spoken = SensorCoverageText.spoken(s, now: referenceNow, calendar: utc)
        XCTAssertTrue(spoken.hasPrefix("Sensor coverage, the last 14 days. Readings for 98 percent of the time. 2 gaps, 6 hr 30 min missing. The longest, 6 hr from "))
        XCTAssertTrue(spoken.hasSuffix(": No readings."))
    }

    func testNeverSays100WhileSomethingIsMissing() {
        XCTAssertEqual(SensorCoverageText.percent(0.998), "99%")
        XCTAssertEqual(SensorCoverageText.percent(1), "100%")
        XCTAssertEqual(SensorCoverageText.percent(0.5), "50%")
    }

    func testHistoryFillIsCovered() throws {
        // The last 3 days only at LibreLinkUp's 15-minute history steps: not gaps.
        let fillFrom = referenceNow.addingTimeInterval(-3 * day)
        var readings = history().filter { $0.timestamp <= fillFrom }
        readings += history(from: fillFrom.addingTimeInterval(900), step: 900)
        let s = try XCTUnwrap(compute(readings))
        XCTAssertTrue(s.gaps.isEmpty)
        XCTAssertEqual(s.coverage, 1)
    }

    func testAGapCrossingThePeriodStartCountsFromTheStart() throws {
        let start = referenceNow.addingTimeInterval(-14 * day)
        let s = try XCTUnwrap(compute(history(skip: gap(start.addingTimeInterval(-2 * hour), 3 * hour))))
        XCTAssertEqual(s.gaps.count, 1)
        XCTAssertEqual(s.missing, hour)
        XCTAssertEqual(s.counted(s.gaps[0]), hour)
        XCTAssertEqual(SensorCoverageText.row(s.gaps[0], in: s, now: referenceNow, calendar: utc).components(separatedBy: " · ").last,
                       "1 hr")
    }

    func testANewInstallCountsFromItsFirstReading() throws {
        let s = try XCTUnwrap(compute(history(from: referenceNow.addingTimeInterval(-3 * day))))
        XCTAssertTrue(s.isPartial)
        XCTAssertEqual(s.start, referenceNow.addingTimeInterval(-3 * day))
        XCTAssertEqual(SensorCoverageText.headline(s), "Readings for 100% of the 3 days stored so far.")
        // Under a day: nothing to say.
        XCTAssertNil(compute(history(from: referenceNow.addingTimeInterval(-20 * hour))))
        XCTAssertNil(compute([]))
    }

    func testPeriodPicksTheDays() throws {
        let old = referenceNow.addingTimeInterval(-20 * day)
        let readings = history(skip: gap(old, 4 * hour))
        XCTAssertTrue(try XCTUnwrap(compute(readings, period: .week)).gaps.isEmpty)
        XCTAssertTrue(try XCTUnwrap(compute(readings, period: .fortnight)).gaps.isEmpty)
        let month = try XCTUnwrap(compute(readings, period: .month))
        XCTAssertEqual(month.gaps.count, 1)
        // The stored readings start 5 minutes inside the 30 days: still the whole period.
        XCTAssertFalse(month.isPartial)
    }

    // MARK: Reasons

    func testReasonsComeFromTheChartsGaps() throws {
        // GlucOS kept checking all through the last gap: no signal.
        let start = referenceNow.addingTimeInterval(-3 * hour)
        var polls = PollLog()
        var t = start.addingTimeInterval(-10 * 60)
        while t <= referenceNow { polls.record(t); t = t.addingTimeInterval(60) }
        let context = ReadingGaps.Context(sensor: nil, polls: polls, device: .iPhone)
        let s = try XCTUnwrap(compute(history(skip: gap(start, hour)), context: context))
        XCTAssertEqual(s.gaps.map(\.reason), [.noSignal])
        XCTAssertEqual(s.byReason.first?.reason, .noSignal)
        XCTAssertEqual(SensorCoverageText.reasonLine(s), "Most of the missing time: No signal from LibreLinkUp (1 hr).")
    }

    func testMissingTimeByReasonMostFirst() throws {
        // A sensor change 4 days ago (warm-up) and an older unknown gap that's shorter.
        let activated = referenceNow.addingTimeInterval(-4 * day)
        let sensor = SensorInfo(serial: "ABC", activated: activated, lifetimeDays: 15)
        let context = ReadingGaps.Context(sensor: sensor, polls: PollLog(), device: .mac)
        let s = try XCTUnwrap(compute(history(skip: gaps(gap(activated.addingTimeInterval(-10 * 60), 80 * 60),
                                                         gap(referenceNow.addingTimeInterval(-9 * day), 20 * 60))),
                                      context: context))
        XCTAssertEqual(s.byReason.map(\.reason), [.warmUp, .unknown])
        XCTAssertEqual(s.byReason.map(\.seconds), [80.0 * 60, 20.0 * 60])
        XCTAssertEqual(SensorCoverageText.reasonLine(s), "Most of the missing time: Sensor warming up (1 hr 20 min).")
    }

    // MARK: Compare

    func testComparesWithThePeriodBefore() throws {
        let now = gap(referenceNow.addingTimeInterval(-2 * day), 6 * hour)
        let before = gaps(gap(referenceNow.addingTimeInterval(-20 * day), 12 * hour),
                          gap(referenceNow.addingTimeInterval(-25 * day), hour))
        let readings = history(skip: gaps(now, before))
        let s = try XCTUnwrap(compute(readings))
        let prev = try XCTUnwrap(InsightsCompare.previousCoverage(readings: readings, context: none, current: s))
        XCTAssertEqual(prev.end, referenceNow.addingTimeInterval(-14 * day))
        XCTAssertEqual(prev.gaps.count, 2)
        XCTAssertEqual(prev.missing, 13 * hour)
        let cov = try XCTUnwrap(InsightsCompare.coverage(s, prev))
        XCTAssertEqual(cov.direction, .up)
        XCTAssertEqual(cov.verdict, .better)
        let count = try XCTUnwrap(InsightsCompare.coverageGaps(s, prev))
        XCTAssertEqual(count.direction, .down)
        XCTAssertEqual(count.verdict, .better)
        XCTAssertNil(InsightsCompare.coverage(s, nil))
    }

    func testNoCompareWithoutStoredReadingsBefore() throws {
        // 20 days stored: the 14 days before have only 6.
        let readings = history(from: referenceNow.addingTimeInterval(-20 * day))
        let s = try XCTUnwrap(compute(readings))
        XCTAssertNil(InsightsCompare.previousCoverage(readings: readings, context: none, current: s))
        // A new install's partial period never compares.
        let partial = history(from: referenceNow.addingTimeInterval(-3 * day))
        XCTAssertNil(InsightsCompare.previousCoverage(readings: partial, context: none,
                                                      current: try XCTUnwrap(compute(partial))))
    }

    // MARK: Logbook

    func testLinkOpensTheLogbookAroundTheGap() throws {
        let start = referenceNow.addingTimeInterval(-2 * day)
        let s = try XCTUnwrap(compute(history(skip: gap(start, 6 * hour))))
        let link = SensorCoverage.link(for: try XCTUnwrap(s.longest.first), now: referenceNow, calendar: utc)
        XCTAssertEqual(link.filter, .aroundGap)
        XCTAssertNil(link.kindChip)
        XCTAssertEqual(link.period.interval.start, start.addingTimeInterval(-hour))
        XCTAssertEqual(link.period.interval.end, start.addingTimeInterval(7 * hour))
        XCTAssertTrue(link.period.label.hasPrefix("Around "))
        XCTAssertEqual(link.sourceID, "logbook-aroundGap")
        XCTAssertEqual(LogbookFilter.aroundGap.title, "Around a gap")
        XCTAssertFalse(LogbookFilter.aroundGap.isListed)
        XCTAssertEqual(LogbookFilter.aroundGap.insightsCard, .aroundGap)
    }

    // MARK: Layout, share, step

    func testCardShipsLastOnBothScreens() {
        XCTAssertEqual(InsightsCard(rawValue: "sensorCoverage"), .sensorCoverage)
        XCTAssertEqual(InsightsCard.sensorCoverage.title, "Sensor coverage")
        XCTAssertEqual(InsightsCard.phoneDefault.last, .sensorCoverage)
        XCTAssertEqual(InsightsCard.macDefault.last, .sensorCoverage)
        XCTAssertTrue(InsightsCard.sensorCoverage.stepsWithPeriod)
        // A layout saved before it shipped, Forecast accuracy moved to the top: it shows straight after.
        let others = InsightsCard.macDefault.filter { $0 != .forecastAccuracy && $0 != .sensorCoverage }
        let saved = InsightsLayout(order: ["forecastAccuracy"] + others.map(\.rawValue), hidden: [])
        XCTAssertEqual(Array(saved.arranged(InsightsCard.macDefault).prefix(2)), [.forecastAccuracy, .sensorCoverage])
    }

    func testSharePeriodFollowsThePicker() {
        let d = UserDefaults(suiteName: "SensorCoverageTests.\(UUID().uuidString)")!
        XCTAssertEqual(InsightsShare.period(for: .sensorCoverage, defaults: d, firstReading: nil), .days(14))
        d.set(30, forKey: InsightsShare.Key.coverage)
        XCTAssertEqual(InsightsShare.period(for: .sensorCoverage, defaults: d, firstReading: nil), .days(30))
    }

    @MainActor
    func testScreenShowsTheCardOnlyWhileSomethingIsMissing() {
        let d = UserDefaults(suiteName: "SensorCoverageTests.\(UUID().uuidString)")!
        let cache = SensorCoverageCache()
        XCTAssertFalse(cache.shows(readings: history(), context: none, back: 0, defaults: d))
        let gappy = history(skip: gap(referenceNow.addingTimeInterval(-2 * day), 6 * hour))
        XCTAssertTrue(cache.shows(readings: gappy, context: none, back: 0, defaults: d))
        // Stepped back a fortnight, past the gap: full again.
        XCTAssertFalse(cache.shows(readings: gappy, context: none, back: 1, defaults: d))
        XCTAssertFalse(cache.shows(readings: [], context: none, back: 0, defaults: d))
    }

    // MARK: Words

    func testWordsGiveNoAdvice() throws {
        let s = try XCTUnwrap(compute(history(skip: gap(referenceNow.addingTimeInterval(-2 * day), 6 * hour))))
        let all = [SensorCoverageText.headline(s), SensorCoverageText.footnote(s),
                   SensorCoverageText.spoken(s, now: referenceNow, calendar: utc),
                   SensorCoverageText.emptyLine(.fortnight), SensorCoverageText.logbookLine,
                   SensorCoverageText.logbookHint].joined(separator: " ").lowercased()
        for word in ["dose", "bolus", "insulin", "should", "inject", "basal"] {
            XCTAssertFalse(all.contains(word), word)
        }
    }

    func testWhatsNewHighlightFits() throws {
        let release = try XCTUnwrap(WhatsNewCatalog.releases.first { $0.version == "1.75.0" })
        let h = try XCTUnwrap(release.highlights.first { $0.title == "Sensor coverage in Insights" })
        XCTAssertLessThanOrEqual(h.title.count, 40)
        XCTAssertTrue(h.detail.hasSuffix("."))
        XCTAssertLessThanOrEqual(release.highlights.count, 4)
    }
}
