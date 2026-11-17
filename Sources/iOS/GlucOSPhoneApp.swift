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
        // And the Your usual widget's buttons, which open the log sheet on an entry.
        UsualActions.open = { PhoneLogRouter.shared.openUsual($0) }
        // And the Control Center controls: Glucose opens Today, Log treatment the low sheet.
        ControlActions.open = { PhoneLogRouter.shared.openControl($0) }
        // The in-app alert banner's buttons do what the notification's do, Logbook sync included.
        AlertBannerCenter.shared.perform = { tap in
            await PhoneAlertActions.handle(tap, from: .alertBanner)
            await PhoneServices.shared?.logbookSync?.sync()
        }
        // Likewise the Meal / Correction buttons after a dose with no food near it.
        DoseQuestion.shared.start(logbook: logbook)
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
            // A Your usual widget tap whose intent ran in the widget's process.
            if phase == .active, let id = UsualActions.takePending() { PhoneLogRouter.shared.openUsual(id) }
            // Likewise a Control Center control tap.
            if phase == .active, let target = ControlActions.takePending() { PhoneLogRouter.shared.openControl(target) }
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

    /// Show glucose alerts even with the app open. The user's own low and high alerts slide in as
    /// the in-app banner instead of the system one (docs/AlertActions.md, "In-app banner"), keeping
    /// the sound and the Notification Center entry; everything else gets the system banner.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let content = notification.request.content
        let userInfo = content.userInfo
        let title = content.title, body = content.body
        let date = notification.date
        Task { @MainActor in
            let inApp = AlertBannerCenter.shared.present(title: title, body: body, userInfo: userInfo, at: date)
            completionHandler(inApp ? [.list, .sound] : [.banner, .list, .sound])
            // The user's own low or high alert goes in the logbook (docs/AlertLog.md).
            AlertLogRecorder.shared.arrived(userInfo: userInfo, at: date)
            await CheckInCoordinator.arrived(userInfo: userInfo)
        }
    }

    /// Buttons on a notification: a tap on the evening recap opens Insights on today; "Snooze 30 min" and "Log treatment" on alerts, check-ins ("I'm
    /// okay", "I need help", "Check in") and "Was that dose for a meal?" (Meal, Correction).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let date = response.notification.date
        Task { @MainActor in
            if EveningRecapScheduler.isRecap(userInfo) {
                // The evening recap: Insights, opened on today (docs/EveningRecap.md).
                if action == UNNotificationDefaultActionIdentifier { EveningRecapRoute.shared.open(firedAt: date) }
            } else if let tap = AlertNotifications.button(action: action, userInfo: userInfo) {
                AlertLogRecorder.shared.tapped(tap, userInfo: userInfo, firedAt: date)
                await PhoneAlertActions.handle(tap)
                // While iOS keeps the app awake, so the Mac's Logbook shows the tap too.
                await PhoneServices.shared?.logbookSync?.sync()
            } else if DoseQuestion.shared.handle(action: action, userInfo: userInfo) {
                // Send the answer now, while iOS keeps the app awake, so the Mac stops asking too.
                if action != UNNotificationDefaultActionIdentifier {
                    await PhoneServices.shared?.logbookSync?.sync()
                }
            } else {
                await CheckInCoordinator.handle(action: action, userInfo: userInfo)
            }
            completionHandler()
        }
    }
}
