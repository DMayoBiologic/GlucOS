import SwiftUI
import AppKit

@main
struct GlucOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = GlucoseStore()
    @StateObject private var updater = Updater()
    @StateObject private var logbook = LogbookStore()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(store)
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
                .environmentObject(store.settings)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)

        // Quick log from the menu bar, without opening the dashboard.
        Window("Log Insulin or Food", id: LogWindow.id) {
            LogWindow()
                .environmentObject(logbook)
                .environmentObject(store.settings)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(store.settings)
                .environmentObject(updater)
                .environmentObject(logbook)
        }
    }
}

/// The menu bar item: value + trend arrow, with a warning glyph when stale.
struct MenuBarLabel: View {
    @ObservedObject var store: GlucoseStore
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let stale = store.snapshot.current != nil && store.snapshot.isStale()
        HStack(spacing: 3) {
            icon(stale: stale)
            Text(store.statusItemText())
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(store.snapshot.accessibilitySummary())
        .task {
            store.start()   // ensure polling starts even if the popover is never opened
            if settings.needsOnboarding {
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

extension MenuBarLabel {
    /// Monochrome by default, like every other menu bar item. With "Colour-code the menu bar icon"
    /// on, the drop takes the range colour. An urgent low is always coloured, whatever the setting,
    /// so it stands out from across the room. Stale data always shows the monochrome warning glyph
    /// (and its age instead of a trend arrow), so an old reading never looks like a reassuring one.
    /// With no reading at all, the drop is hollow.
    @ViewBuilder
    func icon(stale: Bool) -> some View {
        let range = store.snapshot.range
        if !stale, let range, settings.colorMenuBarIcon || range == .urgentLow,
           let image = Self.tintedSymbol(range == .urgentLow ? "exclamationmark.octagon.fill" : "drop.fill",
                                         color: range.nsColor) {
            Image(nsImage: image)
        } else if store.snapshot.current == nil {
            Image(systemName: "drop")
                .imageScale(.small)
        } else {
            Image(systemName: stale ? "exclamationmark.triangle.fill" : "drop.fill")
                .imageScale(.small)
        }
    }

    /// Menu bar labels render SwiftUI images as templates (monochrome), so a coloured icon has to
    /// be a non-template NSImage.
    static func tintedSymbol(_ name: String, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        image.isTemplate = false
        return image
    }
}

private extension GlucoseRange {
    var nsColor: NSColor {
        nsTint
    }
}
