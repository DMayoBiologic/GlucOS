import SwiftUI
import AppKit

// The menu bar item's right-click menu (docs/MenuBarMenu.md, `MenuBarQuickMenu`). Right-click or
// Control-click the reading for Your usual, Log Something…, Open Logbook, Copy Reading and Settings….
// A plain click is left alone, so it still opens the popover.
//
// MenuBarExtra owns the status item and gives no way to set its menu, so a local event monitor
// watches for a right or Control click on GlucOS's own status bar button, swallows it, and pops a
// menu up under the button. The monitor only sees events sent to GlucOS's own windows and does
// nothing for any other click, so there is no tick and nothing runs while the menu is closed.
//
// Nothing is logged from the menu. A usual opens the log window filled in, as the popover row does,
// and is logged there with Log, after RepeatCheck and the calculator's confirm step.

@MainActor
final class MenuBarQuickMenuController: NSObject {
    private let store: GlucoseStore
    private let settings: AppSettings
    /// Run just before the menu opens: closes the hover preview, which would sit under it.
    private let willOpen: () -> Void
    private var monitor: Any?
    /// The usuals the open menu offered, by id, so a pick fills in exactly what was shown.
    private var offered: [String: UsualEntry] = [:]
    /// The reading line the open menu offered to copy, so Copy Reading copies what its tooltip said.
    private var copyLine: String?
    /// Run once Copy Reading has put the line on the clipboard: the item says "Copied" briefly.
    private let didCopy: () -> Void

    init(store: GlucoseStore, settings: AppSettings, willOpen: @escaping () -> Void,
         didCopy: @escaping () -> Void = {}) {
        self.store = store
        self.settings = settings
        self.willOpen = willOpen
        self.didCopy = didCopy
        super.init()
    }

    /// Starts watching for the click. Cheap to call again.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            let swallow = MainActor.assumeIsolated { self?.take(event) ?? false }
            return swallow ? nil : event
        }
    }

    /// True (the click is swallowed) when it was a menu click on the status bar button.
    private func take(_ event: NSEvent) -> Bool {
        let click: MenuBarQuickMenu.Click = event.type == .rightMouseDown ? .secondary : .primary
        guard MenuBarQuickMenu.opensMenu(click, control: event.modifierFlags.contains(.control)),
              let button = StatusItemToolTip.button(), let window = button.window,
              event.window === window,
              button.bounds.contains(button.convert(event.locationInWindow, from: nil)) else { return false }
        // The menu runs its own loop; start it once this event has been handled.
        DispatchQueue.main.async { [weak self, weak button] in
            guard let self, let button else { return }
            self.show(under: button)
        }
        return true
    }

    // MARK: Menu

    private func show(under button: NSStatusBarButton) {
        guard let window = button.window else { return }
        willOpen()
        let menu = makeMenu()
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        button.highlight(true)
        // With no view the point is on screen: the menu's top-left corner, just under the item.
        menu.popUp(positioning: nil, at: NSPoint(x: anchor.minX, y: anchor.minY - 2), in: nil)
        button.highlight(false)
    }

    private func makeMenu() -> NSMenu {
        let usuals = store.logbook.map {
            PopoverUsualRow.entries(logbook: $0, store: store, settings: settings)
        } ?? []
        offered = Dictionary(usuals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let menu = NSMenu(title: "GlucOS")
        menu.autoenablesItems = false
        copyLine = store.readingCopyText()
        for row in MenuBarQuickMenu.rows(usuals: usuals, copyLine: copyLine) {
            switch row {
            case .header(let title):
                menu.addItem(NSMenuItem.sectionHeader(title: title))
            case .separator:
                menu.addItem(.separator())
            case .item(let item):
                menu.addItem(menuItem(item))
            }
        }
        return menu
    }

    private func menuItem(_ item: MenuBarQuickMenu.Item) -> NSMenuItem {
        let m = NSMenuItem(title: item.title, action: #selector(pick(_:)), keyEquivalent: item.key ?? "")
        m.target = self
        m.representedObject = Box(item.action)
        m.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
        m.keyEquivalentModifierMask = item.withOption ? [.command, .option] : [.command]
        m.toolTip = item.toolTip
        if case .usual(let id) = item.action, let u = offered[id] {
            m.setAccessibilityLabel(u.spokenLabel)
            m.setAccessibilityHelp(MenuBarQuickMenu.usualToolTip)
        }
        return m
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let action = (sender.representedObject as? Box)?.action else { return }
        switch action {
        case .usual(let id):
            // Logging opens its own small window, filled in; it's logged there with Log.
            guard let u = offered[id] else { return }
            LogWindowRequest.shared.target = .usual(u)
            NotificationCenter.default.post(name: .glucosOpenLogWindow, object: nil)
        case .newEntry:
            LogWindowRequest.shared.target = .new
            NotificationCenter.default.post(name: .glucosOpenLogWindow, object: nil)
        case .openLogbook:
            DashboardRequest.shared.opensLogbook = true
            NotificationCenter.default.post(name: .glucosOpenDashboard, object: nil)
        case .copyReading:
            // The same line ⌘C copies in the popover, in the unit on screen. One "Copied" in the
            // menu bar item and one VoiceOver announcement, as the popover's toast does.
            guard let line = copyLine ?? store.readingCopyText() else { break }
            ReadingClipboard.copy(line)
            didCopy()
            VoiceOver.announce(ReadingCopy.copiedToast)
        case .settings:
            NotificationCenter.default.post(name: .glucosOpenSettings, object: nil)
        }
        offered = [:]
        copyLine = nil
    }

    /// `representedObject` takes an object; the action is a Swift enum.
    private final class Box {
        let action: MenuBarQuickMenu.Action
        init(_ action: MenuBarQuickMenu.Action) { self.action = action }
    }
}
