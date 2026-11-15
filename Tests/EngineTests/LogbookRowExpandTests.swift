import XCTest
@testable import GlucOSEngine

/// An iPhone Logbook row opening into its detail (docs/Redesign.md §7.2): the card starts exactly
/// on the row, opens in place, follows a drag down, and lists what the entry holds as logged.
final class LogbookRowExpandTests: XCTestCase {
    private let container = CGSize(width: 390, height: 700)
    private let row = CGRect(x: 20, y: 300, width: 350, height: 44)

    // MARK: Geometry

    func testStartsOnTheRowAndEndsOpen() {
        let open = LogbookRowExpand.openFrame(row: row, contentHeight: 260, in: container)
        XCTAssertEqual(LogbookRowExpand.frame(row: row, open: open, progress: 0), row)
        XCTAssertEqual(LogbookRowExpand.frame(row: row, open: open, progress: 1), open)
        let half = LogbookRowExpand.frame(row: row, open: open, progress: 0.5)
        XCTAssertEqual(half.height, (row.height + open.height) / 2, accuracy: 1e-9)
        XCTAssertEqual(half.minX, (row.minX + open.minX) / 2, accuracy: 1e-9)
    }

    func testOpensInPlaceAcrossTheWidthAtItsNaturalHeight() {
        let open = LogbookRowExpand.openFrame(row: row, contentHeight: 260, in: container)
        XCTAssertEqual(open.minX, LogbookRowExpand.margin, accuracy: 1e-9)
        XCTAssertEqual(open.width, container.width - 2 * LogbookRowExpand.margin, accuracy: 1e-9)
        XCTAssertEqual(open.height, 260, accuracy: 1e-9)
        // Just above the row's own top, so the row's line barely moves.
        XCTAssertEqual(open.minY, row.minY - LogbookRowExpand.padding, accuracy: 1e-9)
    }

    func testARowNearTheBottomOpensUpwardsToFit() {
        let low = CGRect(x: 20, y: 640, width: 350, height: 44)
        let open = LogbookRowExpand.openFrame(row: low, contentHeight: 300, in: container)
        XCTAssertEqual(open.maxY, container.height - LogbookRowExpand.margin, accuracy: 1e-9)
        let high = CGRect(x: 20, y: 2, width: 350, height: 44)
        XCTAssertEqual(LogbookRowExpand.openFrame(row: high, contentHeight: 300, in: container).minY,
                       LogbookRowExpand.margin, accuracy: 1e-9)
    }

    func testATallCardIsCappedToTheScreen() {
        let open = LogbookRowExpand.openFrame(row: row, contentHeight: 5_000, in: container)
        XCTAssertEqual(open.height, container.height - 2 * LogbookRowExpand.margin, accuracy: 1e-9)
        XCTAssertEqual(open.minY, LogbookRowExpand.margin, accuracy: 1e-9)
    }

    func testBeforeItIsMeasuredTheCardIsAtLeastTheRow() {
        for h in [0, -10, Double.nan] {
            let open = LogbookRowExpand.openFrame(row: row, contentHeight: h, in: container)
            XCTAssertEqual(open.height, row.height, accuracy: 1e-9)
        }
    }

    func testSpringOvershootIsKeptButFadesAreClamped() {
        let open = LogbookRowExpand.openFrame(row: row, contentHeight: 260, in: container)
        XCTAssertGreaterThan(LogbookRowExpand.frame(row: row, open: open, progress: 1.04).height, open.height)
        XCTAssertEqual(LogbookRowExpand.detailOpacity(progress: 1.04), 1)
        XCTAssertEqual(LogbookRowExpand.scrim(progress: 1.2), LogbookRowExpand.scrimOpacity, accuracy: 1e-9)
        XCTAssertEqual(LogbookRowExpand.corner(progress: -0.1), 0)
        XCTAssertEqual(LogbookRowExpand.frame(row: row, open: open, progress: .nan), row)
    }

    func testDetailsStayHiddenUntilThereIsRoom() {
        XCTAssertEqual(LogbookRowExpand.detailOpacity(progress: 0), 0)
        XCTAssertEqual(LogbookRowExpand.detailOpacity(progress: 0.3), 0)
        XCTAssertGreaterThan(LogbookRowExpand.detailOpacity(progress: 0.6), 0)
        XCTAssertEqual(LogbookRowExpand.detailOpacity(progress: 0.9), 1, accuracy: 1e-9)
        var last = -1.0
        for i in 0...20 {
            let o = LogbookRowExpand.detailOpacity(progress: Double(i) / 20)
            XCTAssertGreaterThanOrEqual(o, last)
            last = o
        }
    }

    func testRowEdgesAreSquareAndOpenCardIsRounded() {
        XCTAssertEqual(LogbookRowExpand.corner(progress: 0), 0)
        XCTAssertEqual(LogbookRowExpand.inset(progress: 0), 0)
        XCTAssertEqual(LogbookRowExpand.corner(progress: 1), LogbookRowExpand.cornerRadius)
        XCTAssertEqual(LogbookRowExpand.inset(progress: 1), LogbookRowExpand.padding)
    }

