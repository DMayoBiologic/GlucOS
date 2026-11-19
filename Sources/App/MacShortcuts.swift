#if os(macOS)
import AppIntents

/// The Mac's Siri and Shortcuts phrases. The iPhone has its own provider (`GlucOSAppShortcuts`);
/// each app may have only one.
struct GlucOSMacShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: DaySummaryIntent(),
                    phrases: ["How was my day in \(.applicationName)",
                              "How's my day going in \(.applicationName)",
                              "My \(.applicationName) day so far",
                              "\(.applicationName) today so far"],
                    shortTitle: "How Was My Day",
                    systemImageName: "sun.max")
    }
}
#endif
