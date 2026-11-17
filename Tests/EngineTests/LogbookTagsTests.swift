import XCTest
@testable import GlucOSEngine

/// Tags on Logbook entries (docs/LogbookTags.md): how they're kept, synced and filtered by.
final class LogbookTagsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func meal(_ food: String, tags: [String]? = nil, at offset: TimeInterval = 0) -> MealEntry {
        MealEntry(timestamp: t0.addingTimeInterval(offset), carbs: 40, food: food, labels: tags)
    }

    // MARK: Storage

    func testTagsAreTidiedAndBuiltInsKeepTheirSpelling() {
        XCTAssertEqual(LogbookTags.cleaned("  night   shift "), "night shift")
        XCTAssertEqual(LogbookTags.cleaned("#travel"), "travel")
        XCTAssertEqual(LogbookTags.cleaned("EXERCISE"), "Exercise")
        XCTAssertEqual(LogbookTags.cleaned("sick"), "Sick")
        XCTAssertNil(LogbookTags.cleaned("   "))
        XCTAssertNil(LogbookTags.cleaned("#"))
        let long = String(repeating: "a", count: 40)
        XCTAssertEqual(LogbookTags.cleaned(long)?.count, LogbookTags.maxLength)
    }

    func testRepeatsInAnySpellingAreDroppedAndTheListIsCapped() {
        XCTAssertEqual(LogbookTags.normalised(["Travel", "travel ", "TRAVEL", "Exercise", "exercise"]), ["Travel", "Exercise"])
        XCTAssertEqual(LogbookTags.key("Café  Run"), LogbookTags.key("cafe run"))
        let many = (1...20).map { "Tag \($0)" }
        XCTAssertEqual(LogbookTags.normalised(many).count, LogbookTags.maxPerEntry)
    }

    func testTogglingAddsThenRemovesInAnySpelling() {
        var tags: [String] = []
        tags = LogbookTags.toggling("Travel", in: tags)
        tags = LogbookTags.toggling("stress", in: tags)
        XCTAssertEqual(tags, ["Travel", "Stress"])
        tags = LogbookTags.toggling("travel", in: tags)
        XCTAssertEqual(tags, ["Stress"])
        XCTAssertEqual(LogbookTags.toggling("  ", in: tags), ["Stress"], "nothing typed changes nothing")
    }

    func testAnUntaggedEntryEncodesExactlyAsBefore() throws {
        let m = meal("Toast")
        let json = try XCTUnwrap(LogbookMerge.json(m))
        XCTAssertNil(json["labels"], "no tags, no key: older apps and old files see the same JSON")
        XCTAssertEqual(LogEntry.meal(m).withLabels(["  "]), .meal(m), "only blank tags leaves it untagged")
        if case .meal(let back) = LogEntry.meal(meal("Toast", tags: ["Travel"])).withLabels([]) {
            XCTAssertNil(back.labels, "clearing the tags removes the key again")
        } else { XCTFail() }
    }

    func testOldEntriesWithoutTagsStillDecode() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","timestamp":1790000000,"carbs":30,"food":"Apple","note":""}"#
        let m = try JSONDecoder().decode(MealEntry.self, from: Data(old.utf8))
        XCTAssertNil(m.labels)
        XCTAssertEqual(LogEntry.meal(m).labels, [])
        let ctx = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FE","timestamp":1790000000,"tags":["exercise"]}"#
        let c = try JSONDecoder().decode(ContextEvent.self, from: Data(ctx.utf8))
        XCTAssertNil(c.labels)
    }

    func testEveryKindOfEntryKeepsItsTagsThroughTheSyncPayload() throws {
        let entries: [LogEntry] = [
            .dose(InsulinDose(timestamp: t0, units: 4, kind: .rapid, name: "NovoRapid")),
            .meal(meal("Pasta")),
            .siteChange(SiteChange(timestamp: t0, site: .abdomenLeft)),
            .context(ContextEvent(timestamp: t0, tags: [.exercise], note: "run")),
        ].map { $0.withLabels(["Travel", "Night shift"]) }
        for e in entries {
            XCTAssertEqual(e.labels, ["Travel", "Night shift"])
            switch e {
            case .dose(let d):
                let back = try XCTUnwrap(LogbookMerge.json(d).flatMap { LogbookMerge.decode(InsulinDose.self, from: $0) })
                XCTAssertEqual(back, d)
            case .meal(let m):
                let back = try XCTUnwrap(LogbookMerge.json(m).flatMap { LogbookMerge.decode(MealEntry.self, from: $0) })
                XCTAssertEqual(back, m)
            case .siteChange(let s):
                let back = try XCTUnwrap(LogbookMerge.json(s).flatMap { LogbookMerge.decode(SiteChange.self, from: $0) })
                XCTAssertEqual(back, s)
            case .context(let c):
                let back = try XCTUnwrap(LogbookMerge.json(c).flatMap { LogbookMerge.decode(ContextEvent.self, from: $0) })
                XCTAssertEqual(back, c, "the context decoder reads tags too")
            }
        }
    }

    func testLogAgainKeepsTheTags() {
        let e = LogEntry.meal(meal("Porridge", tags: ["Travel"]))
        XCTAssertEqual(e.copied(at: t0.addingTimeInterval(3600)).labels, ["Travel"])
    }

    // MARK: Filter

    func testTagChipMatchesTaggedEntriesInAnySpelling() {
        let tagged = LogEntry.meal(meal("Pizza", tags: ["Travel"]))
        let other = LogEntry.meal(meal("Toast"))
        XCTAssertTrue(LogbookTags.matches(tagged, tag: "travel"))
        XCTAssertFalse(LogbookTags.matches(other, tag: "Travel"))
    }

    func testWhatElseIsGoingOnChoicesCountAsTheBuiltInTags() {
        let unwell = LogEntry.context(ContextEvent(timestamp: t0, tags: [.illness]))
        let run = LogEntry.context(ContextEvent(timestamp: t0, tags: [.exercise, .wokeUp]))
        let period = LogEntry.context(ContextEvent(timestamp: t0, tags: [.period]))
        XCTAssertTrue(LogbookTags.matches(unwell, tag: "Sick"))
        XCTAssertTrue(LogbookTags.matches(run, tag: "Exercise"))
        XCTAssertEqual(period.filterTags, [], "only the four built-ins have a match")
        let both = LogEntry.context(ContextEvent(timestamp: t0, tags: [.exercise], labels: ["Exercise"]))
        XCTAssertEqual(both.filterTags, ["Exercise"], "never listed twice")
    }

    func testChipsInUseAreMostUsedFirstThenByName() {
        let entries: [LogEntry] = [
            .meal(meal("A", tags: ["Travel"])),
            .meal(meal("B", tags: ["travel", "Alcohol"])),
            .meal(meal("C", tags: ["Birthday"])),
            .context(ContextEvent(timestamp: t0, tags: [.alcohol])),
            .meal(meal("D")),
        ]
        XCTAssertEqual(LogbookTags.used(entries), ["Alcohol", "Travel", "Birthday"])
        XCTAssertEqual(LogbookTags.used([]), [])
    }

    func testLogSheetOffersBuiltInsThenTheUsersOwnThenWhatsPicked() {
        let entries: [LogEntry] = [.meal(meal("A", tags: ["Travel"])), .meal(meal("B", tags: ["Travel", "Stress"]))]
        XCTAssertEqual(LogbookTags.choices(entries: []), LogbookTags.builtIn)
        XCTAssertEqual(LogbookTags.choices(entries: entries, picked: ["Gym day"]),
                       ["Exercise", "Sick", "Stress", "Alcohol", "Travel", "Gym day"])
    }

    func testSearchFindsTagsAndShowsThemInDetail() {
        let tagged = LogEntry.meal(meal("Pizza", tags: ["Night shift"]))
        let q = LogbookQuery.parse("shift", now: t0.addingTimeInterval(60))
        XCTAssertTrue(LogbookSearch.matches(tagged, q))
        let lines = LogbookEntryDetail.lines(tagged, site: nil)
        XCTAssertEqual(lines.first { $0.label == "Tags" }?.value, "Night shift")
    }

    func testEmptyListAndSearchAllDatesKnowAboutTheTagChip() {
        let none = LogbookQuery.parse("", now: t0)
        XCTAssertEqual(LogbookSearch.noMatchMessage(none, filter: nil, tag: "Travel"), "Nothing tagged Travel logged yet.")
        XCTAssertEqual(LogbookSearch.noMatchMessage(none, filter: .meals, tag: "Travel"), "Nothing in Meals tagged Travel logged yet.")
        XCTAssertTrue(LogbookSearch.offersAllDates(none, filter: nil, tag: "Travel", allDates: false))
        XCTAssertFalse(LogbookSearch.offersAllDates(none, filter: nil, tag: nil, allDates: false))
    }
}
