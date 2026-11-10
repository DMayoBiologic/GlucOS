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
    /// High (above target) alerts. Very high and every low alert stay on whenever alerts are on.
    @Published var alertOnHigh: Bool { didSet { d.set(alertOnHigh, forKey: "alertHigh") } }
    @Published var alertOnRapidChange: Bool { didSet { d.set(alertOnRapidChange, forKey: "alertRapid") } }
    @Published var alertOnStale: Bool { didSet { d.set(alertOnStale, forKey: "alertStale") } }
    @Published var alertOnSensorExpiry: Bool { didSet { d.set(alertOnSensorExpiry, forKey: "alertSensor") } }
    @Published var alertCooldownMinutes: Int { didSet { d.set(alertCooldownMinutes, forKey: "alertCooldown") } }
    @Published var sensorLifetimeDays: Int { didSet { d.set(sensorLifetimeDays, forKey: "sensorLifetimeDays") } }
    @Published var showDeltaInMenuBar: Bool { didSet { d.set(showDeltaInMenuBar, forKey: "showDelta") } }
    @Published var colorMenuBarIcon: Bool { didSet { d.set(colorMenuBarIcon, forKey: "colorMenuBarIcon") } }
    /// Hours of history in the popover chart (3, 6 or 12).
    @Published var chartHours: Int { didSet { d.set(chartHours, forKey: "chartHours") } }

    // Insulin & food logging
    @Published var therapy: TherapyType {
        didSet {
            d.set(therapy.rawValue, forKey: "therapy")
            // A pump only delivers rapid or ultra-rapid insulin.
            if therapy == .pump, !InsulinKind.pumpKinds.contains(bolusInsulinKind) { bolusInsulinKind = .rapid }
        }
    }
    /// Mealtime / correction insulin (pump users: the insulin in the pump).
    @Published var bolusInsulinKind: InsulinKind { didSet { d.set(bolusInsulinKind.rawValue, forKey: "bolusInsulinKind") } }
    @Published var bolusInsulinName: String { didSet { d.set(bolusInsulinName, forKey: "bolusInsulinName") } }
    /// Long-acting insulin (injections only).
    @Published var basalInsulinName: String { didSet { d.set(basalInsulinName, forKey: "basalInsulinName") } }

    /// First-run setup finished (or skipped). Existing installs with an account count as done.
    @Published var onboardingCompleted: Bool { didSet { d.set(onboardingCompleted, forKey: "onboardingCompleted") } }

    var password: String {
        get { Keychain.get("password") ?? "" }
        set {
            if newValue.isEmpty { Keychain.delete("password") } else { Keychain.set(newValue, for: "password") }
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
        alertOnHigh = d.object(forKey: "alertHigh") as? Bool ?? true
        alertOnRapidChange = d.object(forKey: "alertRapid") as? Bool ?? true
        alertOnStale = d.object(forKey: "alertStale") as? Bool ?? true
        alertOnSensorExpiry = d.object(forKey: "alertSensor") as? Bool ?? true
        alertCooldownMinutes = d.object(forKey: "alertCooldown") as? Int ?? 15
        sensorLifetimeDays = d.object(forKey: "sensorLifetimeDays") as? Int ?? 15   // Libre 2 Plus
        showDeltaInMenuBar = d.object(forKey: "showDelta") as? Bool ?? false
        colorMenuBarIcon = d.object(forKey: "colorMenuBarIcon") as? Bool ?? false
        let hours = d.object(forKey: "chartHours") as? Int ?? 12
        chartHours = [3, 6, 12].contains(hours) ? hours : 12
        therapy = TherapyType(rawValue: d.string(forKey: "therapy") ?? "") ?? .notSet
        bolusInsulinKind = InsulinKind(rawValue: d.string(forKey: "bolusInsulinKind") ?? "") ?? .rapid
        bolusInsulinName = d.string(forKey: "bolusInsulinName") ?? ""
        basalInsulinName = d.string(forKey: "basalInsulinName") ?? ""
        let savedEmail = d.string(forKey: "email") ?? ""
        onboardingCompleted = d.object(forKey: "onboardingCompleted") as? Bool ?? !savedEmail.isEmpty
    }

    /// Show the setup window at launch: never finished it and no account yet.
    var needsOnboarding: Bool { !onboardingCompleted && !hasCredentials }

    /// The name to pre-fill when logging a dose of `kind`.
    func defaultInsulinName(for kind: InsulinKind) -> String {
        if kind == bolusInsulinKind { return bolusInsulinName }
        if kind == .long { return basalInsulinName }
        return ""
    }
}
