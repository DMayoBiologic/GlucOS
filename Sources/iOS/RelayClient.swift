import Foundation

/// Where the push relay is and the secret it wants. The address comes from the build (the release
/// workflow bakes in the repo's RELAY_URL). The secret never does, because anyone with the public
/// TestFlight link can install the app: the owner's phone claims it from the relay by signing in
/// with the LibreLinkUp account the relay uses (`PhoneServices.claimRelayIfOwner`), or it's typed
/// in Settings. Either way it can be changed in Settings.
///
/// The app also copies its settings into the app group, so the Messages app (which can't read
/// the app's Keychain or defaults) makes share links with the same relay. The relay secret is in
/// the app bundle's Info.plist already, so the copy doesn't widen who can read it.
final class RelaySettings: ObservableObject {
    static let shared = RelaySettings()

    private let d = UserDefaults.standard
    private let group = SharedStore.defaults

    @Published var urlString: String {
        didSet {
            d.set(urlString, forKey: "relayURL")
            group.set(urlString, forKey: "relayURL")
        }
    }
    var secret: String {
        // Never built into the app: anyone with the TestFlight link can install it. The owner's
        // phone claims it from the relay (`RelayClient.claim`), or it's typed in Settings.
        get { Keychain.get("relaySecret") ?? group.string(forKey: "relaySecret") ?? "" }
        set {
            if newValue.isEmpty {
                Keychain.delete("relaySecret")
                group.removeObject(forKey: "relaySecret")
            } else {
                Keychain.set(newValue, for: "relaySecret")
                group.set(newValue, forKey: "relaySecret")
            }
            objectWillChange.send()
        }
    }

    private init() {
        urlString = d.string(forKey: "relayURL") ?? group.string(forKey: "relayURL") ?? Self.builtIn("GlucOSRelayURL") ?? ""
        // Settings changed before the Messages app existed: copy them over once.
        if let url = d.string(forKey: "relayURL"), group.string(forKey: "relayURL") == nil { group.set(url, forKey: "relayURL") }
        if let s = Keychain.get("relaySecret"), group.string(forKey: "relaySecret") == nil { group.set(s, forKey: "relaySecret") }
    }

    private static func builtIn(_ key: String) -> String? {
        guard let v = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !v.trimmingCharacters(in: .whitespaces).isEmpty, !v.hasPrefix("$(") else { return nil }
        return v
    }

    var url: URL? {
        let t = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let u = URL(string: t.hasPrefix("http") ? t : "https://\(t)"), u.host != nil else { return nil }
        return u
    }

    var isConfigured: Bool { url != nil && !secret.isEmpty }

    var client: RelayClient? {
        guard let url, !secret.isEmpty else { return nil }
        return RelayClient(baseURL: url, secret: secret)
    }
}

/// The relay's HTTPS API (see `RelayProtocol.swift`).
struct RelayClient {
    let baseURL: URL
    let secret: String

    enum RelayError: LocalizedError {
        case unauthorized
        case http(Int)
        case badResponse
        /// The relay's own explanation, e.g. too many share links.
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .unauthorized: return "The relay didn't accept the secret."
            case .http(let code): return "The relay returned HTTP \(code)."
            case .badResponse: return "The relay's reply wasn't understood."
            case .refused(let message): return message
            }
        }
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()

    enum ClaimResult {
        case secret(String)
        /// Signed in to a different LibreLinkUp account than the relay's: this isn't the owner's phone.
        case notOwner
        /// Try again later (too many tries, no account on the relay yet, offline).
        case unavailable
    }

    /// The relay's secret, for a phone signed in to the LibreLinkUp account the relay fetches with.
    static func claim(baseURL: URL, email: String, password: String) async -> ClaimResult {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/claim"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        guard let (data, resp) = try? await session.data(for: req) else { return .unavailable }
        switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200:
            let secret = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["secret"] as? String
            return secret.map { .secret($0) } ?? .unavailable
        case 403: return .notOwner
        default: return .unavailable
        }
    }

    func register(_ registration: RelayRegistration) async throws -> RelayStatus {
        try await call("v1/register", method: "POST", body: try JSONEncoder().encode(registration))
    }

    func status() async throws -> RelayStatus { try await call("v1/status", method: "GET") }

    func sendTest() async throws -> RelayStatus { try await call("v1/test", method: "POST") }

    func upload(_ readings: RelayReadings) async throws -> RelayStatus {
        try await call("v1/readings", method: "POST", body: try JSONEncoder().encode(readings))
    }

    // MARK: Sharing (ShareProtocol.swift)

    func shares() async throws -> [ShareInfo] { try await call("v1/shares", method: "GET") }

    func createShare(_ request: CreateShare) async throws -> CreatedShare {
        try await call("v1/shares", method: "POST", body: try JSONEncoder().encode(request))
    }

    func revokeShare(id: String) async throws -> [ShareInfo] {
        try await call("v1/shares/revoke", method: "POST", body: try JSONEncoder().encode(RevokeShare(id: id)))
    }

    private func call<T: Decodable>(_ path: String, method: String, body: Data? = nil) async throws -> T {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await Self.session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw RelayError.unauthorized }
        guard (200..<300).contains(code) else {
            if (400..<500).contains(code),
               let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String {
                throw RelayError.refused(message)
            }
            throw RelayError.http(code)
        }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw RelayError.badResponse }
        return value
    }
}
