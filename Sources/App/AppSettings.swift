import Foundation
import Combine

/// User settings. Non-secret values live in UserDefaults; the LibreLinkUp password in the Keychain.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let d = UserDefaults.standard

    @Published var email: String { didSet { d.set(email, forKey: "email") } }
    @Published var region: String { didSet { d.set(region, forKey: "region") } }
    @Published var clientVersion: String { didSet { d.set(clientVersion, forKey: "clientVersion") } }
    @Published var unit: GlucoseUnit { didSet { d.set(unit.rawValue, forKey: "unit") } }
    @Published var lowMgdl: Double { didSet { d.set(lowMgdl, forKey: "lowMgdl") } }
    @Published var highMgdl: Double { didSet { d.set(highMgdl, forKey: "highMgdl") } }
    @Published var pollIntervalSeconds: Int { didSet { d.set(pollIntervalSeconds, forKey: "pollInterval") } }
    @Published var alertsEnabled: Bool { didSet { d.set(alertsEnabled, forKey: "alertsEnabled") } }
    @Published var alertOnRapidChange: Bool { didSet { d.set(alertOnRapidChange, forKey: "alertRapid") } }
    @Published var alertOnStale: Bool { didSet { d.set(alertOnStale, forKey: "alertStale") } }
    @Published var alertOnSensorExpiry: Bool { didSet { d.set(alertOnSensorExpiry, forKey: "alertSensor") } }
    @Published var alertCooldownMinutes: Int { didSet { d.set(alertCooldownMinutes, forKey: "alertCooldown") } }
    @Published var sensorLifetimeDays: Int { didSet { d.set(sensorLifetimeDays, forKey: "sensorLifetimeDays") } }
    @Published var showDeltaInMenuBar: Bool { didSet { d.set(showDeltaInMenuBar, forKey: "showDelta") } }

    /// Cached after the first read: `hasCredentials` is evaluated on every poll and view render,
    /// and each Keychain hit can raise an access prompt for an ad-hoc-signed build.
    private var cachedPassword: String?

    var password: String {
        get {
            if let cachedPassword { return cachedPassword }
            let value = Keychain.get("password") ?? ""
            cachedPassword = value
            return value
        }
        set {
            guard newValue != cachedPassword else { return }
            if newValue.isEmpty { Keychain.delete("password") } else { Keychain.set(newValue, for: "password") }
            cachedPassword = newValue
            objectWillChange.send()
        }
    }

    var hasCredentials: Bool { !email.isEmpty && !password.isEmpty }

    private init() {
        email = d.string(forKey: "email") ?? ""
        region = d.string(forKey: "region") ?? "au"
        clientVersion = d.string(forKey: "clientVersion") ?? "4.16.0"
        unit = GlucoseUnit(rawValue: d.string(forKey: "unit") ?? "") ?? .mmol
        lowMgdl = d.object(forKey: "lowMgdl") as? Double ?? 70
        highMgdl = d.object(forKey: "highMgdl") as? Double ?? 180
        pollIntervalSeconds = d.object(forKey: "pollInterval") as? Int ?? 60
        alertsEnabled = d.object(forKey: "alertsEnabled") as? Bool ?? true
        alertOnRapidChange = d.object(forKey: "alertRapid") as? Bool ?? true
        alertOnStale = d.object(forKey: "alertStale") as? Bool ?? true
        alertOnSensorExpiry = d.object(forKey: "alertSensor") as? Bool ?? true
        alertCooldownMinutes = d.object(forKey: "alertCooldown") as? Int ?? 15
        sensorLifetimeDays = d.object(forKey: "sensorLifetimeDays") as? Int ?? 15   // Libre 2 Plus
        showDeltaInMenuBar = d.object(forKey: "showDelta") as? Bool ?? false
    }
}
