import Foundation
import UserNotifications

/// Supplementary alerts via macOS notifications. The phone app's alarms remain the primary ones.
@MainActor
final class AlertManager {
    enum Kind: String, CaseIterable {
        case urgentLow, low, high, veryHigh, rapidChange, stale, sensorExpiring, apiBroken
        case predictedUrgentLow, predictedLow, predictedHigh, predictedVeryHigh
    }

    private static func kind(for e: PredictedExcursion) -> Kind {
        switch e {
        case .urgentLow: return .predictedUrgentLow
        case .low: return .predictedLow
        case .high: return .predictedHigh
        case .veryHigh: return .predictedVeryHigh
        }
    }

    private var lastFired: [Kind: Date] = [:]
    private var authorized = false

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] ok, _ in
            Task { @MainActor in self?.authorized = ok }
        }
    }

    /// Whether macOS will actually show GlucOS notifications. `nil` while the user hasn't been
    /// asked yet (or the first-launch prompt is still open), so that isn't reported as "blocked".
    static func notificationsAllowed() async -> Bool? {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return settings.alertSetting != .disabled
        case .notDetermined: return nil
        default: return false
        }
    }

    /// System Settings → Notifications → GlucOS.
    static let notificationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=au.com.declanmayo.glucos")!

    /// A harmless sample alert so you can check banners and sound are working.
    func sendTest() {
        let content = UNMutableNotificationContent()
        content.title = "GlucOS test alert"
        content.body = "If you can see and hear this, glucose alerts will reach you."
        content.sound = .default
        let req = UNNotificationRequest(identifier: "glucos.test", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    func evaluate(_ s: GlucoseSnapshot, settings: AppSettings, now: Date = Date()) {
        guard settings.alertsEnabled else { return }
        let unit = s.unit
        let cooldown = TimeInterval(settings.alertCooldownMinutes * 60)

        if let r = s.current, !s.isStale(at: now) {
            let v = unit.format(mgdl: r.mgdl, withUnit: true)
            switch GlucoseRange.classify(mgdl: r.mgdl, low: s.lowMgdl, high: s.highMgdl) {
            case .urgentLow:
                fire(.urgentLow, title: "URGENT LOW — \(v)", body: "\(r.trend.description). Treat now and confirm on your phone.", cooldown: 5 * 60, critical: true, now: now)
            case .low:
                fire(.low, title: "Low glucose — \(v)", body: r.trend.description, cooldown: cooldown, now: now)
            case .veryHigh:
                fire(.veryHigh, title: "Very high glucose — \(v)", body: r.trend.description, cooldown: cooldown, now: now)
            case .high where settings.alertOnHigh:
                fire(.high, title: "High glucose — \(v)", body: r.trend.description, cooldown: cooldown, now: now)
            case .high:
                break
            case .inRange:
                // Reset low/high so the next excursion alerts immediately.
                lastFired[.low] = nil; lastFired[.high] = nil; lastFired[.urgentLow] = nil; lastFired[.veryHigh] = nil
            }

            if settings.alertOnRapidChange, r.trend.isRapid {
                fire(.rapidChange, title: "\(r.trend.description) — \(v)",
                     body: s.deltaMgdl.map { "\(unit.formatDelta(mgdl: $0)) since last reading" } ?? "",
                     cooldown: cooldown, now: now)
            } else if !r.trend.isRapid {
                lastFired[.rapidChange] = nil
            }
        }

        if settings.alertOnStale, s.isStale(at: now), s.current != nil {
            let age = s.current.map { Format.age($0.age(at: now)) } ?? "a while"
            fire(.stale, title: "No recent glucose data", body: "Last reading \(age). Check your phone has signal and LibreLink is running.", cooldown: 30 * 60, now: now)
        } else {
            lastFired[.stale] = nil
        }

        if settings.alertOnSensorExpiry, let sensor = s.sensor {
            let days = sensor.daysRemaining(at: now)
            if days < 1 {
                fire(.sensorExpiring, title: "Sensor expires soon", body: "About \(Format.days(days)) left on sensor \(sensor.serial).", cooldown: 6 * 3600, now: now)
            }
        }

        if let err = s.lastError, err.contains("version") || err.contains("API may have changed") {
            fire(.apiBroken, title: "GlucOS needs attention", body: err, cooldown: 6 * 3600, now: now)
        }
    }

    /// Heads-up alerts from the forecast: glucose is heading out of range within the lead time.
    /// Only while the reading is current and still on the right side of the threshold, so these
    /// never stand in for the alerts on actual readings above.
    func evaluatePrediction(_ s: GlucoseSnapshot, forecast: GlucoseForecast?, settings: AppSettings, now: Date = Date()) {
        guard settings.alertsEnabled, settings.alertOnPredictedLow || settings.alertOnPredictedHigh else { return }
        guard let r = s.current, !s.isStale(at: now), let forecast else {
            clearPredictions(now: now)
            return
        }
        let rules = PredictiveAlertSettings(lows: settings.alertOnPredictedLow, highs: settings.alertOnPredictedHigh,
                                            leadTime: TimeInterval(settings.predictiveAlertMinutes * 60),
                                            lowMgdl: s.lowMgdl, highMgdl: s.highMgdl, highAlertsOn: settings.alertOnHigh)
        guard let d = PredictiveAlertRules.evaluate(forecast, settings: rules, now: now) else {
            clearPredictions(now: now)
            return
        }
        quietSince = nil
        // Another kind's heads-up isn't relevant any more.
        for k in [Kind.predictedUrgentLow, .predictedLow, .predictedHigh, .predictedVeryHigh] where k != Self.kind(for: d.kind) {
            lastFired[k] = nil
        }
        let unit = s.unit
        let minutes = d.minutesAway(from: now)
        let when = minutes <= 1 ? "any minute" : "in about \(minutes) min"
        let current = "Now \(unit.format(mgdl: r.mgdl, withUnit: true)) \(r.trend.arrow)."
        let threshold = unit.format(mgdl: d.thresholdMgdl, withUnit: true)
        let note = "Forecast, not a reading: check before acting."
        let cooldown = TimeInterval(settings.alertCooldownMinutes * 60)
        switch d.kind {
        case .urgentLow:
            fire(.predictedUrgentLow, title: "Urgent low predicted \(when)",
                 body: "\(current) Heading below \(threshold). \(note)", cooldown: min(cooldown, 10 * 60), critical: true, now: now)
        case .low:
            fire(.predictedLow, title: "Low predicted \(when)",
                 body: "\(current) Heading below \(threshold). \(note)", cooldown: cooldown, now: now)
        case .high:
            fire(.predictedHigh, title: "High predicted \(when)",
                 body: "\(current) Heading above \(threshold). \(note)", cooldown: max(cooldown, 30 * 60), now: now)
        case .veryHigh:
            fire(.predictedVeryHigh, title: "Very high predicted \(when)",
                 body: "\(current) Heading above \(threshold). \(note)", cooldown: max(cooldown, 30 * 60), now: now)
        }
    }

    /// Since when no excursion has been predicted. A forecast can hover around a threshold from
    /// one reading to the next, so the repeat timer only resets after a quiet spell.
    private var quietSince: Date?

    private func clearPredictions(now: Date) {
        if quietSince == nil { quietSince = now }
        guard let q = quietSince, now.timeIntervalSince(q) >= 15 * 60 else { return }
        for k in [Kind.predictedUrgentLow, .predictedLow, .predictedHigh, .predictedVeryHigh] { lastFired[k] = nil }
    }

    private func fire(_ kind: Kind, title: String, body: String, cooldown: TimeInterval, critical: Bool = false, now: Date) {
        if let last = lastFired[kind], now.timeIntervalSince(last) < cooldown { return }
        lastFired[kind] = now

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = critical ? .defaultCritical : .default
        content.interruptionLevel = critical ? .timeSensitive : .active
        let req = UNNotificationRequest(identifier: "glucos.\(kind.rawValue)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
