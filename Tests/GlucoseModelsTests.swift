import XCTest

/// Logic tests for Sources/Shared (compiled straight into this bundle). No network, no UI.
final class GlucoseModelsTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func r(_ minutes: Double, _ mgdl: Double, _ trend: Trend = .flat) -> GlucoseReading {
        GlucoseReading(timestamp: t0.addingTimeInterval(minutes * 60), mgdl: mgdl, trend: trend)
    }

    // MARK: Units

    func testFormatDeltaSignFollowsDisplayedValue() {
        XCTAssertEqual(GlucoseUnit.mmol.formatDelta(mgdl: 5.4), "+0.3")
        XCTAssertEqual(GlucoseUnit.mmol.formatDelta(mgdl: -5.4), "−0.3")
        XCTAssertEqual(GlucoseUnit.mmol.formatDelta(mgdl: -0.5), "±0.0")   // −0.03 mmol/L rounds to 0
        XCTAssertEqual(GlucoseUnit.mgdl.formatDelta(mgdl: -12.2), "−12")
        XCTAssertEqual(GlucoseUnit.mgdl.formatDelta(mgdl: 0.4), "±0")
    }

    func testUnitRoundTrip() {
        let mgdl = GlucoseUnit.mmol.mgdl(fromDisplay: 5.5)
        XCTAssertEqual(GlucoseUnit.mmol.value(fromMgdl: mgdl), 5.5, accuracy: 1e-9)
        XCTAssertEqual(GlucoseUnit.mmol.format(mgdl: 180), "10.0")
    }

    // MARK: Range

    func testClassify() {
        XCTAssertEqual(GlucoseRange.classify(mgdl: 50, low: 70, high: 180), .urgentLow)
        XCTAssertEqual(GlucoseRange.classify(mgdl: 65, low: 70, high: 180), .low)
        XCTAssertEqual(GlucoseRange.classify(mgdl: 120, low: 70, high: 180), .inRange)
        XCTAssertEqual(GlucoseRange.classify(mgdl: 200, low: 70, high: 180), .high)
        XCTAssertEqual(GlucoseRange.classify(mgdl: 260, low: 70, high: 180), .veryHigh)
    }

    func testHighThresholdAboveVeryHighIsRespected() {
        // With high = 15 mmol/L, 14 mmol/L is in range — not "very high".
        XCTAssertEqual(GlucoseRange.classify(mgdl: 252, low: 70, high: 270), .inRange)
        XCTAssertEqual(GlucoseRange.classify(mgdl: 280, low: 70, high: 270), .veryHigh)
    }

    // MARK: Stats

    func testStatsAreTimeWeighted() {
        // 12 h of 15-min points at 100, then 15 one-minute live readings at 250.
        var readings = stride(from: 0.0, through: 720, by: 15).map { r($0, 100) }
        readings += (1...15).map { r(720 + Double($0), 250) }
        let st = GlucoseStats.compute(readings, low: 70, high: 180)!
        // Count-weighted this would be ~24 % above range; time-weighted it's ~2 %.
        XCTAssertLessThan(st.timeAboveRange, 0.03)
        XCTAssertEqual(st.timeInRange + st.timeAboveRange + st.timeBelowRange, 1, accuracy: 1e-9)
        XCTAssertEqual(st.count, readings.count)
        XCTAssertEqual(st.spanHours, 735.0 / 60, accuracy: 1e-9)
    }

    func testStatsCapLongGaps() {
        // A 6 h gap after a low reading must not count as 6 h spent low.
        let readings = [r(0, 60), r(360, 120), r(375, 120), r(390, 120)]
        let st = GlucoseStats.compute(readings, low: 70, high: 180)!
        XCTAssertEqual(st.timeBelowRange, 15.0 / (15 + 15 + 15 + 1), accuracy: 1e-9)
    }

    func testStatsSingleReadingAndEmpty() {
        XCTAssertNil(GlucoseStats.compute([], low: 70, high: 180))
        let st = GlucoseStats.compute([r(0, 100)], low: 70, high: 180)!
        XCTAssertEqual(st.meanMgdl, 100)
        XCTAssertEqual(st.sdMgdl, 0)
        XCTAssertEqual(st.timeInRange, 1)
    }

    // MARK: History merge

    func testMergeAppendsLiveReadingsAfterGraph() {
        let graph = stride(from: 0.0, through: 60, by: 15).map { r($0, 100) }
        let previous = graph + [r(62, 105), r(63, 106)]
        let merged = GlucoseSnapshot.mergeHistory(previous: previous, graph: graph, current: r(64, 107))
        XCTAssertEqual(merged.map(\.mgdl), [100, 100, 100, 100, 100, 105, 106, 107])
    }

    func testMergeDropsLiveReadingsCoveredByGraph() {
        // Live points at 16–17 min were superseded by the graph's 30-min point: no interleaving.
        let previous = [r(0, 100), r(15, 100), r(16, 140), r(17, 141)]
        let graph = [r(0, 100), r(15, 100), r(30, 110)]
        let merged = GlucoseSnapshot.mergeHistory(previous: previous, graph: graph, current: r(31, 112))
        XCTAssertEqual(merged.map(\.mgdl), [100, 100, 110, 112])
    }

    func testMergeKeepsOlderHistoryAndTrimsToWindow() {
        let previous = [r(-30 * 60, 90), r(-20 * 60, 95), r(-13 * 60, 98)]
        let graph = [r(-12 * 60, 100), r(0, 101)]
        let merged = GlucoseSnapshot.mergeHistory(previous: previous, graph: graph, current: r(1, 102))
        XCTAssertEqual(merged.map(\.mgdl), [95, 98, 100, 101, 102])
    }

    func testMergeWithoutGraphKeepsLiveAndDeduplicates() {
        let merged = GlucoseSnapshot.mergeHistory(previous: [r(0, 100), r(1, 101)], graph: [], current: r(1, 101))
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(GlucoseSnapshot.mergeHistory(previous: [], graph: [], current: nil).isEmpty)
    }

    // MARK: Snapshot

    func testDeltaUsesReadingAtLeastFourMinutesOld() {
        var s = GlucoseSnapshot()
        s.history = [r(0, 100), r(5, 104), r(8, 106), r(10, 110)]
        s.current = r(10, 110)
        XCTAssertEqual(s.previous?.mgdl, 104)   // 5 min back, not 2 min back
        XCTAssertEqual(s.deltaMgdl, 6)
    }

    func testNoDeltaAcrossLongGap() {
        var s = GlucoseSnapshot()
        s.history = [r(0, 100), r(45, 150)]
        s.current = r(45, 150)
        XCTAssertNil(s.deltaMgdl)
    }

    func testStaleness() {
        var s = GlucoseSnapshot()
        XCTAssertTrue(s.isStale(at: t0))
        s.current = r(0, 100)
        XCTAssertFalse(s.isStale(at: t0.addingTimeInterval(5 * 60)))
        XCTAssertTrue(s.isStale(at: t0.addingTimeInterval(7 * 60)))
    }

    func testSnapshotDecodesFromDisk() throws {
        var s = GlucoseSnapshot()
        s.current = r(0, 100, .rising)
        s.history = [r(-5, 95), r(0, 100, .rising)]
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try d.decode(GlucoseSnapshot.self, from: e.encode(s)), s)
    }
}
