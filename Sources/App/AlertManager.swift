import Foundation
import UserNotifications

/// Supplementary alerts via macOS notifications. The phone app's alarms remain the primary ones.
@MainActor
final class AlertManager {
    enum Kind: String, CaseIterable {
        case urgentLow, low, high, veryHigh, rapidChange, stale, sensorExpiring, apiBroken
    }

    private var lastFired: [Kind: Date] = [:]

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// - Parameter needsAttention: the last fetch failed in a way the user has to fix
    ///   (credentials, T&Cs, API change) rather than a transient network error.
    func evaluate(_ s: GlucoseSnapshot, settings: AppSettings, needsAttention: Bool = false, now: Date = Date()) {
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
            case .high:
                fire(.high, title: "High glucose — \(v)", body: r.trend.description, cooldown: cooldown, now: now)
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

        if needsAttention, let err = s.lastError {
            fire(.apiBroken, title: "GlucOS needs attention", body: err, cooldown: 6 * 3600, now: now)
        } else if s.lastError == nil {
            lastFired[.apiBroken] = nil
        }
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
