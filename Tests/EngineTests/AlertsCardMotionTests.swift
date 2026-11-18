import XCTest
@testable import GlucOSEngine

final class AlertsCardMotionTests: XCTestCase {
    func testScaleUsesTheLargestCountAndNeverZero() {
        XCTAssertEqual(AlertsCardMotion.scale(counts: [0, 0, 0, 0]), 1)
        XCTAssertEqual(AlertsCardMotion.scale(counts: []), 1)
        XCTAssertEqual(AlertsCardMotion.scale(counts: [3, 1, 0, 2]), 3)
    }

    func testCompareSharesTheScaleSoBarsGlideWhenItTurnsOn() {
        let counts = [3, 1, 0, 2]
        XCTAssertEqual(AlertsCardMotion.scale(counts: counts, previous: [1, 1, 1, 1]), 3)
        // The period before had more: today's bars shrink to make room for its marks.
        let wider = AlertsCardMotion.scale(counts: counts, previous: [6, 0, 0, 0])
        XCTAssertEqual(wider, 6)
        XCTAssertEqual(AlertsCardMotion.fraction(3, scale: wider), 0.5, accuracy: 1e-9)
        XCTAssertEqual(AlertsCardMotion.fraction(3, scale: AlertsCardMotion.scale(counts: counts)), 1, accuracy: 1e-9)
    }

    func testFraction() {
        XCTAssertEqual(AlertsCardMotion.fraction(0, scale: 4, minimum: 0.1), 0)
        XCTAssertEqual(AlertsCardMotion.fraction(2, scale: 4), 0.5, accuracy: 1e-9)
        // One alert among many still shows.
        XCTAssertEqual(AlertsCardMotion.fraction(1, scale: 100, minimum: 0.05), 0.05, accuracy: 1e-9)
        XCTAssertEqual(AlertsCardMotion.fraction(9, scale: 4), 1)
        XCTAssertEqual(AlertsCardMotion.fraction(2, scale: 0), 0)
    }

    func testSharesSumToOneAndKeepOrder() {
        let shares = AlertsCardMotion.shares([2, 0, 1, 1])
        XCTAssertEqual(shares.count, 4)
        XCTAssertEqual(shares.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(shares[0], 0.5, accuracy: 1e-9)
        XCTAssertEqual(shares[1], 0)
        XCTAssertEqual(AlertsCardMotion.shares([0, 0, 0, 0]), [0, 0, 0, 0])
    }

    func testBarsGrowTopToBottomThenTheOutcomeBar() {
        let delays = AlertsSummary.Group.allCases.map { AlertsCardMotion.growDelay(order: $0.rawValue) }
        XCTAssertEqual(delays, delays.sorted())
        XCTAssertEqual(Set(delays).count, delays.count)
        XCTAssertGreaterThan(AlertsCardMotion.endingStart, delays.last ?? 0)
        // All done well inside a second, so the card settles as it finishes rising.
        XCTAssertLessThan(AlertsCardMotion.endingStart, 0.5)
        XCTAssertEqual(AlertsCardMotion.growDelay(order: -3), AlertsCardMotion.growStart)
    }

    func testPreviousCountsOnlyWithAPreviousPeriod() {
        XCTAssertNil(AlertsCardMotion.previousKinds(nil))
        XCTAssertNil(AlertsCardMotion.previousEndings(nil))
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let records = [AlertRecord(kind: .low, firedAt: now.addingTimeInterval(-86_400)),
                       AlertRecord(kind: .high, firedAt: now.addingTimeInterval(-2 * 86_400)),
                       AlertRecord(kind: .low, firedAt: now.addingTimeInterval(-3 * 86_400))]
        let s = AlertsSummary.compute(records: records, period: .week, end: now)
        let kinds = AlertsCardMotion.previousKinds(s)
        XCTAssertEqual(kinds?.count, AlertsSummary.Group.allCases.count)
        XCTAssertEqual(kinds?.reduce(0, +), s.count)
        XCTAssertEqual(AlertsCardMotion.previousEndings(s)?.reduce(0, +), s.count)
    }

    func testCompareWordsGiveNoAdvice() {
        let all = [AlertsSummaryText.previousMarkKey, AlertsSummaryText.previousShort, AlertsSummaryText.historyHint]
            .joined(separator: " ").lowercased()
        for word in ["should", "try ", "increase", "decrease", "reduce", "adjust"] {
            XCTAssertFalse(all.contains(word), word)
        }
    }
}
