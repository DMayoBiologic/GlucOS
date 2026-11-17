import AppKit
import os
import UserNotifications

/// App-level plumbing SwiftUI's `App` doesn't cover for a menu bar app:
/// - `glucos://open` (widget taps) and re-opening the app from Finder/Spotlight show the popover; `glucos://dashboard` opens the dashboard;
///   `glucos://log` and `glucos://log/usual/<id>` (the Your usual widget) open the log window.
/// - Notifications still appear while GlucOS is the active app, and clicking one shows the popover
///   (the Meal / Correction buttons of "Was that dose for a meal?" answer without opening it).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Must be set before launch finishes, or a click on a notification that launched us is lost.
        UNUserNotificationCenter.current().delegate = self
        // "Was that dose for a meal?" with Meal and Correction buttons, and the low/high alerts'
        // "Snooze 30 min" and "Log treatment".
        UNUserNotificationCenter.current().setNotificationCategories(
            Set([DoseQuestion.notificationCategory] + AlertNotifications.categories))
        // The in-app alert banner's buttons do what the notification's do.
        AlertBannerCenter.shared.perform = { MacAlertActions.handle($0, from: .alertBanner) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Error reports saved while offline (see Diagnostics).
        Task { await Diagnostics.shared.flush() }
        // Registered after SwiftUI's own setup so this handler is the one that receives URL events.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        // The first use of the Mac each morning is offered as the wake-up time.
        MacWakeWatcher.shared.start()
        // The optional "open the log window from anywhere" shortcut (off unless turned on in Settings).
        GlobalLogShortcut.shared.start()
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string), url.scheme == "glucos" else { return }
        switch url.host {
        case "dashboard":
            // Opened by whoever can reach SwiftUI's openWindow (see MenuBarLabel).
            NotificationCenter.default.post(name: .glucosOpenDashboard, object: nil)
        case "log":
            // The Your usual widget: glucos://log/usual/<id> opens the log window filled in from
            // that entry (if it's still offered), glucos://log on a new entry. Never logs.
            LogWindowRequest.shared.open(UsualGlance.usualID(from: url).map { .usualID($0, at: Date()) } ?? .new, from: .widget)
            NotificationCenter.default.post(name: .glucosOpenLogWindow, object: nil)
        default:
            // glucos://open and anything unrecognised: show the reading.
            StatusItemPopover.show()
        }
    }

    /// Launching GlucOS again (Finder, Spotlight, Launchpad, clicking the widget) while it's running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        StatusItemPopover.show()
        return false
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Without this, macOS silently drops banners while the app is frontmost, which for a menu bar
    /// app is whenever the popover or Settings is open. A glucose alert must never be swallowed.
    ///
    /// A low or high alert while the popover or dashboard is in front slides in there as the in-app
    /// banner instead (docs/AlertActions.md, "In-app banner"), keeping the sound and the list.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let content = notification.request.content
        let userInfo = content.userInfo
        let title = content.title, body = content.body
        let date = notification.date
        Task { @MainActor in
            let inApp = AlertBannerCenter.shared.present(title: title, body: body, userInfo: userInfo, at: date)
            completionHandler(inApp ? [.list, .sound] : [.banner, .list, .sound])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let date = response.notification.date
        Task { @MainActor in
            // The evening recap opens the dashboard on Insights, with today at the top.
            if EveningRecapScheduler.isRecap(userInfo) {
                guard action == UNNotificationDefaultActionIdentifier else { return }
                EveningRecapRoute.shared.open(firedAt: date)
                NotificationCenter.default.post(name: .glucosOpenDashboard, object: nil)
                return
            }
            // Meal, Correction or dismissing "Was that dose for a meal?" is answered on the spot.
            if DoseQuestion.shared.handle(action: action, userInfo: userInfo),
               action != UNNotificationDefaultActionIdentifier { return }
            if let tap = AlertNotifications.button(action: action, userInfo: userInfo) {
                AlertLogRecorder.shared.tapped(tap, userInfo: userInfo, firedAt: date)
                MacAlertActions.handle(tap)
                return
            }
            StatusItemPopover.show()
        }
        completionHandler()
    }
}

/// "Snooze 30 min" and "Log treatment" on the Mac's low and high alerts, from the notification or
/// the in-app banner (docs/AlertActions.md). The Mac's snoozes are its own.
@MainActor
enum MacAlertActions {
    /// `origin`: the notification's button or the in-app banner's, for the caption on what's logged.
    static func handle(_ tap: AlertNotifications.Tap, from origin: LogOrigin = .notification) {
        if let minutes = tap.snoozeMinutes { AlertSnoozeStore.shared.snooze(tap.kind, minutes: minutes) }
        if case .treat(_, let treatment) = tap {
            // The quick-log window, opened by the menu bar label (it can reach openWindow).
            LogWindowRequest.shared.open(.treating(treatment), from: origin)
            NotificationCenter.default.post(name: .glucosOpenLogWindow, object: nil)
        }
    }
}

extension Notification.Name {
    /// Posted for `glucos://dashboard` (the widgets' dashboard button).
    static let glucosOpenDashboard = Notification.Name("au.com.declanmayo.glucos.open-dashboard")
    /// Posted for "Log treatment" on an alert: open the quick-log window on `LogWindowRequest`.
    static let glucosOpenLogWindow = Notification.Name("au.com.declanmayo.glucos.open-log-window")
}

/// Opens the `MenuBarExtra` popover programmatically. SwiftUI has no API for this, so it clicks
/// GlucOS's own status bar button, which is exactly what the user would do. If AppKit's internals
/// ever change and the button can't be found, this quietly does nothing.
@MainActor
enum StatusItemPopover {
    static func show() {
        // Already open: clicking again would close it.
        let isOpen = NSApp.windows.contains { $0.isVisible && $0.className.contains("MenuBarExtra") }
        guard !isOpen else { NSApp.activate(); return }
        for window in NSApp.windows where window.className.contains("NSStatusBarWindow") {
            if let button = findButton(in: window.contentView) {
                button.performClick(nil)
                NSApp.activate()
                return
            }
        }
        // AppKit's private window/button names changed: make the regression visible in Console.
        Logger(subsystem: "au.com.declanmayo.glucos", category: "popover")
            .error("Couldn't find the status bar button to open the popover")
    }

    private static func findButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews {
            if let found = findButton(in: sub) { return found }
        }
        return nil
    }
}
