import XCTest
@testable import GlucOSEngine

/// The Dynamic Island's compact trend line (`IslandSparkline`).
final class IslandSparklineTests: XCTestCase {
    /// A reading at the start of 5-minute slot `slot`.
    private func at(_ slot: Int) -> Double { Double(slot) * 300 }

    /// Fifteen slots rising 10 mg/dL a slot from `start`.
    private func rising(from start: Int) -> [Int?] {
        (0..<15).map { Optional(start + 10 * $0) }
    }

    private func history(_ tail: [Int?]) -> [Int?] {
        // A 3-hour card: 37 slots, older ones empty.
        [Int?](repeating: nil, count: 37 - tail.count) + tail
    }

    func testOffByDefault() {
        let d = UserDefaults(suiteName: "IslandSparklineTests")!
        d.removePersistentDomain(forName: "IslandSparklineTests")
        XCTAssertFalse(IslandSparkline.isOn(d))
        d.set(true, forKey: IslandSparkline.defaultsKey)
        XCTAssertTrue(IslandSparkline.isOn(d))
    }

    func testTooFewReadingsInTheLastHourDrawsNothing() {
        let h = history([100, 110, 120, 130, 140, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, 150])
        // The last hour's 13 slots hold only 130, 140 and 150.
        XCTAssertNil(IslandSparkline.frame(history: h, readingAt: at(1000)))
        XCTAssertNil(IslandSparkline.frame(history: [], readingAt: at(1000)))
        XCTAssertNil(IslandSparkline.frame(history: history([120, 130, nil]), readingAt: at(1000)))
    }

    func testPointsSpanTheLastHourOldestFirst() throws {
        // Slots 986...1000 hold 100...240.
        let f = try XCTUnwrap(IslandSparkline.frame(history: history(rising(from: 100)), readingAt: at(1000) + 120))
        XCTAssertEqual(f.endSlot, 1000)
        let p = IslandSparkline.points(f)
        // Back 13 (just off the left edge) to 0 (the right edge).
        XCTAssertEqual(p.map { $0.back }, (0...13).reversed().map { Double($0) })
        XCTAssertEqual(f.lowMgdl, 120)
        XCTAssertEqual(f.highMgdl, 240)
        XCTAssertEqual(p.last?.level ?? -1, 1, accuracy: 1e-9)   // 240, the reading, is the top
        XCTAssertEqual(p[1].level, 0, accuracy: 1e-9)             // 120 (back 12) is the bottom of the hour
        XCTAssertEqual(p[0].level, 0, accuracy: 1e-9)             // 110, off the edge, is clamped
        XCTAssertEqual(p[7].level, 0.5, accuracy: 1e-9)           // 180, half an hour ago
    }

    func testFlatHourKeepsAMinimumSpan() throws {
        let f = try XCTUnwrap(IslandSparkline.frame(history: history(Array(repeating: Optional(120), count: 15)), readingAt: at(50)))
        XCTAssertEqual(f.highMgdl - f.lowMgdl, IslandSparkline.minSpanMgdl, accuracy: 1e-9)
        for p in IslandSparkline.points(f) { XCTAssertEqual(p.level, 0.5, accuracy: 1e-9) }
    }

    func testGapsAreFilledFromNeighbours() {
        XCTAssertEqual(IslandSparkline.fillGaps([nil, 100, nil, nil, 130, nil]), [100, 100, 110, 120, 130, 130])
        XCTAssertEqual(IslandSparkline.fillGaps([nil, nil]), [])
    }

    func testSharedSlotsKeepTheirRingIndexAcrossANewReading() throws {
        let old = try XCTUnwrap(IslandSparkline.frame(history: history(rising(from: 100)), readingAt: at(1000)))
        let new = try XCTUnwrap(IslandSparkline.frame(history: history(rising(from: 110)), readingAt: at(1001)))
        // Slots 988...1000 are on screen on both cards: same value at the same index, so nothing jumps.
        for slot in 988...1000 {
            XCTAssertEqual(old.ring[IslandSparkline.index(slot)], new.ring[IslandSparkline.index(slot)], "slot \(slot)")
        }
        // The new slot starts at the old reading and ends at the new one.
        XCTAssertEqual(old.ring[IslandSparkline.index(1001)], 240)
        XCTAssertEqual(new.ring[IslandSparkline.index(1001)], 250)
        // So does the one after it, for a card two slots later.
        XCTAssertEqual(old.ring[IslandSparkline.index(1002)], 240)
    }

    func testHalfwayThroughAGlideTheNewPointIsOffTheRightEdge() throws {
        let old = try XCTUnwrap(IslandSparkline.frame(history: history(rising(from: 100)), readingAt: at(1000)))
        let new = try XCTUnwrap(IslandSparkline.frame(history: history(rising(from: 110)), readingAt: at(1001)))
        let ring = zip(old.ring, new.ring).map { ($0 + $1) / 2 }
        let p = IslandSparkline.points(endSlot: 1000.5, ring: ring,
                                       lowMgdl: (old.lowMgdl + new.lowMgdl) / 2, highMgdl: (old.highMgdl + new.highMgdl) / 2)
        XCTAssertEqual(p.last?.back ?? 0, -0.5, accuracy: 1e-9)
        XCTAssertEqual(p.first?.back ?? 0, 12.5, accuracy: 1e-9)
        // Oldest first, evenly spaced.
        for (a, b) in zip(p, p.dropFirst()) { XCTAssertEqual(a.back - b.back, 1, accuracy: 1e-9) }
    }

    func testIndexWrapsForAnySlot() {
        XCTAssertEqual(IslandSparkline.index(16), 0)
        XCTAssertEqual(IslandSparkline.index(17), 1)
        XCTAssertEqual(IslandSparkline.index(-1), 15)
    }
}
