import Foundation

/// Where the push relay is and the secret it wants. Defaults come from the build (the release
/// workflow bakes in the repo's RELAY_URL and RELAY_SECRET), and can be changed in Settings.
final class RelaySettings: ObservableObject {
    static let shared = RelaySettings()

    private let d = UserDefaults.standard

    @Published var urlString: String { didSet { d.set(urlString, forKey: "relayURL") } }
    var secret: String {
        get { Keychain.get("relaySecret") ?? Self.builtIn("GlucOSRelaySecret") ?? "" }
        set {
            if newValue.isEmpty { Keychain.delete("relaySecret") } else { Keychain.set(newValue, for: "relaySecret") }
            objectWillChange.send()
        }
    }

    private init() {
        urlString = d.string(forKey: "relayURL") ?? Self.builtIn("GlucOSRelayURL") ?? ""
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

        var errorDescription: String? {
            switch self {
            case .unauthorized: return "The relay didn't accept the secret."
            case .http(let code): return "The relay returned HTTP \(code)."
            case .badResponse: return "The relay's reply wasn't understood."
            }
        }
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()

    func register(_ registration: RelayRegistration) async throws -> RelayStatus {
        try await call("v1/register", method: "POST", body: try JSONEncoder().encode(registration))
    }

    func status() async throws -> RelayStatus { try await call("v1/status", method: "GET") }

    func sendTest() async throws -> RelayStatus { try await call("v1/test", method: "POST") }

    private func call(_ path: String, method: String, body: Data? = nil) async throws -> RelayStatus {
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
        guard code == 200 else { throw RelayError.http(code) }
        guard let status = try? JSONDecoder().decode(RelayStatus.self, from: data) else { throw RelayError.badResponse }
        return status
    }
}
