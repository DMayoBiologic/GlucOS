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
    /// while the push relay is delivering the same alerts, so they don't arrive twice. It's asked
    /// at delivery time, so a relay that has gone quiet since its last status hands alerts back.
    var deliversLocally: @MainActor () -> Bool = { true }

    func evaluate(_ s: GlucoseSnapshot, settings: AppSettings, now: Date = Date()) {
        let due = planner.evaluate(s, prefs: settings.alertPreferences, now: now)
        for notice in planner.unsnoozed(due, snoozes: AlertSnoozeStore.shared.snoozes, now: now) { deliver(notice) }
    }

    /// Heads-up alerts from the forecast. See `AlertPlanner.evaluatePrediction`.
    func evaluatePrediction(_ s: GlucoseSnapshot, forecast: GlucoseForecast?, settings: AppSettings, now: Date = Date()) {
        if let notice = planner.evaluatePrediction(s, forecast: forecast, prefs: settings.alertPreferences, now: now) {
            for n in planner.unsnoozed([notice], snoozes: AlertSnoozeStore.shared.snoozes, now: now) { deliver(n) }
        }
    }

    private func deliver(_ notice: AlertNotice) {
        guard deliversLocally() else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = notice.critical ? .defaultCritical : .default
        content.interruptionLevel = notice.critical ? .timeSensitive : .active
        content.threadIdentifier = "glucos.alerts"
        // "Snooze 30 min" and "I'm treating it" (urgent lows: only the second). See AlertSnooze.swift.
        if let category = notice.kind.actionCategory { content.categoryIdentifier = category }
        content.userInfo = ["kind": notice.kind.rawValue]
        let req = UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

// MARK: - Snooze and "I'm treating it"

/// This device's alert snoozes, kept across launches. Read at delivery by `AlertManager`; the
/// iPhone also sends each one to the relay for its push alerts.
@MainActor
final class AlertSnoozeStore: ObservableObject {
    static let shared = AlertSnoozeStore()
    private static let key = "alertSnoozes"
    private let defaults: UserDefaults

    @Published private(set) var snoozes: AlertSnoozes

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        snoozes = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(AlertSnoozes.self, from: $0) }
            ?? AlertSnoozes()
    }

    /// False for an alert that can't be snoozed (urgent lows).
    @discardableResult
    func snooze(_ kind: AlertNotice.Kind, minutes: Int, now: Date = Date()) -> Bool {
        var s = snoozes
        s.prune(now: now)
        guard s.snooze(kind, minutes: minutes, now: now) else { return false }
        snoozes = s
        defaults.set(try? JSONEncoder().encode(s), forKey: Self.key)
        return true
    }
}

/// The buttons on low and high alerts, for both apps and for the relay's pushes (which carry the
/// same category and `kind`).
enum AlertNotifications {
    /// A tapped alert button.
    enum Tap: Equatable {
        case snooze(AlertNotice.Kind)
        case treat(AlertNotice.Kind, AlertTreatment)

        var kind: AlertNotice.Kind {
            switch self {
            case .snooze(let k), .treat(let k, _): return k
            }
        }

        /// How long the tap quiets this alert for: nothing for an urgent low.
        var snoozeMinutes: Int? {
            guard kind.snoozeLevel != nil else { return nil }
            switch self {
            case .snooze: return AlertSnoozes.snoozeMinutes
            case .treat(_, let t): return AlertSnoozes.treatingMinutes(t)
            }
        }
    }

    static var categories: [UNNotificationCategory] {
        // Snoozing needs no unlocking (it only quiets this device's own alerts); treating opens the
        // log sheet, so it brings the app forward.
        let snooze = UNNotificationAction(identifier: AlertSnoozes.snoozeAction,
                                          title: "Snooze \(AlertSnoozes.snoozeMinutes) min", options: [],
                                          icon: UNNotificationActionIcon(systemImageName: "zzz"))
        let treat = UNNotificationAction(identifier: AlertSnoozes.treatAction, title: "I'm treating it",
                                         options: [.foreground],
                                         icon: UNNotificationActionIcon(systemImageName: "cross.case.fill"))
        return [
            UNNotificationCategory(identifier: AlertSnoozes.snoozeAndTreatCategory, actions: [treat, snooze],
                                   intentIdentifiers: []),
            // Urgent lows are never snoozable.
            UNNotificationCategory(identifier: AlertSnoozes.treatOnlyCategory, actions: [treat], intentIdentifiers: []),
        ]
    }

    /// The alert button behind a notification response, if it was one.
    static func button(action: String, userInfo: [AnyHashable: Any]) -> Tap? {
        guard let raw = userInfo["kind"] as? String, let kind = AlertNotice.Kind(rawValue: raw) else { return nil }
        switch action {
        case AlertSnoozes.snoozeAction:
            return kind.snoozeLevel == nil ? nil : .snooze(kind)
        case AlertSnoozes.treatAction:
            return kind.treatment.map { .treat(kind, $0) }
        default:
            return nil
        }
    }
}
