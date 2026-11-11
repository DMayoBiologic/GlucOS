import Foundation
import AsyncHTTPClient
import Crypto
import NIOCore
import NIOFoundationCompat

// Apple Push Notification service: token-based auth (an ES256 JWT from the .p8 key) over
// HTTP/2. Payload shapes follow Apple's "Sending notification requests to APNs" and "Starting and
// updating Live Activities with ActivityKit push notifications".

/// One push to send.
struct PushRequest: Equatable {
    enum PushType: String { case alert, liveactivity }

    var deviceToken: String
    var type: PushType
    /// The app's bundle id; Live Activity pushes get `.push-type.liveactivity` added.
    var topic: String
    /// 10 sends now; 5 lets APNs batch it to save the phone's battery.
    var priority: Int
    var payload: Data
    var collapseID: String?
    /// Past this time APNs gives up rather than delivering late.
    var expiration: Date?
    var sandbox: Bool
}

enum PushResult: Equatable {
    case delivered
    /// The token will never work again (app deleted, activity ended): forget it.
    case tokenInvalid(String)
    case failed(String)
}

protocol PushSending: Sendable {
    func send(_ push: PushRequest) async -> PushResult
}

// MARK: - Payloads

enum PushPayload {
    static let activityAttributesType = "GlucoseActivityAttributes"

    static func alert(_ n: AlertNotice, criticalSound: Bool) -> Data {
        var aps: [String: Any] = [
            "alert": ["title": n.title, "body": n.body],
            "thread-id": "glucos.alerts",
            "interruption-level": n.critical ? (criticalSound ? "critical" : "time-sensitive") : "active",
            "relevance-score": n.critical ? 1.0 : 0.8,
        ]
        if n.critical && criticalSound {
            aps["sound"] = ["critical": 1, "name": "default", "volume": 1.0]
        } else {
            aps["sound"] = "default"
        }
        return json(["aps": aps, "kind": n.kind.rawValue])
    }

    static func test() -> Data {
        json(["aps": ["alert": ["title": "GlucOS test alert",
                                "body": "Sent by your GlucOS relay. Alerts will reach you even when the app is closed."],
                      "sound": "default", "thread-id": "glucos.alerts"]])
    }

    static func activityUpdate(_ state: GlucoseActivityState, now: Date) throws -> Data {
        try activity(event: "update", state: state, now: now)
    }

    static func activityStart(_ state: GlucoseActivityState, now: Date) throws -> Data {
        try activity(event: "start", state: state, now: now) { aps in
            aps["attributes-type"] = activityAttributesType
            aps["attributes"] = ["name": "GlucOS"]
            // Required to start an activity. No sound, so a restart in the night is silent.
            aps["alert"] = ["title": "GlucOS", "body": "Live glucose is on your Lock Screen."]
        }
    }

    static func activityEnd(_ state: GlucoseActivityState?, now: Date) throws -> Data {
        try activity(event: "end", state: state, now: now) { aps in
            aps["dismissal-date"] = Int(now.timeIntervalSince1970)
        }
    }

    private static func activity(event: String, state: GlucoseActivityState?, now: Date,
                                 extra: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var aps: [String: Any] = ["timestamp": Int(now.timeIntervalSince1970), "event": event]
        if let state {
            let encoded = try JSONEncoder().encode(state)
            aps["content-state"] = try JSONSerialization.jsonObject(with: encoded)
            aps["stale-date"] = Int(state.staleDate.timeIntervalSince1970)
            // Out of range sorts above other Live Activities.
            aps["relevance-score"] = state.range == .inRange ? 50 : 100
        }
        extra(&aps)
        return json(["aps": aps])
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

// MARK: - Auth token

/// The provider token APNs wants in every request. Apple refuses tokens older than an hour and
/// throttles ones refreshed more often than every 20 minutes, so it's reused for 50.
actor APNsTokenSigner {
    private let key: P256.Signing.PrivateKey
    private let keyID: String
    private let teamID: String
    private var cached: (token: String, issued: Date)?

    init(pem: String, keyID: String, teamID: String) throws {
        key = try P256.Signing.PrivateKey(pemRepresentation: pem)
        self.keyID = keyID
        self.teamID = teamID
    }

    func token(now: Date = Date(), forceRefresh: Bool = false) throws -> String {
        if !forceRefresh, let c = cached, now.timeIntervalSince(c.issued) < 50 * 60 { return c.token }
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID], options: [.sortedKeys])
        let claims = try JSONSerialization.data(withJSONObject: ["iss": teamID, "iat": Int(now.timeIntervalSince1970)],
                                                options: [.sortedKeys])
        let signingInput = "\(header.base64URL).\(claims.base64URL)"
        let signature = try key.signature(for: Data(signingInput.utf8))
        let token = "\(signingInput).\(signature.rawRepresentation.base64URL)"
        cached = (token, now)
        return token
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Sender

final class APNsSender: PushSending {
    private let http: HTTPClient
    private let signer: APNsTokenSigner

    init(signer: APNsTokenSigner, http: HTTPClient = .shared) {
        self.signer = signer
        self.http = http
    }

    func send(_ push: PushRequest) async -> PushResult {
        do {
            let first = try await attempt(push, forceRefresh: false)
            // A provider token can be refused as expired around a clock skew: refresh once.
            if case .failed(let reason) = first, reason.contains("ExpiredProviderToken") {
                return try await attempt(push, forceRefresh: true)
            }
            return first
        } catch {
            return .failed("\(error)")
        }
    }

    private func attempt(_ push: PushRequest, forceRefresh: Bool) async throws -> PushResult {
        let host = push.sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com"
        var req = HTTPClientRequest(url: "https://\(host)/3/device/\(push.deviceToken)")
        req.method = .POST
        req.headers.add(name: "authorization", value: "bearer \(try await signer.token(forceRefresh: forceRefresh))")
        req.headers.add(name: "apns-push-type", value: push.type.rawValue)
        req.headers.add(name: "apns-topic", value: push.type == .liveactivity ? "\(push.topic).push-type.liveactivity" : push.topic)
        req.headers.add(name: "apns-priority", value: String(push.priority))
        if let id = push.collapseID { req.headers.add(name: "apns-collapse-id", value: id) }
        if let exp = push.expiration { req.headers.add(name: "apns-expiration", value: String(Int(exp.timeIntervalSince1970))) }
        req.headers.add(name: "content-type", value: "application/json")
        req.body = .bytes(ByteBuffer(data: push.payload))

        let resp = try await http.execute(req, timeout: .seconds(20))
        let body = try await resp.body.collect(upTo: 64 * 1024)
        let status = Int(resp.status.code)
        if status == 200 { return .delivered }
        let reason = (try? JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any])?["reason"] as? String
            ?? "HTTP \(status)"
        if status == 410 || reason == "BadDeviceToken" || reason == "DeviceTokenNotForTopic" || reason == "Unregistered" {
            return .tokenInvalid(reason)
        }
        return .failed("\(status) \(reason)")
    }
}
