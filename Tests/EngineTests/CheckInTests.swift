import XCTest
@testable import GlucOSEngine

/// Check-ins on the Live Activity: what the relay sends (supabase/functions/relay/checkins.ts)
/// decodes as the card's `checkIn`, and an old card without one still decodes.
final class CheckInTests: XCTestCase {
    private let card = #"{"mgdl":62,"trend":2,"readingAt":1790000000,"unit":"mmol","lowMgdl":70,"highMgdl":180,"history":[70,null,62],"forecast":[],"source":"relay""#

    func testRelayCardWithCheckInDecodes() throws {
        let json = card + #","checkIn":{"status":"asked","askedAt":1790000060,"who":"Sam","count":2}}"#
        let state = try JSONDecoder().decode(GlucoseActivityState.self, from: Data(json.utf8))
        XCTAssertEqual(state.checkIn?.status, .asked)
        XCTAssertEqual(state.checkIn?.askedAt, 1_790_000_060)
        XCTAssertEqual(state.checkIn?.askers, "Sam and 1 other")
        XCTAssertTrue(state.checkIn?.isWaiting ?? false)
        XCTAssertTrue(state.offersCheckIn)
    }

    func testCardWithoutCheckInDecodes() throws {
        let state = try JSONDecoder().decode(GlucoseActivityState.self, from: Data((card + "}").utf8))
        XCTAssertNil(state.checkIn)
        // Encoding leaves the key out, so the card's size and the relay's comparisons don't change.
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(state), as: UTF8.self).contains("checkIn"))
    }

    func testUnknownStatusShowsAsWaiting() throws {
        let c = try JSONDecoder().decode(CheckInState.self, from: Data(#"{"status":"onTheWay","askedAt":1}"#.utf8))
        XCTAssertEqual(c.status, .asked)
        XCTAssertEqual(c.askers, "Someone")
    }

    func testAnswersAndStatusRoundTrip() throws {
        let answered = try JSONDecoder().decode(CheckInState.self,
                                                from: Data(#"{"status":"help","askedAt":1,"answeredAt":61}"#.utf8))
        XCTAssertEqual(answered.status, .help)
        XCTAssertEqual(answered.answeredDate, Date(timeIntervalSince1970: 61))
        XCTAssertFalse(answered.isWaiting)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(CheckInAnswer(answer: .okay)), as: UTF8.self),
                       #"{"answer":"okay"}"#)
        let status = try JSONDecoder().decode(RelayStatus.self, from: Data(#"""
            {"version":"2.2.0","hasAccount":true,"hasDeviceToken":true,"hasPushToStartToken":true,
             "liveActivityEnabled":true,"alertsEnabled":true,"checkIn":{"status":"noAnswer","askedAt":5,"count":1}}
            """#.utf8))
        XCTAssertEqual(status.checkIn?.status, .noAnswer)
        XCTAssertEqual(status.checkIn?.askers, "Someone")
    }

    func testInRangeCardDoesNotOfferCheckIn() throws {
        let inRange = card.replacingOccurrences(of: #""mgdl":62"#, with: #""mgdl":120"#) + "}"
        XCTAssertFalse(try JSONDecoder().decode(GlucoseActivityState.self, from: Data(inRange.utf8)).offersCheckIn)
    }
}
