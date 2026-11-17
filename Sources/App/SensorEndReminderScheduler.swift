import Foundation
import UserNotifications

/// Keeps the evening-before reminder for the current sensor (docs/SensorEnd.md) scheduled. Off
/// unless turned on in Settings; off, signed out, or with nothing to remind about, it takes back
/// any reminder still waiting. A new sensor moves the reminder to its own end. Shared by the Mac
/// and iPhone apps.
@MainActor
final class SensorEndReminderScheduler {
    static let shared = SensorEndReminderScheduler()

    /// What the pending reminder was last scheduled from; nil after a removal.
    private var lastKey: SensorEndReminder.Key?
    private var cleared = false

    /// Called on every publish of the store and on settings changes. Cheap when nothing moved.
    func update(sensor: SensorInfo?, settings: AppSettings, now: Date = Date()) {
        guard settings.sensorEndReminderEnabled, let sensor, sensor.lifetimeDays > 0 else {
            remove()
            return
        }
        let fireAt = SensorEndReminder.fireDate(endsAt: sensor.expires, now: now)
        let key = SensorEndReminder.Key(endsAt: sensor.expires, fireAt: fireAt)
        guard key != lastKey else { return }
        // Checked only when something moved: it reads the Keychain. Followers have no sensor of their own.
        guard settings.hasCredentials else {
            remove()
            return
        }
        lastKey = key
        guard let fireAt else {
            // The evening before has gone (the one scheduled stands, or has gone out). A reminder
            // left over from an earlier sensor would be for the wrong one, so only a new sensor's
            // reminder ever replaces it, and nothing else waits.
            if sensor.expires <= now { removePending() }
            return
        }
        cleared = false
        let content = UNMutableNotificationContent()
        content.title = SensorEndReminder.title(endsAt: sensor.expires)
        content.body = SensorEndReminder.body(endsAt: sensor.expires)
        // Not an alert: no sound, and a Focus holds it back like any other ordinary notification.
        content.interruptionLevel = .active
        content.threadIdentifier = SensorEndReminder.identifier
        content.userInfo = ["kind": SensorEndReminder.kind]
        let parts = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        // Same identifier, so a new sensor's reminder replaces the old one rather than adding a second.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: SensorEndReminder.identifier, content: content, trigger: trigger))
    }

    /// The switch went off, the account was signed out, or there's no sensor.
    private func remove() {
        guard !cleared else { return }
        cleared = true
        lastKey = nil
        removePending()
    }

    private func removePending() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [SensorEndReminder.identifier])
    }
}
