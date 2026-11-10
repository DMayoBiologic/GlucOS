import Foundation

/// Settings from the environment. Everything the phone can tell the relay (account, units,
/// thresholds, alert switches, push tokens) comes from the phone instead, so this is only what
/// the relay needs before any phone has registered.
public struct RelayConfig: Sendable {
    /// Shared secret the app sends as `Authorization: Bearer …`. Required.
    public var secret: String
    /// APNs auth key (.p8 contents, PEM), its key id and the Apple Developer team id.
    public var apnsKeyPEM: String?
    public var apnsKeyID: String?
    public var teamID: String?
    /// The iPhone app's bundle id: the topic for alert pushes, and with
    /// `.push-type.liveactivity` for Live Activity pushes.
    public var bundleID: String
    /// Where state (registration, tokens, recent readings) is kept.
    public var dataDirectory: URL
    public var port: Int
    /// How often to fetch from LibreLinkUp, seconds.
    public var pollInterval: TimeInterval
    /// Send urgent lows with the critical-alert sound. Only once Apple has granted the app the
    /// Critical Alerts entitlement; otherwise they go out as time-sensitive alerts.
    public var criticalAlerts: Bool

    public var canPush: Bool { apnsKeyPEM != nil && apnsKeyID != nil && teamID != nil }

    public init(secret: String, apnsKeyPEM: String? = nil, apnsKeyID: String? = nil, teamID: String? = nil,
                bundleID: String = "au.com.declanmayo.glucos.ios", dataDirectory: URL,
                port: Int = 8080, pollInterval: TimeInterval = 60, criticalAlerts: Bool = false) {
        self.secret = secret
        self.apnsKeyPEM = apnsKeyPEM
        self.apnsKeyID = apnsKeyID
        self.teamID = teamID
        self.bundleID = bundleID
        self.dataDirectory = dataDirectory
        self.port = port
        self.pollInterval = pollInterval
        self.criticalAlerts = criticalAlerts
    }

    public enum ConfigError: Error, CustomStringConvertible {
        case missing(String)
        public var description: String {
            switch self {
            case .missing(let name): return "\(name) is not set. See docs/iOS.md."
            }
        }
    }

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) throws -> RelayConfig {
        func value(_ k: String) -> String? {
            guard let v = env[k]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return v
        }
        guard let secret = value("RELAY_SECRET") else { throw ConfigError.missing("RELAY_SECRET") }
        // Hosts that store secrets on one line often turn the PEM's newlines into "\n".
        let pem = value("APNS_KEY_P8")?.replacingOccurrences(of: "\\n", with: "\n")
        return RelayConfig(
            secret: secret,
            apnsKeyPEM: pem,
            apnsKeyID: value("APNS_KEY_ID"),
            teamID: value("APPLE_TEAM_ID"),
            bundleID: value("APNS_BUNDLE_ID") ?? "au.com.declanmayo.glucos.ios",
            dataDirectory: URL(fileURLWithPath: value("DATA_DIR") ?? "/data", isDirectory: true),
            port: value("PORT").flatMap(Int.init) ?? 8080,
            pollInterval: max(30, value("POLL_SECONDS").flatMap(Double.init) ?? 60),
            criticalAlerts: value("APNS_CRITICAL_ALERTS") == "true")
    }
}
