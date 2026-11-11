import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto // swift-crypto, for the push relay on Linux
#endif

/// Minimal client for Abbott's (unofficial) LibreLinkUp follower API.
///
/// Flow: login at the global endpoint → follow region redirect if given →
/// GET /llu/connections for the current reading → GET /llu/connections/{patientId}/graph
/// for ~12 h of history. All authenticated calls need `Authorization: Bearer` and
/// `Account-Id: sha256(userId)` (required since client version 4.16.0, Oct 2025).
actor LibreLinkUpClient {

    struct Credentials: Equatable {
        var email: String
        var password: String
    }

    struct Result {
        var current: GlucoseReading?
        var history: [GlucoseReading]
        var sensor: SensorInfo?
        var targetLowMgdl: Double?
        var targetHighMgdl: Double?
    }

    enum ClientError: LocalizedError {
        case notConfigured
        case badCredentials
        case termsAcceptanceRequired
        case versionTooOld(minimum: String)
        case noConnections
        case http(Int, String)
        case decoding(String)
        case unexpectedStatus(Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "LibreLinkUp credentials not set."
            case .badCredentials: return "LibreLinkUp rejected the email/password."
            case .termsAcceptanceRequired: return "Open the LibreLinkUp app on your phone and accept the updated terms, then retry."
            case .versionTooOld(let m): return "Abbott now requires client version \(m)+. Update the version in Settings."
            case .noConnections: return "This LibreLinkUp account isn't following anyone. Accept the invitation in the LibreLinkUp app."
            case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
            case .decoding(let what): return "Unexpected response (\(what)). The API may have changed."
            case .unexpectedStatus(let s): return "LibreLinkUp returned status \(s)."
            }
        }
    }

    // MARK: Config

    private let globalBase = URL(string: "https://api.libreview.io")!
    private var base: URL
    private var clientVersion: String
    private var sensorLifetimeDays: Int

    // MARK: Session state

    private var token: String?
    private var tokenExpiry: Date?
    private var accountID: String?
    private var patientID: String?
    /// Which account the cached session belongs to, so a login that finished after the account
    /// changed is never reused for another one.
    private var sessionCredentials: Credentials?

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        #if !os(Linux)
        cfg.waitsForConnectivity = false
        #endif
        return URLSession(configuration: cfg)
    }()

    init(region: String?, clientVersion: String, sensorLifetimeDays: Int) {
        self.base = Self.baseURL(forRegion: region)
        self.clientVersion = clientVersion
        self.sensorLifetimeDays = sensorLifetimeDays
    }

    func configure(region: String?, clientVersion: String, sensorLifetimeDays: Int) {
        let newBase = Self.baseURL(forRegion: region)
        if newBase != base || clientVersion != self.clientVersion {
            invalidateSession()
        }
        base = newBase
        self.clientVersion = clientVersion
        self.sensorLifetimeDays = sensorLifetimeDays
    }

    func invalidateSession() {
        token = nil
        tokenExpiry = nil
        accountID = nil
        patientID = nil
        sessionCredentials = nil
    }

    var currentRegionHost: String { base.host ?? "" }

    private static func baseURL(forRegion region: String?) -> URL {
        guard let r = region?.trimmingCharacters(in: .whitespaces).lowercased(), !r.isEmpty, r != "global" else {
            return URL(string: "https://api.libreview.io")!
        }
        return URL(string: "https://api-\(r).libreview.io")!
    }

    // MARK: Public

    func fetch(credentials: Credentials) async throws -> Result {
        if sessionCredentials != credentials { invalidateSession() }
        if token == nil || (tokenExpiry.map { $0 < Date().addingTimeInterval(300) } ?? true) {
            try await login(credentials)
        }
        do {
            return try await fetchData()
        } catch ClientError.http(let code, _) where code == 401 || code == 403 {
            // Token revoked or expired early: re-login once.
            invalidateSession()
            try await login(credentials)
            return try await fetchData()
        }
    }

    // MARK: Login

    private func login(_ creds: Credentials, followingRedirect: Bool = false) async throws {
        var req = URLRequest(url: base.appendingPathComponent("llu/auth/login"))
        req.httpMethod = "POST"
        applyCommonHeaders(&req)
        req.httpBody = try JSONSerialization.data(withJSONObject: ["email": creds.email, "password": creds.password])

        let (data, code) = try await perform(req)
        let json = try parseJSON(data, context: "login")
        try checkForVersionError(json)
        guard code == 200 else { throw ClientError.http(code, String(decoding: data, as: UTF8.self)) }

        let status = json["status"] as? Int ?? -1
        let payload = json["data"] as? [String: Any] ?? [:]

        if status == 2 { throw ClientError.badCredentials }
        if status == 4 { throw ClientError.termsAcceptanceRequired }
        guard status == 0 else { throw ClientError.unexpectedStatus(status) }

        // Region redirect: {"data":{"redirect":true,"region":"au"}}
        if payload["redirect"] as? Bool == true, let region = payload["region"] as? String {
            guard !followingRedirect else { throw ClientError.decoding("redirect loop") }
            base = Self.baseURL(forRegion: region)
            try await login(creds, followingRedirect: true)
            return
        }

        guard
            let ticket = payload["authTicket"] as? [String: Any],
            let tok = ticket["token"] as? String,
            let user = payload["user"] as? [String: Any],
            let userID = user["id"] as? String
        else { throw ClientError.decoding("missing authTicket/user") }

        token = tok
        if let exp = ticket["expires"] as? Double {
            tokenExpiry = Date(timeIntervalSince1970: exp)
        } else {
            tokenExpiry = Date().addingTimeInterval(6 * 3600)
        }
        sessionCredentials = creds
        accountID = SHA256.hash(data: Data(userID.utf8)).map { String(format: "%02x", $0) }.joined()
        patientID = nil
    }

    // MARK: Data

    private func fetchData() async throws -> Result {
        // 1. Connections → patientId, current measurement, targets, sensor.
        let connJSON = try await getJSON(path: "llu/connections", context: "connections")
        guard let connections = connJSON["data"] as? [[String: Any]], let first = connections.first else {
            throw ClientError.noConnections
        }
        guard let pid = first["patientId"] as? String else { throw ClientError.decoding("patientId") }
        patientID = pid

        var result = Result(history: [])
        result.current = Self.reading(from: first["glucoseMeasurement"] as? [String: Any])
        result.targetLowMgdl = (first["targetLow"] as? NSNumber)?.doubleValue
        result.targetHighMgdl = (first["targetHigh"] as? NSNumber)?.doubleValue
        result.sensor = sensorInfo(from: first["sensor"] as? [String: Any])

        // 2. Graph → ~12 h of readings.
        let graphJSON = try await getJSON(path: "llu/connections/\(pid)/graph", context: "graph")
        let graphData = graphJSON["data"] as? [String: Any] ?? [:]
        let points = (graphData["graphData"] as? [[String: Any]] ?? [])
            .compactMap { Self.reading(from: $0) }
            .sorted { $0.timestamp < $1.timestamp }
        result.history = points

        if result.current == nil,
           let conn = graphData["connection"] as? [String: Any] {
            result.current = Self.reading(from: conn["glucoseMeasurement"] as? [String: Any])
        }
        if result.sensor == nil,
           let active = (graphData["activeSensors"] as? [[String: Any]])?.first,
           let s = active["sensor"] as? [String: Any] {
            result.sensor = sensorInfo(from: s)
        }
        return result
    }

    // MARK: Parsing

    private static let factoryFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "M/d/yyyy h:mm:ss a"
        return f
    }()

    private static func reading(from dict: [String: Any]?) -> GlucoseReading? {
        guard let dict,
              let mgdl = (dict["ValueInMgPerDl"] as? NSNumber)?.doubleValue,
              let ts = dict["FactoryTimestamp"] as? String,
              let date = factoryFormatter.date(from: ts)
        else { return nil }
        let trend = Trend(rawValue: (dict["TrendArrow"] as? NSNumber)?.intValue ?? 0) ?? .unknown
        return GlucoseReading(timestamp: date, mgdl: mgdl, trend: trend)
    }

    private func sensorInfo(from dict: [String: Any]?) -> SensorInfo? {
        guard let dict, let a = (dict["a"] as? NSNumber)?.doubleValue else { return nil }
        let serial = dict["sn"] as? String ?? "?"
        return SensorInfo(serial: serial, activated: Date(timeIntervalSince1970: a), lifetimeDays: sensorLifetimeDays)
    }

    // MARK: HTTP plumbing

    private func applyCommonHeaders(_ req: inout URLRequest) {
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.setValue("llu.ios", forHTTPHeaderField: "product")
        req.setValue(clientVersion, forHTTPHeaderField: "version")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) LibreLinkUp/\(clientVersion)",
                     forHTTPHeaderField: "User-Agent")
    }

    private func getJSON(path: String, context: String) async throws -> [String: Any] {
        guard let token, let accountID else { throw ClientError.notConfigured }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "GET"
        applyCommonHeaders(&req)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(accountID, forHTTPHeaderField: "Account-Id")

        let (data, code) = try await perform(req)
        let json = try parseJSON(data, context: context)
        try checkForVersionError(json)
        guard code == 200 else { throw ClientError.http(code, String(decoding: data, as: UTF8.self)) }
        let status = json["status"] as? Int ?? 0
        guard status == 0 else { throw ClientError.unexpectedStatus(status) }
        return json
    }

    private func perform(_ req: URLRequest) async throws -> (Data, Int) {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (data, code)
    }

    private func parseJSON(_ data: Data, context: String) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data), let dict = obj as? [String: Any] else {
            throw ClientError.decoding(context)
        }
        return dict
    }

    private func checkForVersionError(_ json: [String: Any]) throws {
        if let data = json["data"] as? [String: Any], let min = data["minimumVersion"] as? String {
            throw ClientError.versionTooOld(minimum: min)
        }
        if let msg = json["message"] as? String, msg == "RequiredHeaderMissing" {
            throw ClientError.decoding("required header missing — client version too old")
        }
    }
}
