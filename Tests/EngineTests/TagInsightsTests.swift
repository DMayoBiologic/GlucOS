import XCTest
@testable import GlucOSEngine

/// Insights "Tags" (`TagInsights`): time in range and the average in the 4 hours after tagged
/// entries against the whole period, and the Logbook link each tag opens.
final class TagInsightsTests: XCTestCase {
    // referenceNow is on a 5-minute boundary. Readings every 5 minutes for 30 days, 120 mg/dL unless
    // `value` says otherwise. Low line 70, high line 180.

    private let size = Double(TodaySoFar.bucketMinutes) * 60

    private func history(skip: (Date) -> Bool = { _ in false },
                         value: (Date) -> Double? = { _ in nil }) -> [GlucoseReading] {
        var out: [GlucoseReading] = []
        var t = referenceNow.addingTimeInterval(-30 * 86_400 + 300)
        while t <= referenceNow {
            if !skip(t) { out.append(reading(t, value(t) ?? 120)) }
            t = t.addingTimeInterval(300)
        }
        return out
    }

    private func ago(days: Double = 0, hours: Double = 0, minutes: Double = 0) -> Date {
        referenceNow.addingTimeInterval(-(days * 86_400 + hours * 3600 + minutes * 60))
    }

    private func meal(_ at: Date, _ tags: [String]) -> LogEntry {
        .meal(MealEntry(timestamp: at, carbs: 30, food: "toast", labels: tags))
    }

    private func compute(_ readings: [GlucoseReading], _ entries: [LogEntry],
                         period: TagInsights.Period = .fortnight) -> TagInsights? {
        TagInsights.compute(readings: readings, entries: entries, low: 70, high: 180, period: period)
    }

    // MARK: The window

    func testWindowIsFourHoursOfBuckets() {
        // On a bucket boundary: the entry's bucket and the 47 after it.
        XCTAssertEqual(TagInsights.afterKeys([referenceNow], bucketSeconds: size).count, 48)
        // A minute in: the bucket it falls in, through the one holding 4 hours later.
        XCTAssertEqual(TagInsights.afterKeys([referenceNow.addingTimeInterval(60)], bucketSeconds: size).count, 49)
        XCTAssertTrue(TagInsights.afterKeys([], bucketSeconds: size).isEmpty)
    }

    func testOverlappingWindowsCountOnce() {
        let first = ago(hours: 10)
        let keys = TagInsights.afterKeys([first, first.addingTimeInterval(3600)], bucketSeconds: size)
        // 4 hours from the first, plus the one hour the second runs past it: 5 hours, not 8.
        XCTAssertEqual(keys.count, 60)
        // Two entries at the same moment are one window.
        XCTAssertEqual(TagInsights.afterKeys([first, first], bucketSeconds: size).count, 48)
        // Windows a day apart don't touch.
        XCTAssertEqual(TagInsights.afterKeys([first, first.addingTimeInterval(86_400)], bucketSeconds: size).count, 96)
    }

    // MARK: Figures

    func testAfterTagAgainstThePeriod() throws {
        // Three Exercise entries in the fortnight, each followed by 2 hours at 60 then 2 at 120.
        let runs = [ago(days: 2), ago(days: 3, hours: 5), ago(days: 5, hours: 9)]
        let readings = history(value: { t in
            runs.contains { t >= $0 && t < $0.addingTimeInterval(7200) } ? 60 : nil
        })
        let entries: [LogEntry] = [
            meal(runs[0], ["Exercise"]),
            meal(runs[1], ["exercise", "Work"]),
            // A "What else is going on?" exercise moment counts as Exercise, as on the Logbook chip.
            .context(ContextEvent(timestamp: runs[2], tags: [.exercise])),
            // Outside the fortnight: not counted.
            meal(ago(days: 20), ["Exercise"]),
            // Too recent for an hour of readings after it.
            meal(ago(minutes: 20), ["Travel"]),
            // Untagged entries are left alone.
            meal(ago(days: 1), []),
        ]
        let t = try XCTUnwrap(compute(readings, entries))

        // 14 × 288 buckets, 72 of them low.
        XCTAssertEqual(t.overall.buckets, 4032)
        XCTAssertEqual(t.overall.timeInRange, 3960.0 / 4032.0, accuracy: 1e-9)

        XCTAssertEqual(t.rows.map(\.tag), ["Exercise", "Travel", "Work"])
        let exercise = t.rows[0]
        XCTAssertEqual(exercise.entries, 3)
        let after = try XCTUnwrap(exercise.after)
        XCTAssertEqual(after.buckets, 144)
        XCTAssertEqual(after.timeInRange, 0.5, accuracy: 1e-9)
        XCTAssertEqual(after.averageMgdl, 90, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(t.gapPoints(exercise)), (0.5 - 3960.0 / 4032.0) * 100, accuracy: 1e-9)
        XCTAssertEqual(t.direction(exercise), -1)
        XCTAssertEqual(TagInsightsText.gap(exercise, in: t), "−48 vs all")
        XCTAssertEqual(TagInsightsText.detail(exercise, unit: .mgdl), "3 entries · average 90 mg/dL")
        XCTAssertEqual(TagInsightsText.spoken(exercise, in: t, unit: .mgdl),
                       "3 entries. In the 4 hours after: 50 percent in range, average 90 mg/dL. 48 points less than all readings.")

        // Travel: 5 buckets after it before the newest reading, short of an hour.
        let travel = t.rows[1]
        XCTAssertEqual(travel.entries, 1)
        XCTAssertNil(travel.after)
        XCTAssertNil(t.direction(travel))
        XCTAssertNil(TagInsightsText.gap(travel, in: t))
        XCTAssertEqual(TagInsightsText.detail(travel, unit: .mgdl), "1 entry · waiting for readings")

        // Work shares the second run's window: half low, so it reads the same as Exercise there.
        let work = try XCTUnwrap(t.rows[2].after)
        XCTAssertEqual(work.buckets, 48)
        XCTAssertEqual(work.timeInRange, 0.5, accuracy: 1e-9)
    }

