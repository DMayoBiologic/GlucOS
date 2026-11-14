import SwiftUI
import UIKit
import UserNotifications

@main
struct GlucOSPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate
    @StateObject private var store: GlucoseStore
    @StateObject private var logbook: LogbookStore
    @StateObject private var services: PhoneServices
    @StateObject private var logbookSync: LogbookSyncService
    @StateObject private var follows: FollowStore
    @StateObject private var sharing = OwnerSharing()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = GlucoseStore()
        let logbook = LogbookStore()
        store.logbook = logbook
        _store = StateObject(wrappedValue: store)
        _logbook = StateObject(wrappedValue: logbook)
        PhoneWakeLogger.shared.logbook = logbook
        let sync = LogbookSyncService(logbook: logbook, settings: store.settings, device: "iPhone")
        sync.forecastLedger = store.outlook.ledger
        _logbookSync = StateObject(wrappedValue: sync)
        let follows = FollowStore()
        _follows = StateObject(wrappedValue: follows)
        let services = PhoneServices(store: store)
        services.logbookSync = sync
        services.follows = follows
        _services = StateObject(wrappedValue: services)
        // Before any check-in button can run: they may be what launched the app.
        CheckInCoordinator.install(services: services, follows: follows)
        // Has to happen before launch finishes.
        BackgroundRefresh.register()
    }

    var body: some Scene {
        WindowGroup {
            PhoneRootView()
                .environmentObject(store)
                .environmentObject(logbook)
                .environmentObject(services)
                .environmentObject(logbookSync)
                .environmentObject(store.settings)
                .environmentObject(follows)
                .environmentObject(sharing)
                .environmentObject(PhoneLogRouter.shared)
                .modifier(PhoneTextScale())
                .onOpenURL { url in
                    if let token = FollowLink.token(from: url) {
                        Task { await follows.open(token: token) }
                    } else {
                        // glucos://log opens the log sheet (Lock Screen widget, Dynamic Island, links);
                        // glucos://log/wake logs a wake-up.
                        PhoneLogRouter.shared.handle(url)
                        Task { await store.refresh() }
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            services.scenePhaseChanged(phase)
            // Error reports saved while offline go out when the app comes back.
            if phase == .active { Task { await Diagnostics.shared.flush() } }
            // The first use of the morning is offered as the wake-up time.
            if phase == .active { PhoneWakeLogger.shared.noteActive() }
        }
    }
}

/// Push registration and how notifications show while the app is open.
final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // The device token only reaches the relay; without one alerts are local-only.
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.hexString
        UserDefaults.standard.set(token, forKey: "apnsDeviceToken")
        Task { @MainActor in PhoneServices.shared?.deviceTokenArrived(token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PhoneServices.shared?.deviceTokenFailed(error) }
    }

    /// Show glucose alerts as banners even with the app open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
        let userInfo = notification.request.content.userInfo
        Task { @MainActor in await CheckInCoordinator.arrived(userInfo: userInfo) }
    }

    /// Check-in buttons on a notification ("I'm okay", "I need help", "Check in").
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            await CheckInCoordinator.handle(action: action, userInfo: userInfo)
            completionHandler()
        }
    }
}
