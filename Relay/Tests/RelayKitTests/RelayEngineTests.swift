import XCTest
import Crypto
import Hummingbird
@testable import RelayKit

final class FakeSender: PushSending, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [PushRequest] = []
    var results: [String: PushResult] = [:]

    var sent: [PushRequest] { lock.withLock { _sent } }
    func clear() { lock.withLock { _sent = [] } }

    func send(_ push: PushRequest) async -> PushResult {
        lock.withLock { _sent.append(push) }
        return results[push.deviceToken] ?? .delivered
    }
}

final class FakeFetcher: GlucoseFetching, @unchecked Sendable {
    var mgdl: Double = 120
    var trend: Trend = .flat
    var clock: () -> Date
    /// Pin the reading's time, as if LibreLinkUp had nothing new.
    var readingAt: Date?
    /// Runs while the fetch is in flight, before it returns.
    var duringFetch: (() async -> Void)?

    init(clock: @escaping () -> Date) { self.clock = clock }

    func fetch(_ account: RelayRegistration.Account) async throws -> LibreLinkUpClient.Result {
        await duringFetch?()
        let now = readingAt ?? clock()
        let history = stride(from: 180, through: 5, by: -5).map {
            GlucoseReading(timestamp: now.addingTimeInterval(-Double($0) * 60), mgdl: mgdl, trend: .flat)
        }
        return .init(current: GlucoseReading(timestamp: now.addingTimeInterval(-30), mgdl: mgdl, trend: trend),
                     history: history, sensor: nil)
    }
}

final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_790_000_000)
}

final class RelayEngineTests: XCTestCase {
    var clock: Clock!
    var sender: FakeSender!
    var fetcher: FakeFetcher!
    var engine: RelayEngine!

    override func setUp() async throws {
        clock = Clock()
        sender = FakeSender()
        let c = clock!
        fetcher = FakeFetcher(clock: { c.now })
        engine = RelayEngine(config: RelayConfig(secret: "s", dataDirectory: URL(fileURLWithPath: "/tmp")),
                             sender: sender, fetcher: fetcher, store: nil, clock: { c.now })
        var reg = RelayRegistration()
        reg.deviceToken = "device"
        reg.pushToStartToken = "p2s"
        reg.account = .init(email: "a@b.c", password: "x", region: "au", clientVersion: "4.16.0", sensorLifetimeDays: 15)
        reg.display = .init(unit: "mmol", lowMgdl: 70, highMgdl: 180)
        _ = await engine.register(reg)
    }

