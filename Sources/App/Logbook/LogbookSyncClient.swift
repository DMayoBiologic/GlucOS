import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where logbook sync lives: the GlucOS Supabase project. The publishable key is meant to ship in
/// apps; what each user can reach is decided by row-level security on the server.
enum LogbookSyncConfig {
    static let projectURL = URL(string: "https://aqlbadbyjuoruwnwyfrc.supabase.co")!
    static let publishableKey = "sb_publishable_nm2qjjnMZ1PXcJYQ1tT0pQ_25I_sX5m"
}

/// A signed-in Supabase session.
struct LogbookSyncSession: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    /// Unix seconds.
    var expiresAt: Double
    var userID: String
    /// The LibreLinkUp email it was made from, so a different account signs in again.
    var email: String

    func expiresSoon(now: Date = Date()) -> Bool { expiresAt - now.timeIntervalSince1970 < 120 }
}

/// Supabase over HTTPS: the `account` function to sign in, Auth to refresh, and the logbook
/// functions through the Data API.
struct LogbookSyncClient {
    var baseURL = LogbookSyncConfig.projectURL
    var apiKey = LogbookSyncConfig.publishableKey
    var session: URLSession = Self.defaultSession

    enum SyncError: LocalizedError, Equatable {
        /// LibreLinkUp refused the login (the message says why).
        case loginRejected(String)
        /// The session is no longer valid; sign in again.
        case sessionExpired
        case http(Int, String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .loginRejected(let m): return m
            case .sessionExpired: return "Signed out of sync."
            case .http(let code, let m): return m.isEmpty ? "The sync server returned HTTP \(code)." : m
            case .badResponse: return "The sync server's reply wasn't understood."
            }
        }
    }

    static let defaultSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg)
    }()

    /// Signs in with the LibreLinkUp login. The server checks it with LibreLinkUp once and
    /// doesn't keep the password.
    func signIn(email: String, password: String, region: String, clientVersion: String) async throws -> LogbookSyncSession {
        struct Body: Encodable { let email, password, region, clientVersion: String }
        struct Reply: Decodable { let access_token, refresh_token: String; let expires_at: Double; let user_id: String }
        let (data, code) = try await send(path: "functions/v1/account/v1/session",
                                          body: Body(email: email, password: password, region: region, clientVersion: clientVersion))
        if code == 401 { throw SyncError.loginRejected(Self.message(data) ?? "LibreLinkUp didn't accept the login.") }
        guard code == 200 else { throw SyncError.http(code, Self.message(data) ?? "") }
        guard let r = try? JSONDecoder().decode(Reply.self, from: data) else { throw SyncError.badResponse }
        return LogbookSyncSession(accessToken: r.access_token, refreshToken: r.refresh_token,
                                  expiresAt: r.expires_at, userID: r.user_id, email: email)
    }

    func refresh(_ s: LogbookSyncSession) async throws -> LogbookSyncSession {
        struct Body: Encodable { let refresh_token: String }
        struct User: Decodable { let id: String }
        struct Reply: Decodable { let access_token, refresh_token: String; let expires_at: Double?; let expires_in: Double?; let user: User }
        let (data, code) = try await send(path: "auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
                                          body: Body(refresh_token: s.refreshToken))
        // 400: the refresh token was revoked, used up or the user is gone.
        if code == 400 || code == 401 || code == 403 { throw SyncError.sessionExpired }
        guard code == 200 else { throw SyncError.http(code, Self.message(data) ?? "") }
        guard let r = try? JSONDecoder().decode(Reply.self, from: data) else { throw SyncError.badResponse }
        var out = s
        out.accessToken = r.access_token
        out.refreshToken = r.refresh_token
        out.expiresAt = r.expires_at ?? (Date().timeIntervalSince1970 + (r.expires_in ?? 3600))
        out.userID = r.user.id
        return out
    }

    /// Entries changed after `since`, oldest change first.
    func pull(since: Int64, limit: Int = 500, session s: LogbookSyncSession) async throws -> [LogbookRecord] {
        struct Body: Encodable { let since: Int64; let max_rows: Int }
        let (data, code) = try await send(path: "rest/v1/rpc/logbook_pull", body: Body(since: since, max_rows: limit), token: s.accessToken)
        try Self.check(code, data)
        guard let rows = try? JSONDecoder().decode([LogbookRecord].self, from: data) else { throw SyncError.badResponse }
        return rows
    }

    /// Uploads changes; the server keeps whichever edit of each entry is newer.
    func push(_ records: [LogbookRecord], session s: LogbookSyncSession) async throws {
        struct Body: Encodable { let entries: [LogbookRecord] }
        let (data, code) = try await send(path: "rest/v1/rpc/logbook_push", body: Body(entries: records), token: s.accessToken)
        try Self.check(code, data)
    }

    /// Sends scored forecasts, so accuracy can be followed across devices and over time. The
    /// server keeps one row per forecast; sending one again replaces it.
    func pushForecasts(_ records: [ForecastRecord], session s: LogbookSyncSession) async throws {
        struct Body: Encodable { let entries: [ForecastUpload] }
        let (data, code) = try await send(path: "rest/v1/rpc/forecast_push", body: Body(entries: records.map(ForecastUpload.init)),
                                          token: s.accessToken)
        try Self.check(code, data)
    }

    // MARK: HTTP

    private static func check(_ code: Int, _ data: Data) throws {
        if code == 401 || (code == 403 && (message(data) ?? "").localizedCaseInsensitiveContains("jwt")) {
            throw SyncError.sessionExpired
        }
        guard (200..<300).contains(code) else { throw SyncError.http(code, message(data) ?? "") }
    }

    private static func message(_ data: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (o["error"] ?? o["message"] ?? o["msg"] ?? o["error_description"]) as? String
    }

    private func send<B: Encodable>(path: String, query: [URLQueryItem] = [], body: B, token: String? = nil) async throws -> (Data, Int) {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(apiKey, forHTTPHeaderField: "apikey")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await session.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// A scored forecast as `forecast_push` takes it: Unix seconds, mg/dL, snake_case keys.
struct ForecastUpload: Encodable, Equatable {
    struct Point: Encodable, Equatable {
        let minutes: Int
        let mgdl: Double
        let lower: Double
        let upper: Double
        let actual: Double?
        let after_log: Bool
    }
    let id: UUID
    let issued: Double
    let device: String
    let basis: String
    let start_mgdl: Double
    let trend: Double
    let points: [Point]
    let limitations: [String]
    let calibrated: Bool
    let tuned: Bool
    let morning: Bool

    init(_ r: ForecastRecord) {
        id = r.id
        issued = r.issuedAt.timeIntervalSince1970
        device = r.device
        basis = r.basis.rawValue
        start_mgdl = r.startMgdl
        trend = r.trendPerMinute
        points = r.points.map { Point(minutes: $0.minutes, mgdl: $0.mgdl, lower: $0.lower, upper: $0.upper,
                                      actual: $0.actual, after_log: $0.afterLog) }
        limitations = r.limitations
        calibrated = r.calibrated
        tuned = r.tuned
        morning = r.morning
    }
}
