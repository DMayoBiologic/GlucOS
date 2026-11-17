import Foundation
import UserNotifications

/// Keeps today's evening recap notification up to date (docs/EveningRecap.md). A local
/// notification's words are fixed when it's added, so `update` adds it again, under the same
/// identifier, whenever new readings move today's figures. Off unless turned on in Settings; off,
/// it takes back any recap still waiting. Shared by the Mac and iPhone apps.
@MainActor
final class EveningRecapScheduler {
    static let shared = EveningRecapScheduler()

    /// What the pending recap was last scheduled from (`EveningRecap.Key`); nil after a removal.
    private var lastKey: EveningRecap.Key?
    private var cleared = false

    /// Called on every publish of the store and on settings changes. Cheap when nothing moved.
    func update(readings: [GlucoseReading], settings: AppSettings, now: Date = Date()) {
        guard settings.eveningRecapEnabled else {
            remove()
            return
        }
        let minute = settings.eveningRecapMinute
        let key = EveningRecap.key(readings: readings, low: settings.lowMgdl, high: settings.highMgdl,
                                   unit: settings.unit, minute: minute, now: now)
        guard key != lastKey else { return }
        // Checked only when something moved: it reads the Keychain. Followers have no readings of their own.
        guard settings.hasCredentials else {
            remove()
            return
        }
        lastKey = key
        guard let fireAt = EveningRecap.fireDate(minute: minute, now: now),
              let recap = EveningRecap.compute(readings: readings, low: settings.lowMgdl, high: settings.highMgdl,
                                               minute: minute, now: now) else {
            // Past today's time (the one already scheduled stands, or has gone out), or too few
            // readings today to say anything: leave nothing misleading waiting.
            if EveningRecap.fireDate(minute: minute, now: now) != nil { removePending() }
            return
        }
        cleared = false
        let content = UNMutableNotificationContent()
        content.title = EveningRecapText.title
        content.subtitle = EveningRecapText.period(recap)
        content.body = EveningRecapText.body(recap, unit: settings.unit)
        // Not an alert: no sound, and a Focus holds it back like any other ordinary notification.
        content.interruptionLevel = .active
        content.threadIdentifier = "glucos.recap"
        content.userInfo = ["kind": EveningRecap.kind]
        let parts = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        // Same identifier, so this replaces the pending one rather than adding a second.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: EveningRecap.identifier, content: content, trigger: trigger))
    }

    /// The switch went off or the account was signed out.
    private func remove() {
        guard !cleared else { return }
        cleared = true
        lastKey = nil
        removePending()
    }

    private func removePending() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [EveningRecap.identifier])
    }

    /// Whether a notification is the evening recap (its tap opens Insights on today).
    nonisolated static func isRecap(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo["kind"] as? String == EveningRecap.kind
    }
}

/// A tap on the recap asks the app to show Insights on today. The Mac dashboard and the iPhone home
/// stack each read and clear it; it's held here because the tap can arrive before either exists
/// (the tap that launched the app).
@MainActor
final class EveningRecapRoute: ObservableObject {
    static let shared = EveningRecapRoute()
    /// When the tapped recap went out, so the Today card shows the same day and hours even when the
    /// tap comes later. Cleared by whichever screen opened Insights for it.
    @Published var request: Date?

    func open(firedAt date: Date) { request = date }

    /// Takes the request, if there is one.
    func take() -> Date? {
        guard let date = request else { return nil }
        request = nil
        return date
    }
}
