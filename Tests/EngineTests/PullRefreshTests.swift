import XCTest
@testable import GlucOSEngine

/// Pull-to-refresh on the iPhone Today screen: the ring fills only as steps finish, a pull reuses
/// a fetch that has just happened, and the light tap is for new data only.
final class PullRefreshTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testPullProgressClampsToArmDistance() {
        XCTAssertEqual(PullRefresh.pullProgress(overscroll: -20), 0)
        XCTAssertEqual(PullRefresh.pullProgress(overscroll: .nan), 0)
        XCTAssertEqual(PullRefresh.pullProgress(overscroll: PullRefresh.armDistance / 2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(PullRefresh.pullProgress(overscroll: PullRefresh.armDistance * 3), 1)
    }

    func testFillStartsAsASliverAndOnlyCompletesWhenEveryStepIsDone() {
        XCTAssertEqual(PullRefresh.fill(completed: 0, of: 2), PullRefresh.startFill, accuracy: 1e-9)
        let half = PullRefresh.fill(completed: 1, of: 2)
        XCTAssertGreaterThan(half, PullRefresh.startFill)
        XCTAssertLessThan(half, 1)
        XCTAssertEqual(PullRefresh.fill(completed: 2, of: 2), 1, accuracy: 1e-9)
        // Out-of-range counts stay inside the ring.
        XCTAssertEqual(PullRefresh.fill(completed: 5, of: 2), 1, accuracy: 1e-9)
        XCTAssertEqual(PullRefresh.fill(completed: -1, of: 2), PullRefresh.startFill, accuracy: 1e-9)
        XCTAssertEqual(PullRefresh.fill(completed: 1, of: 0), 1, accuracy: 1e-9)
    }

    func testFillNeverGoesBackwards() {
        var last = -1.0
        for done in 0...3 {
            let f = PullRefresh.fill(completed: done, of: 3)
            XCTAssertGreaterThan(f, last)
            last = f
        }
    }

    func testAFetchThatJustFinishedIsTheRefresh() {
        XCTAssertFalse(PullRefresh.needsFetch(fetchedAt: t0, lastError: nil, now: t0.addingTimeInterval(3)))
        XCTAssertTrue(PullRefresh.needsFetch(fetchedAt: t0, lastError: nil, now: t0.addingTimeInterval(PullRefresh.freshFor)))
        XCTAssertTrue(PullRefresh.needsFetch(fetchedAt: t0, lastError: "timed out", now: t0.addingTimeInterval(1)))
        XCTAssertTrue(PullRefresh.needsFetch(fetchedAt: nil, lastError: nil, now: t0))
        // A clock that moved backwards isn't "fresh".
        XCTAssertTrue(PullRefresh.needsFetch(fetchedAt: t0, lastError: nil, now: t0.addingTimeInterval(-60)))
    }

    func testOutcome() {
        let before = PullRefresh.Marker(latest: t0, archived: 100)
        XCTAssertEqual(PullRefresh.outcome(before: before, after: .init(latest: t0.addingTimeInterval(60), archived: 100), failed: false), .newData)
        // The relay's readings landing counts even when LibreLinkUp failed.
        XCTAssertEqual(PullRefresh.outcome(before: before, after: .init(latest: t0, archived: 112), failed: true), .newData)
        XCTAssertEqual(PullRefresh.outcome(before: before, after: before, failed: false), .unchanged)
        XCTAssertEqual(PullRefresh.outcome(before: before, after: before, failed: true), .failed)
        XCTAssertEqual(PullRefresh.outcome(before: .init(latest: nil, archived: 0), after: .init(latest: t0, archived: 0), failed: false), .newData)
        // Signing out isn't new data.
        XCTAssertEqual(PullRefresh.outcome(before: before, after: .init(latest: nil, archived: 100), failed: false), .unchanged)
    }
}
