import AppKit
import os
import UserNotifications

/// App-level plumbing SwiftUI's `App` doesn't cover for a menu bar app:
/// - `glucos://open` (widget taps) and re-opening the app from Finder/Spotlight show the popover; `glucos://dashboard` opens the dashboard.
/// - Notifications still appear while GlucOS is the active app, and clicking one shows the popover.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Must be set before launch finishes, or a click on a notification that launched us is lost.
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Registered after SwiftUI's own setup so this handler is the one that receives URL events.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string), url.scheme == "glucos" else { return }
        switch url.host {
        case "dashboard":
            // Opened by whoever can reach SwiftUI's openWindow (see MenuBarLabel).
            NotificationCenter.default.post(name: .glucosOpenDashboard, object: nil)
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
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in StatusItemPopover.show() }
        completionHandler()
    }
}

extension Notification.Name {
    /// Posted for `glucos://dashboard` (the widgets' dashboard button).
    static let glucosOpenDashboard = Notification.Name("au.com.declanmayo.glucos.open-dashboard")
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
