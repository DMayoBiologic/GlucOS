import XCTest
@testable import GlucOSEngine

final class ShareProtocolTests: XCTestCase {
    let token = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_AbCd"

    func testTokenShape() {
        XCTAssertEqual(token.count, 42)
        let t = token + "e"
        XCTAssertTrue(FollowLink.isToken(t))
        XCTAssertFalse(FollowLink.isToken(token))
        XCTAssertFalse(FollowLink.isToken(String(t.dropLast()) + "!"))
    }

    func testLinksRoundTrip() throws {
        let t = token + "e"
        let web = try XCTUnwrap(FollowLink.url(token: t))
        XCTAssertEqual(web.absoluteString, "https://gluc-os-seven.vercel.app/share/#\(t)")
        XCTAssertEqual(FollowLink.token(from: web), t)
        XCTAssertEqual(FollowLink.token(from: try XCTUnwrap(FollowLink.appURL(token: t))), t)
        XCTAssertEqual(FollowLink.token(from: try XCTUnwrap(URL(string: "glucos://follow?t=\(t)"))), t)
    }

    func testFindsTheLinkInAPastedMessage() {
        let t = token + "e"
        XCTAssertEqual(FollowLink.token(in: "Follow my glucose: https://gluc-os-seven.vercel.app/share/#\(t) 💙"), t)
        XCTAssertEqual(FollowLink.token(in: "  \(t)\n"), t)
        XCTAssertNil(FollowLink.token(in: "https://example.com/share/#\(t)"))
        XCTAssertNil(FollowLink.token(in: "glucos://open#\(t)"))
        XCTAssertNil(FollowLink.token(in: "nothing here"))
    }

    /// What the share function sends decodes, including a card with the relay's shape.
    func testSnapshotDecodes() throws {
        let json = """
        {"label":"Declan","expiresAt":null,"updatedAt":1790000000,"followID":"0b6e…",
         "card":{"mgdl":120,"trend":3,"readingAt":1789999970,"unit":"mmol","lowMgdl":70,"highMgdl":180,
                 "history":[118,null,120],"forecast":[121,122],"source":"relay"}}
        """
        let s = try JSONDecoder().decode(ShareSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(s.label, "Declan")
        XCTAssertNil(s.expiresAt)
        XCTAssertEqual(s.card?.mgdl, 120)
        XCTAssertEqual(s.card?.history, [118, nil, 120])
        let empty = try JSONDecoder().decode(ShareSnapshot.self, from: Data(#"{"label":"X","card":null,"followID":"f"}"#.utf8))
        XCTAssertNil(empty.card)
    }

    func testFollowRegistrationLeavesOutUnchangedFields() throws {
        var r = FollowRegistration(installation: "phone-1")
        r.liveActivityEnabled = false
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["installation", "liveActivityEnabled"])
    }

    func testDurations() {
        XCTAssertEqual(ShareDuration.day.seconds, 86_400)
        XCTAssertNil(ShareDuration.untilStopped.seconds)
        let info = ShareInfo(id: "a", label: "x", createdAt: 0, expiresAt: 100, lastViewedAt: nil, followers: 0)
        XCTAssertTrue(info.isExpired(at: Date(timeIntervalSince1970: 100)))
        XCTAssertFalse(info.isExpired(at: Date(timeIntervalSince1970: 99)))
    }

    func testShareMessageWording() {
        XCTAssertEqual(ShareMessage.cleanLabel("  "), "GlucOS")
        XCTAssertEqual(ShareMessage.cleanLabel(" Declan "), "Declan")
        XCTAssertEqual(ShareMessage.cleanLabel(String(repeating: "a", count: 60)).count, 40)
        XCTAssertEqual(ShareMessage.title(label: "GlucOS"), "My glucose")
        XCTAssertEqual(ShareMessage.title(label: "Declan"), "Declan's glucose")
        XCTAssertEqual(ShareMessage.text(label: "GlucOS"), "Follow my glucose live in GlucOS:")
    }

    func testMessagesBubbleLinkCarriesTheToken() throws {
        // A Messages bubble's URL is the web link, so the bubble and the web view share one token.
        let t = String(repeating: "A", count: 43)
        let url = try XCTUnwrap(FollowLink.url(token: t))
        XCTAssertEqual(FollowLink.token(from: url), t)
        XCTAssertEqual(FollowLink.serviceURL.absoluteString, "https://aqlbadbyjuoruwnwyfrc.supabase.co/functions/v1/share")
    }
}