    func testLowReadingSendsAnAlertPush() async throws {
        fetcher.mgdl = 62
        await engine.tick()
        let alerts = sender.sent.filter { $0.type == .alert }
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].collapseID, "glucos.low")
        XCTAssertEqual(alerts[0].priority, 10)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: alerts[0].payload) as? [String: Any])
        let aps = try XCTUnwrap(json["aps"] as? [String: Any])
        XCTAssertEqual((aps["alert"] as? [String: Any])?["title"] as? String, "Low glucose — 3.4 mmol/L")
        // Not again on the next fetch.
        sender.clear()
        clock.now += 60
        await engine.tick()
        XCTAssertTrue(sender.sent.filter { $0.type == .alert }.isEmpty)
    }

    func testSignOutDuringAFetchDiscardsItsReadings() async {
        fetcher.mgdl = 62
        let engine = engine!
        fetcher.duringFetch = {
            var reg = RelayRegistration()
            reg.signedOut = true
            _ = await engine.register(reg)
        }
        await engine.tick()
        let status = await engine.status()
        XCTAssertFalse(status.hasAccount)
        XCTAssertNil(status.lastReadingAt)
        XCTAssertTrue(sender.sent.filter { $0.type == .alert }.isEmpty)
    }

    func testInRangeSendsNoAlertAndNoActivityWithoutOne() async {
        await engine.tick()
        XCTAssertTrue(sender.sent.isEmpty)
    }

    func testRegisteredActivityGetsUpdatesThatDecodeAsTheCardState() async throws {
        var reg = RelayRegistration()
        reg.activityID = "A1"
        reg.activityToken = "act"
        _ = await engine.register(reg)
        await engine.tick()
        let push = try XCTUnwrap(sender.sent.first { $0.type == .liveactivity })
        XCTAssertEqual(push.deviceToken, "act")
        XCTAssertEqual(push.topic, "au.com.declanmayo.glucos.ios")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: push.payload) as? [String: Any])
        let aps = try XCTUnwrap(json["aps"] as? [String: Any])
        XCTAssertEqual(aps["event"] as? String, "update")
        let content = try JSONSerialization.data(withJSONObject: try XCTUnwrap(aps["content-state"]))
        let state = try JSONDecoder().decode(GlucoseActivityState.self, from: content)
        XCTAssertEqual(state.mgdl, 120)
        XCTAssertEqual(state.source, "relay")
        XCTAssertEqual(state.history.count, 37)

        // No new reading a minute later: nothing new to send.
        sender.clear()
        fetcher.readingAt = clock.now
        clock.now += 60
        await engine.tick()
        XCTAssertTrue(sender.sent.isEmpty)
    }

    func testActivityIsReplacedBeforeTheEightHourLimit() async throws {
        var reg = RelayRegistration()
        reg.activityID = "A1"
        reg.activityToken = "act"
        _ = await engine.register(reg)
        await engine.tick()
        sender.clear()
        clock.now += RelayEngine.rotateAfter + 60
        await engine.tick()
        let events = try sender.sent.map { p -> String in
            let aps = try XCTUnwrap((JSONSerialization.jsonObject(with: p.payload) as? [String: Any])?["aps"] as? [String: Any])
            return "\(p.deviceToken):\(aps["event"] as? String ?? "")"
        }
        XCTAssertEqual(events, ["act:end", "p2s:start"])
        let start = try XCTUnwrap(sender.sent.last)
        let aps = try XCTUnwrap((JSONSerialization.jsonObject(with: start.payload) as? [String: Any])?["aps"] as? [String: Any])
        XCTAssertEqual(aps["attributes-type"] as? String, "GlucoseActivityAttributes")
        XCTAssertNotNil(aps["alert"])

        // The phone reports the new activity; updates go to it.
        sender.clear()
        reg.activityID = "A2"
        reg.activityToken = "act2"
        _ = await engine.register(reg)
        clock.now += 60
        await engine.tick()
        XCTAssertEqual(sender.sent.map(\.deviceToken), ["act2"])
    }

    func testDismissedActivityIsNotRestarted() async {
        var reg = RelayRegistration()
        reg.activityID = "A1"
        reg.activityToken = "act"
        _ = await engine.register(reg)
        var ended = RelayRegistration()
        ended.endedActivityID = "A1"
        _ = await engine.register(ended)
        clock.now += 60
        await engine.tick()
        XCTAssertTrue(sender.sent.isEmpty)
    }

    func testInvalidDeviceTokenIsForgotten() async {
        sender.results["device"] = .tokenInvalid("Unregistered")
        fetcher.mgdl = 60
        await engine.tick()
        let status = await engine.status()
        XCTAssertFalse(status.hasDeviceToken)
        XCTAssertNotNil(status.lastPushError)
    }

    func testSignOutForgetsTheAccount() async {
        var reg = RelayRegistration()
        reg.signedOut = true
        let status = await engine.register(reg)
        XCTAssertFalse(status.hasAccount)
        await engine.tick()
        XCTAssertTrue(sender.sent.isEmpty)
    }
}

final class APNsTests: XCTestCase {
    func testProviderTokenIsAValidES256JWT() async throws {
        let key = P256.Signing.PrivateKey()
        let signer = try APNsTokenSigner(pem: key.pemRepresentation, keyID: "KEY123", teamID: "TEAM456")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let token = try await signer.token(now: now)
        let parts = token.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        func decode(_ s: String) -> Data {
            var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            return Data(base64Encoded: b)!
        }
        let header = try JSONSerialization.jsonObject(with: decode(parts[0])) as? [String: Any]
        XCTAssertEqual(header?["alg"] as? String, "ES256")
        XCTAssertEqual(header?["kid"] as? String, "KEY123")
        let claims = try JSONSerialization.jsonObject(with: decode(parts[1])) as? [String: Any]
        XCTAssertEqual(claims?["iss"] as? String, "TEAM456")
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
        XCTAssertTrue(key.publicKey.isValidSignature(sig, for: Data("\(parts[0]).\(parts[1])".utf8)))
        // Reused within the hour.
        let again = try await signer.token(now: now.addingTimeInterval(600))
        XCTAssertEqual(again, token)
    }

    func testCriticalSoundOnlyWhenEntitled() throws {
        let n = AlertNotice(kind: .urgentLow, title: "URGENT LOW", body: "Treat now", critical: true)
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: PushPayload.alert(n, criticalSound: false)) as? [String: Any])
        let aps = try XCTUnwrap(plain["aps"] as? [String: Any])
        XCTAssertEqual(aps["sound"] as? String, "default")
        XCTAssertEqual(aps["interruption-level"] as? String, "time-sensitive")
        let crit = try XCTUnwrap(JSONSerialization.jsonObject(with: PushPayload.alert(n, criticalSound: true)) as? [String: Any])
        XCTAssertEqual((crit["aps"] as? [String: Any])?["interruption-level"] as? String, "critical")
    }

    func testBearerComparison() {
        XCTAssertTrue(BearerAuth<BasicRequestContext>.constantTimeEqual("Bearer abc", "Bearer abc"))
        XCTAssertFalse(BearerAuth<BasicRequestContext>.constantTimeEqual("Bearer abd", "Bearer abc"))
        XCTAssertFalse(BearerAuth<BasicRequestContext>.constantTimeEqual("Bearer ab", "Bearer abc"))
        XCTAssertFalse(BearerAuth<BasicRequestContext>.constantTimeEqual("", "Bearer abc"))
    }
}
