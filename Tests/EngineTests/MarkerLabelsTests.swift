import XCTest
@testable import GlucOSEngine

/// Which logged markers get a short label beside them, and where it goes.
final class MarkerLabelsTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func candidate(_ id: UUID, x: Double, y: Double = 100, text: String = "45 g",
                           priority: Int = 1, ago minutes: Double = 0) -> MarkerLabels.Candidate {
        .init(id: id, x: x, y: y, text: text, priority: priority, date: now.addingTimeInterval(-minutes * 60))
    }

    func testOnlyWhenZoomedIn() {
        // iPhone's plot is about 330 pt: 3 h and 6 h have room, 12 h and 24 h don't.
        XCTAssertTrue(MarkerLabels.zoomedIn(plotWidth: 330, hours: 3))
        XCTAssertTrue(MarkerLabels.zoomedIn(plotWidth: 330, hours: 6))
        XCTAssertFalse(MarkerLabels.zoomedIn(plotWidth: 330, hours: 12))
        XCTAssertFalse(MarkerLabels.zoomedIn(plotWidth: 0, hours: 3))
        XCTAssertFalse(MarkerLabels.zoomedIn(plotWidth: 330, hours: 0))

        let one = [candidate(a, x: 100)]
        let obstacles = [(x: 100.0, y: 100.0)]
        XCTAssertEqual(MarkerLabels.shown(one, obstacles: obstacles, plotWidth: 330, hours: 3), [a])
        XCTAssertEqual(MarkerLabels.shown(one, obstacles: obstacles, plotWidth: 330, hours: 12), [])
    }

    func testOnlyAmountsGetLabels() {
        XCTAssertEqual(MarkerLabels.priority(.insulin), 2)
        XCTAssertEqual(MarkerLabels.priority(.meal), 1)
        XCTAssertEqual(MarkerLabels.priority(.treatment), 1)
        XCTAssertNil(MarkerLabels.priority(.wake))
        XCTAssertNil(MarkerLabels.priority(.note))
        XCTAssertNil(MarkerLabels.priority(.sensor))
        XCTAssertNil(MarkerLabels.priority(nil))
    }

    func testSitsAfterItsMarkerOrBeforeAtTheRightEdge() throws {
        let after = try XCTUnwrap(MarkerLabels.placement(candidate(a, x: 100), plotWidth: 330))
        XCTAssertFalse(after.leading)
        XCTAssertGreaterThanOrEqual(after.minX, 100 + MarkerLabels.markerSize / 2)

        let before = try XCTUnwrap(MarkerLabels.placement(candidate(a, x: 325), plotWidth: 330))
        XCTAssertTrue(before.leading)
        XCTAssertLessThanOrEqual(before.maxX, 325 - MarkerLabels.markerSize / 2)
        XCTAssertGreaterThanOrEqual(before.minX, 0)

        // Too narrow for either side.
        XCTAssertNil(MarkerLabels.placement(candidate(a, x: 10), plotWidth: 20))
    }

    func testCrowdedLabelsKeepTheHigherPriority() {
        // A meal and a dose logged together in neighbouring lanes, close enough to collide.
        let meal = candidate(a, x: 100, y: 100, text: "45 g", priority: 1)
        let dose = candidate(b, x: 104, y: 104, text: "4 u", priority: 2)
        let shown = MarkerLabels.shown([meal, dose], obstacles: [(x: 100, y: 100), (x: 104, y: 104)],
                                       plotWidth: 330, hours: 3)
        XCTAssertEqual(shown, [b])
    }

    func testEqualPriorityKeepsTheNewer() {
        let older = candidate(a, x: 100, ago: 10)
        let newer = candidate(b, x: 110, ago: 5)
        let shown = MarkerLabels.shown([older, newer], obstacles: [(x: 100, y: 100), (x: 110, y: 100)],
                                       plotWidth: 330, hours: 3)
        XCTAssertEqual(shown, [b])
    }

    func testALabelNeverCoversAnotherMarker() {
        // A wake-up (no label) sits right where the meal's label would go: the meal's is left out.
        let meal = candidate(a, x: 100)
        let shown = MarkerLabels.shown([meal], obstacles: [(x: 100, y: 100), (x: 125, y: 100)],
                                       plotWidth: 330, hours: 3)
        XCTAssertTrue(shown.isEmpty)
    }

    func testSpreadOutMarkersAllGetLabels() {
        let items = [candidate(a, x: 40), candidate(b, x: 140, text: "4 u", priority: 2), candidate(c, x: 240)]
        let shown = MarkerLabels.shown(items, obstacles: items.map { (x: $0.x, y: $0.y) }, plotWidth: 330, hours: 3)
        XCTAssertEqual(shown, [a, b, c])
        // And none of the kept labels overlap.
        let placed = MarkerLabels.placements(items, plotWidth: 330)
        let kept = shown.compactMap { placed[$0] }
        for (i, p) in kept.enumerated() {
            for q in kept[(i + 1)...] { XCTAssertFalse(MarkerLabels.overlaps(p, q)) }
        }
    }

    func testFadeIsShort() {
        XCTAssertLessThanOrEqual(MarkerLabels.fadeDuration + MarkerLabels.fadeInDelay, 0.4)
    }
}
