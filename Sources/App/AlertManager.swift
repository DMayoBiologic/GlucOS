import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// Supplementary alerts as local notifications. The LibreLink app's alarms remain the primary ones.
@MainActor
final class AlertManager {
    /// The rules and repeat timers, shared with the push relay.
    private var planner = AlertPlanner()
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

    #if os(macOS)
    /// System Settings → Notifications → GlucOS.
    static let notificationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=au.com.declanmayo.glucos")!
    #else
    /// Settings → GlucOS → Notifications.
    static let notificationSettingsURL = URL(string: UIApplication.openNotificationSettingsURLString)!
    #endif

    /// A harmless sample alert so you can check banners and sound are working.
    func sendTest() {
        let content = UNMutableNotificationContent()
        content.title = "GlucOS test alert"
        content.body = "If you can see and hear this, glucose alerts will reach you."
        content.sound = .default
        let req = UNNotificationRequest(identifier: "glucos.test", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Shows local notifications for the alerts that are due. The iPhone app turns this off
    /// while the push relay is delivering the same alerts, so they don't arrive twice.
    var deliversLocally = true

    func evaluate(_ s: GlucoseSnapshot, settings: AppSettings, now: Date = Date()) {
        for notice in planner.evaluate(s, prefs: settings.alertPreferences, now: now) { deliver(notice) }
    }

    /// Heads-up alerts from the forecast. See `AlertPlanner.evaluatePrediction`.
    func evaluatePrediction(_ s: GlucoseSnapshot, forecast: GlucoseForecast?, settings: AppSettings, now: Date = Date()) {
        if let notice = planner.evaluatePrediction(s, forecast: forecast, prefs: settings.alertPreferences, now: now) {
            deliver(notice)
        }
    }

    private func deliver(_ notice: AlertNotice) {
        guard deliversLocally else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = notice.critical ? .defaultCritical : .default
        content.interruptionLevel = notice.critical ? .timeSensitive : .active
        content.threadIdentifier = "glucos.alerts"
        let req = UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
