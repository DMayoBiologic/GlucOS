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
        // Each reading also lets go of alert records past 90 days, so a Mac that never quits keeps
        // to the limit too. Cheap: nothing is written unless one has expired.
        AlertLogRecorder.shared.logbook?.pruneExpiredAlerts(now: now)
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
        // "Log treatment" and "Snooze 30 min" (urgent lows: only the first). See AlertSnooze.swift.
        if let category = notice.kind.actionCategory { content.categoryIdentifier = category }
        content.userInfo = ["kind": notice.kind.rawValue]
        let req = UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil)
        // Only an alert that was actually shown goes in the logbook.
        let kind = notice.kind, time = Date()
        UNUserNotificationCenter.current().add(req) { error in
            guard error == nil else { return }
            Task { @MainActor in
                guard await AlertManager.notificationsAllowed() == true else { return }
                AlertLogRecorder.shared.fired(kind, at: time)
            }
        }
    }
}

// MARK: - Alerts in the Logbook

/// Keeps a logbook record of each low or high alert this device shows, and of the button tapped on
/// it (`AlertLog`, docs/AlertLog.md). Records only: nothing here logs a treatment.
@MainActor
final class AlertLogRecorder {
    static let shared = AlertLogRecorder()
    /// Set once at launch by each app.
    weak var logbook: LogbookStore?

    /// A local alert just shown by this device.
    func fired(_ kind: AlertNotice.Kind, at time: Date = Date()) {
        logbook?.alertFired(kind, at: time)
    }

    /// The user's own alert, local or pushed, as the notification arrived. A follower's copy of
    /// someone else's alert (it names the share it's from) is never theirs to record.
    func arrived(userInfo: [AnyHashable: Any], at time: Date) {
        guard let kind = Self.ownKind(userInfo) else { return }
        logbook?.alertFired(kind, at: time)
    }

    /// A button tapped on one of the user's own alerts that arrived at `firedAt`.
    func tapped(_ tap: AlertNotifications.Tap, userInfo: [AnyHashable: Any], firedAt: Date) {
        guard Self.ownKind(userInfo) != nil else { return }
        let response: AlertRecord.Response
        switch tap {
        case .snooze: response = .snoozed
        case .treat: response = .treating
        }
        logbook?.alertAnswered(tap.kind, response, snoozeMinutes: tap.snoozeMinutes, firedAt: firedAt)
    }

    /// The user's own alerts still in Notification Center, which arrived as pushes while GlucOS
    /// wasn't running. Already recorded ones are skipped.
    func collectDelivered() async {
        logbook?.pruneExpiredAlerts()
        let shown = await UNUserNotificationCenter.current().deliveredNotifications()
        for n in shown { arrived(userInfo: n.request.content.userInfo, at: n.date) }
    }

    private static func ownKind(_ userInfo: [AnyHashable: Any]) -> AlertNotice.Kind? {
        guard userInfo["followID"] == nil, let raw = userInfo["kind"] as? String,
              let kind = AlertNotice.Kind(rawValue: raw), AlertLog.isLogged(kind) else { return nil }
        return kind
    }
}

// MARK: - Snooze and "Log treatment"

/// This device's alert snoozes, kept across launches. Read at delivery by `AlertManager`; the
/// iPhone also sends each one to the relay for its push alerts.
@MainActor
final class AlertSnoozeStore: ObservableObject {
    static let shared = AlertSnoozeStore()
    private static let key = "alertSnoozes"
    private let defaults: UserDefaults

    @Published private(set) var snoozes: AlertSnoozes
    /// Goes up with every change made on this device (a snooze button, the chip's Resume), so a
    /// relay status that was asked for before the change can't undo it (`adopt`).
    private(set) var revision = 0

    private var pruneTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        snoozes = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(AlertSnoozes.self, from: $0) }
            ?? AlertSnoozes()
        pruneWhenNextEnds()
    }

    /// Something is snoozed right now: the "snoozed" chip shows.
    var isSnoozing: Bool { !snoozes.active(at: Date()).isEmpty }

    /// False for an alert that can't be snoozed (urgent lows).
    @discardableResult
    func snooze(_ kind: AlertNotice.Kind, minutes: Int, now: Date = Date()) -> Bool {
        var s = snoozes
        s.prune(now: now)
        guard s.snooze(kind, minutes: minutes, now: now) else { return false }
        save(s)
        revision += 1
        return true
    }

    /// The "snoozed" chip was tapped: every alert is back on now. Snoozed alerts were let go of, so
    /// one that's still due fires on the next reading.
    func resumeAll() {
        guard snoozes != AlertSnoozes() else { return }
        save(AlertSnoozes())
        revision += 1
    }

    /// The relay's snoozes (iPhone, relay 2.15.0 on), which decide what it pushes: this device
    /// takes them as its own, so the chip, the phone's own alerts and the pushes all agree. Skipped
    /// when this device changed a snooze after the status was asked for (`revision` moved on).
    func adopt(_ relay: AlertSnoozes, askedAt revision: Int, now: Date = Date()) {
        guard revision == self.revision else { return }
        var r = relay
        r.prune(now: now)
        var mine = snoozes
        mine.prune(now: now)
        guard r != mine else { return }
        save(r)
    }

    private func save(_ s: AlertSnoozes) {
        snoozes = s
        defaults.set(try? JSONEncoder().encode(s), forKey: Self.key)
        pruneWhenNextEnds()
    }

    /// Drops each snooze the moment it ends, so the chip goes away then (one fade) without anything
    /// polling. The alert rules read the end times, not this, so it changes nothing about alerts.
    private func pruneWhenNextEnds(now: Date = Date()) {
        pruneTask?.cancel()
        var pruned = snoozes
        pruned.prune(now: now)
        if pruned != snoozes {
            snoozes = pruned
            defaults.set(try? JSONEncoder().encode(pruned), forKey: Self.key)
        }
        guard let end = pruned.nextEnd(after: now) else { return }
        pruneTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.5, end.timeIntervalSinceNow + 0.5)))
            guard !Task.isCancelled else { return }
            self?.pruneWhenNextEnds()
        }
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
                                          title: AlertSnoozes.snoozeTitle, options: [],
                                          icon: UNNotificationActionIcon(systemImageName: "zzz"))
        let treat = UNNotificationAction(identifier: AlertSnoozes.treatAction, title: AlertSnoozes.treatTitle,
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
