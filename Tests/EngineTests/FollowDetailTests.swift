import XCTest
@testable import GlucOSEngine

/// The follower view's data on the phone: readings topped up from the share function, and the
/// owner's logbook decoded the same way logbook sync decodes it.
final class FollowDetailTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testMergeReplacesTheNewestBucketAndAsksFromItsStart() {
        var h = FollowHistory()
        XCTAssertNil(h.since)
        let t = now.timeIntervalSince1970
        h.merge([[t - 600, 100], [t - 300, 110], [t - 60, 120]], now: now)
        XCTAssertEqual(h.readings.map(\.mgdl), [100, 110, 120])
        let since = h.since!
        XCTAssertEqual(since, floor((t - 60) / 300) * 300)
        // The same bucket again, with more readings in it: replaced, not added.
        h.merge([[t - 10, 124]], now: now)
        XCTAssertEqual(h.readings.map(\.mgdl), [100, 110, 124])
        XCTAssertEqual(h.readings.last?.timestamp.timeIntervalSince1970, t - 10)
    }

    func testOldReadingsAndBadRowsAreDropped() {
        var h = FollowHistory()
        let t = now.timeIntervalSince1970
        h.merge([[t - 15 * 86_400, 90], [t - 3600, 0], [t - 3600], [t - 1800, 140]], now: now)
        XCTAssertEqual(h.readings.map(\.mgdl), [140])
        XCTAssertEqual(h.readings(lastHours: 1, now: now).count, 1)
        XCTAssertEqual(h.readings(lastHours: 0.25, now: now).count, 0)
    }

    func testLogbookDecodesSharedRecordsNewestFirst() throws {
        let t = now.timeIntervalSince1970
        let json = """
        {"readings": [[\(t - 60), 101]], "showsLogbook": true, "generatedAt": \(t), "logbook": [
          {"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "kind": "meal", "deleted": false, "modified": \(t),
           "payload": {"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "timestamp": \(t - 600), "carbs": 30, "food": "Toast", "note": ""}},
          {"id": "7F9619FF-8B86-D011-B42D-00C04FC964FF", "kind": "dose", "deleted": false, "modified": \(t),
           "payload": {"id": "7F9619FF-8B86-D011-B42D-00C04FC964FF", "timestamp": \(t - 1800), "units": 4, "kind": "rapid",
                       "name": "", "viaPump": false, "note": ""}},
          {"id": "8F9619FF-8B86-D011-B42D-00C04FC964FF", "kind": "somethingNew", "deleted": false, "modified": \(t),
           "payload": {"timestamp": \(t)}}
        ]}
        """
        let d = try JSONDecoder().decode(ShareDetail.self, from: Data(json.utf8))
        var detail = FollowDetail()
        detail.apply(d, now: now)
        XCTAssertEqual(detail.history.readings.count, 1)
        let entries = try XCTUnwrap(detail.logbook?.entries)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.phoneKindForTest, "meal")
        XCTAssertEqual(detail.logbook?.contents.doses.first?.units, 4)
        XCTAssertEqual(detail.logbook?.contents.meals.first?.food, "Toast")
    }

    func testHiddenLogbookIsNil() throws {
        let d = try JSONDecoder().decode(ShareDetail.self, from: Data(#"{"readings": [], "showsLogbook": false, "logbook": null, "generatedAt": 1}"#.utf8))
        var detail = FollowDetail()
        detail.apply(d, now: now)
        XCTAssertNil(detail.logbook)
        XCTAssertFalse(detail.showsLogbook)
    }

    func testOlderShareInfoWithoutTheSwitchShowsTheLogbook() throws {
        let s = try JSONDecoder().decode(ShareInfo.self, from: Data(#"{"id": "a", "label": "D", "createdAt": 1, "followers": 0}"#.utf8))
        XCTAssertTrue(s.logbookShown)
    }
}

private extension LogEntry {
    var phoneKindForTest: String {
        switch self {
        case .dose: return "dose"
        case .meal: return "meal"
        case .siteChange: return "site"
        case .context: return "context"
        }
    }
}
