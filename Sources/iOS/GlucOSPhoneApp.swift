import SwiftUI
import UIKit
import UserNotifications

@main
struct GlucOSPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate
    @StateObject private var store: GlucoseStore
    @StateObject private var logbook: LogbookStore
    @StateObject private var services: PhoneServices
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = GlucoseStore()
        let logbook = LogbookStore()
        store.logbook = logbook
        _store = StateObject(wrappedValue: store)
        _logbook = StateObject(wrappedValue: logbook)
        _services = StateObject(wrappedValue: PhoneServices(store: store))
        // Has to happen before launch finishes.
        BackgroundRefresh.register()
    }

    var body: some Scene {
        WindowGroup {
            PhoneRootView()
                .environmentObject(store)
                .environmentObject(logbook)
                .environmentObject(services)
                .environmentObject(store.settings)
                .modifier(PhoneTextScale())
                .onOpenURL { _ in Task { await store.refresh() } }
        }
        .onChange(of: scenePhase) { _, phase in services.scenePhaseChanged(phase) }
    }
}

/// The design system's sizes are tuned for the Mac, where body text is 13 pt. On iPhone they
/// follow Dynamic Type instead, starting from iOS's 17 pt body at the default size.
struct PhoneTextScale: ViewModifier {
    @Environment(\.dynamicTypeSize) private var size

    private var scale: CGFloat {
        switch size {
        case .xSmall: return 1.1
        case .small: return 1.15
        case .medium: return 1.22
        case .large: return 1.3
        case .xLarge: return 1.38
        case .xxLarge: return 1.44
        default: return 1.5
        }
    }

    func body(content: Content) -> some View {
        content.environment(\.dsTextScale, scale)
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
    }
}
