import XCTest
@testable import GlucOSEngine

/// "You logged a similar meal 3 min ago · View" (docs/SimilarEntry.md): a quiet note in the log
/// sheet when the same kind of entry with about the same amount was logged in the last 10 minutes.
final class SimilarEntryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_763_550_000)

    private func dose(_ units: Double, ago: TimeInterval = 0, kind: InsulinKind = .rapid,
                      name: String = "NovoRapid") -> LogEntry {
        .dose(InsulinDose(timestamp: now.addingTimeInterval(-ago), units: units, kind: kind, name: name))
    }

    private func meal(_ carbs: Double, ago: TimeInterval = 0, food: String = "") -> LogEntry {
        .meal(MealEntry(timestamp: now.addingTimeInterval(-ago), carbs: carbs, food: food))
    }

    private func match(_ drafts: [LogEntry], _ entries: [LogEntry], excluding: Set<UUID> = [],
                       isFollower: Bool = false) -> SimilarEntry.Match? {
        SimilarEntry.match(for: drafts, in: entries, now: now, excluding: excluding, isFollower: isFollower)
    }

    // MARK: What matches

    func testSiriMealThenTypedMealMatches() {
        let siri = meal(45, ago: 180)
        let m = match([meal(45, food: "Toast")], [siri])
        XCTAssertEqual(m?.entry.id, siri.id)
        XCTAssertEqual(m?.kind, .meal)
        XCTAssertEqual(m?.minutes, 3)
        XCTAssertEqual(m?.line, "You logged a similar meal 3 min ago")
        XCTAssertEqual(m?.spoken, "You logged a similar meal 3 minutes ago")
    }

    func testSimilarAmountsMatchWithinSlack() {
        // 5 g, or 10% of the larger, either way.
        XCTAssertNotNil(match([meal(30)], [meal(35, ago: 60)]))
        XCTAssertNil(match([meal(30)], [meal(36, ago: 60)]))
        XCTAssertNotNil(match([meal(90)], [meal(99, ago: 60)]))
        XCTAssertNil(match([meal(90)], [meal(101, ago: 60)]))
        // 0.5 u, or 10%.
        XCTAssertNotNil(match([dose(4)], [dose(4.5, ago: 60)]))
        XCTAssertNil(match([dose(4)], [dose(4.6, ago: 60)]))
        XCTAssertNotNil(match([dose(10)], [dose(11, ago: 60)]))
    }

    func testOnlyTheLastTenMinutes() {
        XCTAssertNotNil(match([meal(45)], [meal(45, ago: SimilarEntry.window)]))
        XCTAssertNil(match([meal(45)], [meal(45, ago: SimilarEntry.window + 1)]))
        // Another device's clock a little ahead still counts as just logged; far ahead doesn't.
        XCTAssertEqual(match([meal(45)], [meal(45, ago: -30)])?.minutes, 0)
        XCTAssertEqual(match([meal(45)], [meal(45, ago: -30)])?.line, "You logged a similar meal just now")
        XCTAssertNil(match([meal(45)], [meal(45, ago: -(SimilarEntry.clockSlack + 1))]))
    }

    func testDraftTimedAwayFromTheEarlierOneDoesNotMatch() {
        // The sheet's time moved back an hour: an entry logged a minute ago isn't that one.
        var draft = MealEntry(timestamp: now.addingTimeInterval(-3600), carbs: 45)
        XCTAssertNil(match([.meal(draft)], [meal(45, ago: 60)]))
        draft.timestamp = now.addingTimeInterval(-5 * 60)
        XCTAssertNotNil(match([.meal(draft)], [meal(45, ago: 60)]))
    }

    func testDifferentKindsDoNotMatch() {
        XCTAssertNil(match([meal(4)], [dose(4, ago: 60)]))
        XCTAssertNil(match([dose(4, kind: .rapid)], [dose(4, ago: 60, kind: .long)]))
        let site = LogEntry.siteChange(SiteChange(timestamp: now.addingTimeInterval(-60), site: .abdomenLeft))
        XCTAssertNil(match([site], [site]))
    }

    func testNamesMustAgreeWhenBothGiven() {
        XCTAssertNil(match([dose(4, name: "Fiasp")], [dose(4, ago: 60, name: "NovoRapid")]))
        XCTAssertNotNil(match([dose(4, name: "novo rapid")], [dose(4, ago: 60, name: "NovoRapid")]))
        XCTAssertNotNil(match([dose(4, name: "")], [dose(4, ago: 60, name: "NovoRapid")]))
        XCTAssertNil(match([meal(30, food: "Apple")], [meal(30, ago: 60, food: "Banana")]))
        XCTAssertNotNil(match([meal(30, food: " toast,  Butter ")], [meal(30, ago: 60, food: "Toast, butter")]))
    }

    func testMealWithNoCarbsMatchesOnlyTheSameFood() {
        XCTAssertNotNil(match([meal(0, food: "Coffee")], [meal(0, ago: 60, food: "coffee")]))
        XCTAssertNil(match([meal(0, food: "Coffee")], [meal(0, ago: 60, food: "Tea")]))
        XCTAssertNil(match([meal(0, food: "Toast")], [meal(30, ago: 60, food: "Toast")]))
        XCTAssertNil(match([meal(0)], [meal(0, ago: 60)]))
    }

    func testNothingTypedYetNeverMatches() {
        XCTAssertNil(match([dose(0)], [dose(0, ago: 60)]))
        XCTAssertNil(match([], [meal(45, ago: 60)]))
    }

    // MARK: Which one, and what it says

    func testClosestInTimeWins() {
        let older = meal(45, ago: 8 * 60)
        let newer = meal(46, ago: 2 * 60)
        XCTAssertEqual(match([meal(45)], [older, newer])?.entry.id, newer.id)
    }

    func testMealAndDoseBothMatching() {
        let m = meal(45, ago: 4 * 60), d = dose(4, ago: 3 * 60)
        let found = match([meal(45), dose(4)], [m, d])
        XCTAssertEqual(found?.kind, .mealAndDose)
        XCTAssertEqual(found?.entry.id, d.id, "View shows the most recent of the two")
        XCTAssertEqual(found?.line, "You logged a similar meal and dose 3 min ago")
        // Only the dose matches: it's about the dose.
        XCTAssertEqual(match([meal(80), dose(4)], [m, d])?.kind, .dose)
    }

    func testOwnEntriesAndEditedEntryNeverMatch() {
        let draft = meal(45)
        XCTAssertNil(match([draft], [draft]))
        let earlier = meal(45, ago: 60)
        XCTAssertNil(match([meal(45)], [earlier], excluding: [earlier.id]))
    }

    func testFollowersNeverSeeIt() {
        XCTAssertNil(match([meal(45)], [meal(45, ago: 60)], isFollower: true))
    }

    func testMatchingNeverChangesAmounts() {
        let draft = meal(45, food: "Toast")
        let earlier = meal(40, ago: 60, food: "Toast")
        let found = match([draft], [earlier])
        XCTAssertEqual(found?.entry, earlier)
        if case .meal(let m) = draft { XCTAssertEqual(m.carbs, 45) }
    }

    func testDetailNamesTimeAndEntry() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        let d = SimilarEntry.detail(meal(45, ago: 0, food: "Toast"), calendar: calendar, locale: Locale(identifier: "en_AU"))
        XCTAssertTrue(d.hasSuffix(" · 45 g · Toast"), d)
    }
}

extension SimilarEntryTests {
    func testWhatsNewHighlightFits() throws {
        let release = try XCTUnwrap(WhatsNewCatalog.releases.first { $0.version == "1.91.0" })
        let h = try XCTUnwrap(release.highlights.first { $0.title == "A note when it looks logged already" })
        XCTAssertLessThanOrEqual(h.title.count, 40)
        XCTAssertTrue(h.detail.hasSuffix("."))
        for word in ["bolus", "dose", "units", "correct"] {
            XCTAssertFalse(h.detail.lowercased().contains(word), word)
        }
    }
}
