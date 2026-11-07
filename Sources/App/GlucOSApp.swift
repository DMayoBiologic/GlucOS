import SwiftUI
import AppKit

@main
struct GlucOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let stale = store.snapshot.current != nil && store.snapshot.isStale()
        HStack(spacing: 3) {
            icon(stale: stale)
            Text(store.menuBarText)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(store.snapshot.accessibilitySummary())
        .task { store.start() }   // ensure polling starts even if the popover is never opened
    }
}

extension MenuBarLabel {
    /// Monochrome by default, like every other menu bar item. With "Colour-code the menu bar icon"
    /// on, the drop takes the range colour. Stale data always shows the monochrome warning glyph,
    /// so an old reading never looks like a reassuring green one.
    @ViewBuilder
    func icon(stale: Bool) -> some View {
        if !stale, settings.colorMenuBarIcon, let range = store.snapshot.range,
           let image = Self.tintedSymbol("drop.fill", color: range.nsColor) {
            Image(nsImage: image)
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
        switch self {
        case .urgentLow, .low, .veryHigh: return .systemRed
        case .inRange: return .systemGreen
        case .high: return .systemOrange
        }
    }
}
