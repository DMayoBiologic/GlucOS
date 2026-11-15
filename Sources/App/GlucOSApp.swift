import SwiftUI
import AppKit

@main
struct GlucOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: GlucoseStore
    @StateObject private var updater = Updater()
    @StateObject private var logbook: LogbookStore
    @StateObject private var logbookSync: LogbookSyncService

    init() {
        let store = GlucoseStore()
        let logbook = LogbookStore()
        store.logbook = logbook
        let sync = LogbookSyncService(logbook: logbook, settings: store.settings, device: "Mac")
        sync.forecastLedger = store.outlook.ledger
        _store = StateObject(wrappedValue: store)
        _logbook = StateObject(wrappedValue: logbook)
        _logbookSync = StateObject(wrappedValue: sync)
        // The Mac app runs all the time, so sync starts with it and keeps going.
        Task { @MainActor in
            sync.start()
            // "Was that dose for a meal?" after a dose with no food near it.
            DoseQuestion.shared.start(logbook: logbook)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(store)
                .environmentObject(store.outlook)
                .environmentObject(store.settings)
                .environmentObject(updater)
                .environmentObject(logbook)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        // The pop-out dashboard, opened from the popover. Never opened at launch: the
        // MenuBarExtra above is the app's primary scene.
        Window("GlucOS Dashboard", id: DashboardView.windowID) {
            DashboardView()
                .environmentObject(store)
                .environmentObject(store.outlook)
                .environmentObject(store.settings)
                .environmentObject(logbook)
        }
        .defaultSize(width: 1040, height: 720)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)

        // First-run setup. Opened by MenuBarLabel at launch until it's finished or skipped.
        Window("Welcome to GlucOS", id: OnboardingView.windowID) {
            OnboardingView()
                .environmentObject(store)
                .environmentObject(store.outlook)
                .environmentObject(store.settings)
        }
        // Opens at its ideal size; resizable down to a minimum that fits a 13" display, and up
        // for people who want more room (content stays at a readable width).
        .defaultSize(width: 640, height: 620)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)

        // Quick log from the menu bar, without opening the dashboard.
        Window("Log", id: LogWindow.id) {
            LogWindow()
                .environmentObject(logbook)
                .environmentObject(store)
                .environmentObject(store.settings)
        }
        .defaultSize(width: 540, height: 680)
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(store.outlook)
                .environmentObject(store.settings)
                .environmentObject(updater)
                .environmentObject(logbook)
                .environmentObject(logbookSync)
        }
        .windowResizability(.contentMinSize)
    }
}

/// The menu bar item. Drawn by `MenuBarStatusModel` (MenuBarStatusItem.swift), which redraws only
/// when what it shows changes. This view doesn't observe the store, so the store's periodic
/// age refresh never re-renders the menu bar.
struct MenuBarLabel: View {
    let store: GlucoseStore
    @StateObject private var status: MenuBarStatusModel
    @Environment(\.openWindow) private var openWindow

    init(store: GlucoseStore) {
        self.store = store
        _status = StateObject(wrappedValue: MenuBarStatusModel(store: store))
    }

    var body: some View {
        Image(nsImage: status.image)
            .accessibilityLabel(status.accessibilityLabel)
            .task {
                store.start()   // ensure polling starts even if the popover is never opened
                if AppSettings.shared.needsOnboarding {
                    openWindow(id: OnboardingView.windowID)
                    NSApp.activate()
                }
            }
            // The label lives as long as the app, so it's the one place that can always open the
            // dashboard window for a glucos://dashboard link.
            .onReceive(NotificationCenter.default.publisher(for: .glucosOpenDashboard)) { _ in
                openWindow(id: DashboardView.windowID)
                NSApp.activate()
            }
    }
}
