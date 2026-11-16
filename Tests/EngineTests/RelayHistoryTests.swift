import XCTest
@testable import GlucOSEngine

final class RelayHistoryTests: XCTestCase {
    func testDecodesTheRelaysReadings() throws {
        let json = #"{"readings": [[1794700000, 120, 3], [1794700060, 123.5, 4], [1794700120, 0, 3], [1794700180, 125]]}"#
        let h = try JSONDecoder().decode(RelayHistory.self, from: Data(json.utf8))
        let r = h.glucoseReadings
        XCTAssertEqual(r.map(\.mgdl), [120, 123.5, 125])
        XCTAssertEqual(r.map(\.trend), [.flat, .rising, .unknown])
        XCTAssertEqual(r.first?.timestamp, Date(timeIntervalSince1970: 1_794_700_000))
    }

    /// LibreLinkUp's 15-minute graph alone never counts as live readings in the replay; with the
    /// relay's one-minute readings filling the 5-minute slots between, it does, as on the Mac.
    func testRelayReadingsMakeTheReplayUseLiveReadings() {
        let start = Date(timeIntervalSince1970: 1_794_000_000)
        func value(_ m: Int) -> Double { 140 + 40 * sin(Double(m) / 45) }
        let graph = stride(from: 0, to: 2 * 1440, by: 15).map {
            GlucoseReading(timestamp: start.addingTimeInterval(Double($0) * 60), mgdl: value($0), trend: .flat)
        }
        let filled = stride(from: 0, to: 2 * 1440, by: 5).map {
            GlucoseReading(timestamp: start.addingTimeInterval(Double($0) * 60), mgdl: value($0), trend: .flat)
        }
        let now = start.addingTimeInterval(2 * 86_400)
        let sparse = ForecastBacktest.checks(readings: graph, doses: [], meals: [], contexts: [], profile: .empty, now: now)
        let dense = ForecastBacktest.checks(readings: filled, doses: [], meals: [], contexts: [], profile: .empty, now: now)
        XCTAssertFalse(sparse.checks.isEmpty)
        XCTAssertFalse(sparse.checks.contains(where: \.dense))
        XCTAssertFalse(dense.checks.isEmpty)
        XCTAssertTrue(dense.checks.allSatisfy(\.dense))
    }
}
