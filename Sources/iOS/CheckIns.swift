import Foundation
import UserNotifications

// Check-ins (docs/Sharing.md "Check-ins"): a follower asks the person they follow whether they're
// okay, from the Check in button on that person's Lock Screen card, from a low alert, or in the
// app. The person answers "I'm okay" or "I need help" from the notification, their own Lock
// Screen card, or the app, without unlocking. The relay (supabase/functions/relay/checkins.ts)
// carries both ways and reminds everyone when there's no answer.

/// The notification buttons. The relay names the categories (`ownerCategory`,
/// `followerLowCategory` in checkins.ts).
enum CheckInNotifications {
    static let ownerCategory = "glucos.checkin"
    static let followerLowCategory = "glucos.follow.low"
    static let okayAction = "checkin.okay"
    static let helpAction = "checkin.help"
    static let askAction = "checkin.ask"

    static func register() {
        // No unlocking needed: someone who's low shouldn't have to get past Face ID to say so.
        let okay = UNNotificationAction(identifier: okayAction, title: "I'm okay", options: [],
                                        icon: UNNotificationActionIcon(systemImageName: "checkmark.circle.fill"))
        let help = UNNotificationAction(identifier: helpAction, title: "I need help", options: [.destructive],
                                        icon: UNNotificationActionIcon(systemImageName: "exclamationmark.triangle.fill"))
        let ask = UNNotificationAction(identifier: askAction, title: "Check in", options: [],
                                       icon: UNNotificationActionIcon(systemImageName: "hand.wave.fill"))
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: ownerCategory, actions: [okay, help], intentIdentifiers: []),
            UNNotificationCategory(identifier: followerLowCategory, actions: [ask], intentIdentifiers: []),
        ])
    }
}

/// Connects the Live Activity buttons and notification buttons to the app's stores.
@MainActor
enum CheckInCoordinator {
    static func install(services: PhoneServices, follows: FollowStore) {
        CheckInNotifications.register()
        CheckInActions.ask = { [weak follows] followID in
            guard let follows else { throw CheckInActions.Unavailable() }
            try await follows.checkIn(followID)
        }
        CheckInActions.answer = { [weak services] okay in
            guard let services else { throw CheckInActions.Unavailable() }
            try await services.answerCheckIn(okay ? .okay : .help)
        }
    }

    /// A tap on a notification button. Returns once the answer is sent (or has failed), so iOS
    /// keeps the app awake for it.
    static func handle(action: String, userInfo: [AnyHashable: Any]) async {
        do {
            switch action {
            case CheckInNotifications.okayAction:
                try await CheckInActions.answer?(true)
            case CheckInNotifications.helpAction:
                try await CheckInActions.answer?(false)
            case CheckInNotifications.askAction:
                guard let followID = userInfo["followID"] as? String else { return }
                try await CheckInActions.ask?(followID)
            default:
                return
            }
        } catch {
            // The button did nothing: say so, so nobody thinks the answer went.
            let content = UNMutableNotificationContent()
            content.title = action == CheckInNotifications.askAction ? "Check-in not sent" : "Answer not sent"
            content.body = "GlucOS couldn't reach its server (\(error.localizedDescription)). Open GlucOS and try again."
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "glucos.checkin.failed", content: content, trigger: nil))
        }
    }

    /// A check-in notification while the app is open: show it on the card and in the app now.
    static func arrived(userInfo: [AnyHashable: Any]) async {
        switch userInfo["kind"] as? String {
        case "checkIn": await PhoneServices.shared?.checkInArrived()
        case "checkInAnswer", "checkInNoAnswer": await PhoneServices.shared?.follows?.refresh(canStart: false)
        default: break
        }
    }
}
