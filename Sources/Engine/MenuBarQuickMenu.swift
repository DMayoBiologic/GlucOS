import Foundation

// The menu bar item's own menu (docs/MenuBarMenu.md). Right-click or Control-click the reading and
// a small menu drops down with Your usual (the same up to three repeats the popover row offers),
// then Log Something…, Open Logbook, Copy Reading (while there is a reading) and Settings…. A plain
// click still opens the popover.
//
// Picking a usual opens the log window filled in from it. Nothing is ever logged from the menu:
// the entry is logged with Log in that window, after `RepeatCheck` ("Already logged?") and, for a
// dose, the calculator's confirm step, exactly as from the popover row.
//
// This file is the plain part, engine-tested: which clicks open the menu and what it holds. The
// AppKit side is MenuBarQuickMenuController in Sources/App/Views/MenuBar.

enum MenuBarQuickMenu {
    /// Which mouse button went down on the item.
    enum Click: Equatable, Sendable {
        case primary
        case secondary
    }

    /// A right click, or a left click with Control held, opens the menu. Any other click is left
    /// alone, so it opens the popover as before.
    static func opensMenu(_ click: Click, control: Bool) -> Bool {
        click == .secondary || control
    }

    enum Action: Hashable, Sendable {
        /// Opens the log window filled in from the usual with this id (`UsualEntry.id`).
        case usual(id: String)
        /// Opens the log window on a new entry.
        case newEntry
        /// Opens the dashboard on the Logbook.
        case openLogbook
        /// Copies the current reading as one line (`ReadingCopy`), as ⌘C does in the popover.
        case copyReading
        case settings
    }

    struct Item: Hashable, Sendable, Identifiable {
        let action: Action
        let title: String
        let symbol: String
        /// The key shown beside it ("1" with ⌥⌘ for a usual, "," with ⌘ for Settings).
        let key: String?
        /// The key needs Option as well as Command.
        let withOption: Bool
        /// Shown when the pointer rests on the item.
        let toolTip: String?

        var id: Action { action }
    }

    enum Row: Hashable, Sendable {
        case header(String)
        case item(Item)
        case separator
    }

    static let usualHeader = "Your usual"
    static let usualToolTip = "Opens the log window filled in. Check it, then log. Nothing is logged until you do."

    /// Longest a usual's line gets before it is cut with "…", so one long food name can't make
    /// the menu as wide as the screen.
    static let maxTitleLength = 44

    static let copyTitle = "Copy Reading"

    /// How long the menu bar item shows "Copied" after Copy Reading, before the reading comes back.
    static let copiedDuration: TimeInterval = 1.2

    /// Copy Reading's tooltip: the line it puts on the clipboard, so it can be checked first.
    static func copyToolTip(_ line: String) -> String { "Copies \u{201C}\(line)\u{201D}" }

    /// The menu, top to bottom. `usuals` are what the popover row offers now (already empty
    /// before the therapy type is set); only the first `usualLimit` are shown. `copyLine` is the
    /// current reading as `ReadingCopy` writes it; Copy Reading is left out when it is nil.
    static func rows(usuals: [UsualEntry], copyLine: String? = nil, usualLimit: Int = 3) -> [Row] {
        var rows: [Row] = []
        let shown = usuals.prefix(max(0, usualLimit))
        if !shown.isEmpty {
            rows.append(.header(usualHeader))
            for (index, u) in shown.enumerated() {
                rows.append(.item(Item(action: .usual(id: u.id), title: title(for: u), symbol: u.systemImage,
                                       key: String(index + 1), withOption: true, toolTip: usualToolTip)))
            }
            rows.append(.separator)
        }
        rows.append(.item(Item(action: .newEntry, title: "Log Something…", symbol: "plus.circle",
                               key: nil, withOption: false, toolTip: "Opens the log window on a new entry.")))
        rows.append(.item(Item(action: .openLogbook, title: "Open Logbook", symbol: "book.closed",
                               key: nil, withOption: false, toolTip: nil)))
        if let copyLine, !copyLine.isEmpty {
            rows.append(.item(Item(action: .copyReading, title: copyTitle, symbol: "doc.on.doc",
                                   key: "c", withOption: false, toolTip: copyToolTip(copyLine))))
        }
        rows.append(.separator)
        rows.append(.item(Item(action: .settings, title: "Settings…", symbol: "gearshape",
                               key: ",", withOption: false, toolTip: nil)))
        return rows
    }

    /// "Usual breakfast: Toast and banana · 45 g", "Treat a low: Jelly beans · 15 g",
    /// "Usual correction: 2 u NovoRapid". Just the title when there is nothing to add.
    static func title(for u: UsualEntry) -> String {
        let full = u.detail.isEmpty ? u.title : "\(u.title): \(u.detail)"
        guard full.count > maxTitleLength else { return full }
        return String(full.prefix(maxTitleLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