    func testCloseToThePeriodReadsAboutTheSame() throws {
        let t = try XCTUnwrap(compute(history(), [meal(ago(days: 4), ["Work"])]))
        let work = t.rows[0]
        XCTAssertEqual(try XCTUnwrap(work.after).timeInRange, 1)
        XCTAssertEqual(t.direction(work), 0)
        XCTAssertEqual(TagInsightsText.gap(work, in: t), "about the same")
    }

    func testHigherInRangeAfterATag() throws {
        // Highs all day at 200, except the 4 hours after each walk.
        let walks = [ago(days: 1), ago(days: 2)]
        let readings = history(value: { t in
            walks.contains { t >= $0 && t < $0.addingTimeInterval(4 * 3600) } ? nil : 200
        })
        let t = try XCTUnwrap(compute(readings, walks.map { meal($0, ["Walk"]) }, period: .week))
        let walk = t.rows[0]
        XCTAssertEqual(try XCTUnwrap(walk.after).timeInRange, 1)
        XCTAssertEqual(t.direction(walk), 1)
        XCTAssertEqual(TagInsightsText.gap(walk, in: t), "+\(Int(((1 - t.overall.timeInRange) * 100).rounded())) vs all")
    }

    func testGapsInReadingsOnlyCountWhatWasRead() throws {
        // The sensor was off for the last 3 of the 4 hours after the tag.
        let at = ago(days: 3)
        let readings = history(skip: { $0 >= at.addingTimeInterval(3600) && $0 < at.addingTimeInterval(4 * 3600) })
        let t = try XCTUnwrap(compute(readings, [meal(at, ["Sick"])]))
        XCTAssertEqual(t.rows[0].after?.buckets, 12)
    }

    func testNothingTaggedInThePeriod() throws {
        let t = try XCTUnwrap(compute(history(), [meal(ago(days: 20), ["Travel"])], period: .week))
        XCTAssertTrue(t.rows.isEmpty)
        XCTAssertNil(compute([], [meal(ago(days: 1), ["Travel"])]))
    }

    func testListsAtMostSixTagsMostUsedFirst() throws {
        var entries: [LogEntry] = []
        for i in 0..<8 {
            for j in 0...i { entries.append(meal(ago(days: Double(j + 1), hours: Double(i)), ["Tag \(i)"])) }
        }
        let t = try XCTUnwrap(compute(history(), entries))
        XCTAssertEqual(t.rows.count, TagInsights.maxTags)
        XCTAssertEqual(t.rows.first?.tag, "Tag 7")
        XCTAssertEqual(t.rows.first?.entries, 8)
    }

    // MARK: Logbook

    func testTagOpensTheLogbookOnThatTagChip() {
        let link = LogbookLink.tag("Exercise", .fortnight, newestReading: referenceNow, now: referenceNow)
        XCTAssertEqual(link.tag, "Exercise")
        XCTAssertEqual(link.filter, .tagged)
        XCTAssertNil(link.kindChip, "every kind of entry carrying the tag shows")
        XCTAssertEqual(link.period.interval.start, referenceNow.addingTimeInterval(-14 * 86_400))
        XCTAssertEqual(link.period.label, "Last 14 days")
        XCTAssertEqual(link.sourceID, "logbook-tagged")
        XCTAssertFalse(LogbookFilter.tagged.isListed)
        XCTAssertTrue(LogbookFilter.tagged.matches(meal(referenceNow, []), lowIDs: []))
        XCTAssertEqual(LogbookFilter.tagged.insightsCard, .tagged)
        // Other cards' links keep their kind chip.
        XCTAssertEqual(LogbookLink.lows(.week, newestReading: referenceNow, now: referenceNow).kindChip, .lows)
    }
}
