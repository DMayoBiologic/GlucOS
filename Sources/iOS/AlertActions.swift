import Foundation
import UserNotifications

/// "Snooze 30 min" and "Log treatment" on the iPhone's low and high alerts (docs/AlertActions.md),
/// whether the alert came from the relay or from the phone itself.
@MainActor
enum PhoneAlertActions {
    /// Returns once the relay has the snooze (or it has failed), so iOS keeps the app awake for it.
    /// `origin`: the notification's button or the in-app banner's, for the caption on what's logged.
    static func handle(_ tap: AlertNotifications.Tap, from origin: LogOrigin = .notification) async {
        if case .treat(_, let treatment) = tap { PhoneLogRouter.shared.treat(treatment, from: origin) }
        // Urgent lows: the log sheet only, nothing is ever quieted.
        guard let minutes = tap.snoozeMinutes else { return }
        AlertSnoozeStore.shared.snooze(tap.kind, minutes: minutes)
        do {
            try await PhoneServices.shared?.snoozeRelayAlerts(tap.kind, minutes: minutes)
        } catch {
            // The phone is quiet but the relay may not be: say so, rather than let a push arrive
            // after the user thought they had snoozed it.
            let content = UNMutableNotificationContent()
            content.title = "Snooze didn't reach GlucOS's server"
            content.body = "This alert may still come through for the next \(minutes) minutes "
                + "(\(error.localizedDescription))."
            content.sound = nil
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "glucos.snooze.failed", content: content, trigger: nil))
        }
    }
}
