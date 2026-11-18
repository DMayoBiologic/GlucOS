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
    /// Heads-up when the forecast says glucose will go low (or urgent low) soon.
    @Published var alertOnPredictedLow: Bool { didSet { d.set(alertOnPredictedLow, forKey: "alertPredictedLow") } }
    /// Heads-up when the forecast says glucose will go high (or very high) soon. Predicted highs
    /// above target also need `alertOnHigh`.
    @Published var alertOnPredictedHigh: Bool { didSet { d.set(alertOnPredictedHigh, forKey: "alertPredictedHigh") } }
    /// How far ahead a predicted low may be to alert, in minutes.
    @Published var predictiveAlertMinutes: Int { didSet { d.set(predictiveAlertMinutes, forKey: "predictiveAlertMinutes") } }
    /// Draw the forecast on charts.
    @Published var showForecast: Bool { didSet { d.set(showForecast, forKey: "showForecast") } }
    @Published var alertCooldownMinutes: Int { didSet { d.set(alertCooldownMinutes, forKey: "alertCooldown") } }
    /// The sound glucose alerts play (docs/AlertSounds.md). Sent to the push relay too.
    @Published var alertSound: AlertSound { didSet { d.set(alertSound.rawValue, forKey: "alertSound") } }
    @Published var sensorLifetimeDays: Int { didSet { d.set(sensorLifetimeDays, forKey: "sensorLifetimeDays") } }
    @Published var showDeltaInMenuBar: Bool { didSet { d.set(showDeltaInMenuBar, forKey: "showDelta") } }
    /// The menu bar reading in its range colour. On unless turned off (urgent lows are always coloured).
    @Published var colorMenuBarIcon: Bool { didSet { d.set(colorMenuBarIcon, forKey: "colorMenuBarIcon") } }
    /// A tiny sparkline of the last hour after the menu bar reading.
    @Published var showMenuBarSparkline: Bool { didSet { d.set(showMenuBarSparkline, forKey: "menuBarSparkline") } }
    /// Resting the pointer on the menu bar reading shows the last two hours in a small panel
    /// (`MenuBarHoverPreview`). On unless turned off; the plain tooltip comes back when off.
    @Published var showMenuBarHoverPreview: Bool { didSet { d.set(showMenuBarHoverPreview, forKey: "menuBarHoverPreview") } }
    /// Yesterday's readings as a faint line behind today's on the iPhone Today chart and the Mac
    /// popover and Outlook charts (`YesterdayLine`). Off unless turned on, here or from the chart's
    /// long-press / right-click menu.
    @Published var showYesterdayLine: Bool { didSet { d.set(showYesterdayLine, forKey: "showYesterdayLine") } }
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

    /// Open the log window from any app with `globalLogShortcut` (Settings → Logging). Off until
    /// the user turns it on: a system-wide shortcut takes that key combination from every app.
    @Published var globalLogShortcutEnabled: Bool { didSet { d.set(globalLogShortcutEnabled, forKey: "globalLogShortcutEnabled") } }
    @Published var globalLogShortcut: LogHotKey {
        didSet { d.set(try? JSONEncoder().encode(globalLogShortcut), forKey: "globalLogShortcut") }
    }
    /// The "open from anywhere" shortcut while it's on, for the ⌘? lists.
    var activeGlobalLogShortcut: LogHotKey? { globalLogShortcutEnabled ? globalLogShortcut : nil }

    /// The evening recap notification (docs/EveningRecap.md). Off until turned on in Settings.
    @Published var eveningRecapEnabled: Bool { didSet { d.set(eveningRecapEnabled, forKey: "eveningRecapEnabled") } }
    /// When it goes out, in minutes after local midnight. 9 pm unless changed.
    @Published var eveningRecapMinute: Int { didSet { d.set(eveningRecapMinute, forKey: "eveningRecapMinute") } }

    /// A reminder at 7 pm the evening before the sensor ends (docs/SensorEnd.md). Off until turned on.
    @Published var sensorEndReminderEnabled: Bool { didSet { d.set(sensorEndReminderEnabled, forKey: "sensorEndReminderEnabled") } }

    /// Logs "Sensor started" in the Logbook when GlucOS first sees a new sensor
    /// (docs/SensorStartLog.md). On until turned off.
    @Published var logSensorStarts: Bool { didSet { d.set(logSensorStarts, forKey: "logSensorStarts") } }

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
        alertOnPredictedLow = d.object(forKey: "alertPredictedLow") as? Bool ?? true
        alertOnPredictedHigh = d.object(forKey: "alertPredictedHigh") as? Bool ?? true
        let lead = d.object(forKey: "predictiveAlertMinutes") as? Int ?? 30
        predictiveAlertMinutes = [10, 15, 20, 30].contains(lead) ? lead : 30
        showForecast = d.object(forKey: "showForecast") as? Bool ?? true
        alertCooldownMinutes = d.object(forKey: "alertCooldown") as? Int ?? 15
        alertSound = AlertSound(stored: d.string(forKey: "alertSound"))
        sensorLifetimeDays = d.object(forKey: "sensorLifetimeDays") as? Int ?? 15   // Libre 2 Plus
        showDeltaInMenuBar = d.object(forKey: "showDelta") as? Bool ?? false
        colorMenuBarIcon = d.object(forKey: "colorMenuBarIcon") as? Bool ?? true
        showMenuBarSparkline = d.object(forKey: "menuBarSparkline") as? Bool ?? false
        showMenuBarHoverPreview = d.object(forKey: "menuBarHoverPreview") as? Bool ?? true
        chartHours = ChartHours.sanitized(d.object(forKey: "chartHours") as? Int)
        showYesterdayLine = d.bool(forKey: "showYesterdayLine")
        therapy = TherapyType(rawValue: d.string(forKey: "therapy") ?? "") ?? .notSet
        bolusInsulinKind = InsulinKind(rawValue: d.string(forKey: "bolusInsulinKind") ?? "") ?? .rapid
        bolusInsulinName = d.string(forKey: "bolusInsulinName") ?? ""
        basalInsulinName = d.string(forKey: "basalInsulinName") ?? ""
        globalLogShortcutEnabled = d.bool(forKey: "globalLogShortcutEnabled")
        globalLogShortcut = d.data(forKey: "globalLogShortcut")
            .flatMap { try? JSONDecoder().decode(LogHotKey.self, from: $0) } ?? .suggested
        eveningRecapEnabled = d.bool(forKey: "eveningRecapEnabled")
        eveningRecapMinute = EveningRecap.sanitized(d.object(forKey: "eveningRecapMinute") as? Int)
        sensorEndReminderEnabled = d.bool(forKey: "sensorEndReminderEnabled")
        logSensorStarts = d.object(forKey: "logSensorStarts") as? Bool ?? true
        let savedEmail = d.string(forKey: "email") ?? ""
        onboardingCompleted = d.object(forKey: "onboardingCompleted") as? Bool ?? !savedEmail.isEmpty
    }

    /// The alert switches, for `AlertPlanner` (and the push relay, which runs the same rules).
    var alertPreferences: AlertPreferences {
        AlertPreferences(enabled: alertsEnabled, high: alertOnHigh, rapidChange: alertOnRapidChange,
                         stale: alertOnStale, sensorExpiry: alertOnSensorExpiry,
                         predictedLow: alertOnPredictedLow, predictedHigh: alertOnPredictedHigh,
                         predictiveMinutes: predictiveAlertMinutes, cooldownMinutes: alertCooldownMinutes)
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