    // MARK: Drag and style

    func testDragDownFollowsTheFingerAndUpDoesNothing() {
        XCTAssertEqual(LogbookRowExpand.dragProgress(translation: -80), 1)
        XCTAssertEqual(LogbookRowExpand.dragProgress(translation: 0), 1)
        XCTAssertEqual(LogbookRowExpand.dragProgress(translation: LogbookRowExpand.dragRange / 2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(LogbookRowExpand.dragProgress(translation: LogbookRowExpand.dragRange * 3), 0)
        XCTAssertEqual(LogbookRowExpand.dragProgress(translation: .nan), 1)
    }

    func testReleaseClosesOnDistanceOrAFlick() {
        XCTAssertFalse(LogbookRowExpand.closesOnRelease(translation: 30, predictedEnd: 40))
        XCTAssertTrue(LogbookRowExpand.closesOnRelease(translation: LogbookRowExpand.closeDistance, predictedEnd: 0))
        XCTAssertTrue(LogbookRowExpand.closesOnRelease(translation: 30, predictedEnd: 400))
        XCTAssertFalse(LogbookRowExpand.closesOnRelease(translation: -200, predictedEnd: -400))
        XCTAssertFalse(LogbookRowExpand.closesOnRelease(translation: .nan, predictedEnd: .nan))
    }

    func testReduceMotionCrossFades() {
        XCTAssertEqual(LogbookRowExpand.Style(reduceMotion: true), .crossFade)
        XCTAssertEqual(LogbookRowExpand.Style(reduceMotion: false), .matched)
    }

    func testCardClosesWhenItsEntryHasGone() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(LogbookRowExpand.stillOpen(a, among: [a, b]), a)
        XCTAssertNil(LogbookRowExpand.stillOpen(a, among: [b]))
        XCTAssertNil(LogbookRowExpand.stillOpen(nil, among: [a]))
    }

    // MARK: Detail lines

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testDoseListsEverythingAsLogged() {
        var d = InsulinDose(timestamp: t0, units: 4.5, kind: .rapid, name: "NovoRapid", site: .abdomenLeft, note: "Before pizza")
        d.purpose = .meal
        let lines = LogbookEntryDetail.lines(.dose(d), site: nil)
        XCTAssertEqual(lines.map(\.label), ["Amount", "Insulin", "Site", "For", "Note"])
        XCTAssertEqual(lines[0].value, LogFormat.units(4.5))
        XCTAssertEqual(lines[1].value, "NovoRapid (Rapid-acting)")
        XCTAssertEqual(lines[2].value, InjectionSite.abdomenLeft.title)
        XCTAssertTrue(lines[4].searchable)
        XCTAssertFalse(lines[0].searchable)
    }

    func testPumpDoseSaysPumpNotASite() {
        let d = InsulinDose(timestamp: t0, units: 2, kind: .rapid, viaPump: true)
        let lines = LogbookEntryDetail.lines(.dose(d), site: .armLeft)
        XCTAssertEqual(lines.map(\.label), ["Amount", "Insulin", "Given by"])
        XCTAssertEqual(lines[1].value, InsulinKind.rapid.title)
    }

    func testMealListsFoodsAndUncountedCarbs() {
        let plain = LogbookEntryDetail.lines(.meal(MealEntry(timestamp: t0, carbs: 0, food: "Toast")), site: nil)
        XCTAssertEqual(plain.map(\.label), ["Carbs", "Food"])
        XCTAssertEqual(plain[0].value, "Not counted")
        let counted = LogbookEntryDetail.lines(.meal(MealEntry(timestamp: t0, carbs: 45)), site: nil)
        XCTAssertEqual(counted.map(\.value), [LogFormat.grams(45)])
    }

    func testMomentsExplainTheirTags() {
        let c = ContextEvent(timestamp: t0, tags: [.exercise, .alcohol], note: "Soccer")
        let lines = LogbookEntryDetail.lines(.context(c), site: nil)
        XCTAssertEqual(lines.map(\.label), ["Exercise", "Alcohol", "Note"])
        XCTAssertEqual(lines[0].value, ContextTag.exercise.help)
    }

    func testWhenSaysHowLongAgoOnlyForTheLastDay() {
        XCTAssertTrue(LogbookEntryDetail.when(t0, now: t0.addingTimeInterval(2 * 3600)).hasSuffix("2 h ago"))
        XCTAssertFalse(LogbookEntryDetail.when(t0, now: t0.addingTimeInterval(30)).contains("ago"))
        XCTAssertFalse(LogbookEntryDetail.when(t0, now: t0.addingTimeInterval(3 * 86_400)).contains("ago"))
    }
}
