import XCTest
@testable import GlucOSEngine

/// The sync client against a real Supabase stack (Auth, the Data API and the `account`
/// function). Skipped unless GLUCOS_SYNC_TEST_URL points at one whose `account` function
/// accepts the password "ok", like the local gateway used while developing this.
final class LogbookSyncClientTests: XCTestCase {
    func testTwoDevicesShareALogbook() async throws {
        guard let raw = ProcessInfo.processInfo.environment["GLUCOS_SYNC_TEST_URL"], let url = URL(string: raw) else {
            throw XCTSkip("GLUCOS_SYNC_TEST_URL not set")
        }
        let client = LogbookSyncClient(baseURL: url, apiKey: "test", session: .shared)
        let email = "sync-\(UUID().uuidString.prefix(8))@example.com"

        do {
            _ = try await client.signIn(email: email, password: "wrong", region: "au", clientVersion: "4.16.0")
            XCTFail("a refused login should throw")
        } catch LogbookSyncClient.SyncError.loginRejected(let m) {
            XCTAssertTrue(m.contains("rejected"))
        }

        var macSession = try await client.signIn(email: email, password: "ok", region: "au", clientVersion: "4.16.0")
        let phoneSession = try await client.signIn(email: email.uppercased(), password: "ok", region: "eu", clientVersion: "4.16.0")
        XCTAssertEqual(macSession.userID, phoneSession.userID, "same LibreLinkUp account, same user")
        macSession = try await client.refresh(macSession)

        var mac = LogbookContents(), phone = LogbookContents()
        var macState = LogbookSyncState(), phoneState = LogbookSyncState()
        mac.doses = [InsulinDose(timestamp: Date(timeIntervalSince1970: 1_790_000_000), units: 4, kind: .rapid)]
        mac.presets = [LogPreset(name: "Breakfast", units: 4, carbs: 40)]
        phone.meals = [MealEntry(timestamp: Date(timeIntervalSince1970: 1_790_000_100), carbs: 30, food: "Apple")]

        func sync(_ c: inout LogbookContents, _ st: inout LogbookSyncState, _ s: LogbookSyncSession, _ device: String) async throws {
            LogbookMerge.adopt(userID: s.userID, contents: c, state: &st)
            LogbookMerge.apply(try await client.pull(since: st.cursor, session: s), to: &c, state: &st)
            let out = LogbookMerge.outgoing(c, state: st, device: device)
            if !out.isEmpty { try await client.push(out, session: s) }
            LogbookMerge.pushed(out, state: &st)
        }

        try await sync(&mac, &macState, macSession, "Mac")
        try await sync(&phone, &phoneState, phoneSession, "iPhone")
        try await sync(&mac, &macState, macSession, "Mac")
        XCTAssertEqual(mac, phone)
        XCTAssertEqual(phone.doses.first?.units, 4)
        XCTAssertEqual(phone.presets.first?.name, "Breakfast")

        // A delete on the phone reaches the Mac.
        let id = mac.doses[0].id
        phone.doses.removeAll()
        LogbookMerge.touch(id, kind: .dose, deleted: true, now: Date(), state: &phoneState)
        try await sync(&phone, &phoneState, phoneSession, "iPhone")
        try await sync(&mac, &macState, macSession, "Mac")
        XCTAssertTrue(mac.doses.isEmpty)

        var expired = macSession
        expired.accessToken = "not-a-token"
        do {
            _ = try await client.pull(since: 0, session: expired)
            XCTFail("a bad token should throw")
        } catch LogbookSyncClient.SyncError.sessionExpired {}
    }
}
