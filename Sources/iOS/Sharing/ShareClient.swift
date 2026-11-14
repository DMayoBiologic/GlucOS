import Foundation

/// The public `share` function (supabase/functions/share), as a follower uses it. The share
/// token from the link is the only credential.
struct ShareClient {
    static let baseURL = FollowLink.serviceURL

    let token: String

    enum ShareError: LocalizedError {
        /// Revoked, expired, or never existed.
        case ended
        case refused(String)
        case http(Int)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .ended: return "This share has ended, or the link isn't right."
            case .refused(let m): return m
            case .http(let code): return "The GlucOS server returned HTTP \(code)."
            case .badResponse: return "The GlucOS server's reply wasn't understood."
            }
        }
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()

    /// With `installation`, the snapshot also carries this phone's latest check-in.
    func snapshot(installation: String? = nil) async throws -> ShareSnapshot {
        try await call("v1/snapshot", method: "GET", query: installation.map { [URLQueryItem(name: "installation", value: $0)] })
    }

    /// Asks the person this share belongs to whether they're okay.
    func checkIn(_ request: CheckInRequest) async throws -> CheckInState {
        try await call("v1/checkin", method: "POST", body: try JSONEncoder().encode(request))
    }

    func follow(_ r: FollowRegistration) async throws -> FollowStatus {
        try await call("v1/follow", method: "POST", body: try JSONEncoder().encode(r))
    }

    func unfollow(installation: String) async throws {
        struct OK: Decodable { var ok: Bool }
        let _: OK = try await call("v1/unfollow", method: "POST",
                                   body: try JSONEncoder().encode(FollowRegistration(installation: installation)))
    }

    private func call<T: Decodable>(_ path: String, method: String, body: Data? = nil,
                                    query: [URLQueryItem]? = nil) async throws -> T {
        var url = Self.baseURL.appendingPathComponent(path)
        if let query { url.append(queryItems: query) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await Self.session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { throw ShareError.ended }
        guard (200..<300).contains(code) else {
            if (400..<500).contains(code),
               let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String {
                throw ShareError.refused(message)
            }
            throw ShareError.http(code)
        }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw ShareError.badResponse }
        return value
    }
}
