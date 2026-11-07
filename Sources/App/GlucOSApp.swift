import SwiftUI

@main
struct GlucOSApp: App {
    @StateObject private var store = GlucoseStore()
    @StateObject private var updater = Updater()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(store)
                .environmentObject(store.settings)
                .environmentObject(updater)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(store.settings)
                .environmentObject(updater)
        }
    }
}

/// The menu bar item: value + trend arrow, with a warning glyph when stale.
struct MenuBarLabel: View {
    @ObservedObject var store: GlucoseStore

    var body: some View {
        let stale = store.snapshot.current != nil && store.snapshot.isStale()
        HStack(spacing: 3) {
            Image(systemName: stale ? "exclamationmark.triangle.fill" : "drop.fill")
                .imageScale(.small)
            Text(store.menuBarText)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(store.snapshot.accessibilitySummary())
        .task { store.start() }   // ensure polling starts even if the popover is never opened
    }
}
