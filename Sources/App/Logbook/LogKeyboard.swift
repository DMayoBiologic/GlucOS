import Foundation

/// Keyboard rules for logging on the Mac (docs/KeyboardLogging.md): moving through the "What's
/// happening?" tiles with the arrow keys, what Return and Space do there, the optional
/// shortcut that opens the log window from any app, and the ⌘? shortcut lists. Plain Foundation,
/// so it's unit-tested; the views and the system hot key live in the app.
enum LogKeyboard {
    enum Direction: Sendable { case left, right, up, down }

    /// The tile the highlight moves to in a grid of `count` tiles, `columns` wide, filled row by
    /// row. Left and right run along the list, so → on the end of a row goes to the start of the
    /// next one. Up and down keep the column; down onto a short last row lands on its last tile.
    /// The highlight never wraps off either end. With nothing highlighted yet, any arrow starts
    /// on the first tile.
    static func move(from index: Int?, _ direction: Direction, count: Int, columns: Int) -> Int? {
        guard count > 0 else { return nil }
        let columns = max(1, columns)
        guard let index, (0..<count).contains(index) else { return 0 }
        switch direction {
        case .left: return max(0, index - 1)
        case .right: return min(count - 1, index + 1)
        case .up: return index - columns >= 0 ? index - columns : index
        case .down:
            if index + columns < count { return index + columns }
            let lastRow = (count - 1) / columns
            return index / columns < lastRow ? count - 1 : index
        }
    }

    /// What a key does on a highlighted tile.
    enum TileAction: Equatable, Sendable {
        /// Turn the moment on, or off. The highlight stays in the tiles.
        case toggle
        /// Turn the moment on and go on to the part it opened (the carbs or units field).
        case pickAndContinue
        /// The entry is ready: log it, as the Log button would.
        case log
        case nothing
    }

    /// Space turns a tile on or off and stays, for picking several moments. Return picks the
    /// moment and moves on to fill it in. Return on a tile that's already on means "that's it":
    /// it logs when the entry can be logged, so "Woke up", Return, Return logs a wake-up.
    static func action(return isReturn: Bool, tileIsOn: Bool, opensPart: Bool, canLog: Bool) -> TileAction {
        guard isReturn else { return .toggle }
        if tileIsOn { return canLog ? .log : .nothing }
        return opensPart ? .pickAndContinue : .toggle
    }
}

// MARK: - Your usual

/// One-tap repeats from the keyboard (docs/UsualEntries.md): ⌥⌘1, ⌥⌘2 and ⌥⌘3 fill in the first
/// three "Your usual" entries, in the order they're shown, in the log sheet and from the menu bar
/// popover. ⌥⌘ so they never clash with ⌘1–⌘9 (moments in the sheet, chart range in the popover).
/// A key only ever fills the entry in; it's logged with Log, after the same checks as a click.
enum UsualKeys {
    /// How many entries get a key. The sheet rarely offers more than three.
    static let limit = 3

    /// The digit for the entry at `index`, or nil past the limit.
    static func digit(for index: Int) -> Character? {
        guard (0..<limit).contains(index) else { return nil }
        return Character(String(index + 1))
    }

    /// "⌥⌘1" for the first entry, nil past the limit.
    static func display(for index: Int) -> String? {
        digit(for: index).map { "⌥⌘\($0)" }
    }

    /// "Option Command 1", for VoiceOver.
    static func spoken(for index: Int) -> String? {
        digit(for: index).map { "Option Command \($0)" }
    }

    /// The keys for `count` entries, as a ⌘? row shows them: "⌥⌘1", "⌥⌘1 – ⌥⌘3". Nil for none.
    static func range(count: Int) -> String? {
        let last = min(count, limit)
        guard last > 0 else { return nil }
        return last == 1 ? "⌥⌘1" : "⌥⌘1 – ⌥⌘\(last)"
    }
}

// MARK: - Global shortcut

/// A key combination for the "open the log window from anywhere" shortcut. Stored by key code,
/// so it means the same physical key whatever the keyboard layout; `key` is what the key typed
/// when it was recorded, for showing it.
struct LogHotKey: Codable, Equatable, Sendable {
    struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
    }

    var keyCode: UInt16
    var modifiers: Modifiers
    /// The key's character as recorded ("L"), or a name for keys that type nothing ("Space").
    var key: String

    /// ⌃⌥⌘L: hard to press by accident and not used by macOS or common apps.
    static let suggested = LogHotKey(keyCode: 37, modifiers: [.control, .option, .command], key: "L")

    /// The modifier symbols in Apple's order, then the key: "⌃⌥⌘L".
    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + key.uppercased()
    }

    /// Spoken form for VoiceOver: "Control Option Command L".
    var spoken: String {
        var words: [String] = []
        if modifiers.contains(.control) { words.append("Control") }
        if modifiers.contains(.option) { words.append("Option") }
        if modifiers.contains(.shift) { words.append("Shift") }
        if modifiers.contains(.command) { words.append("Command") }
        return (words + [key.uppercased()]).joined(separator: " ")
    }

    /// Why a recorded combination can't be used, or nil when it can. Typing in any app must never
    /// open the log window, and the shortcut mustn't take one other apps rely on: it needs two
    /// modifier keys, one of them ⌘ or ⌃ (⌘L alone is every browser's address bar, ⌃A the start
    /// of a line), and can't be one macOS keeps for itself.
    var problem: String? {
        guard modifiers.contains(.command) || modifiers.contains(.control) else {
            return "Include ⌘ or ⌃, so typing never opens the log window."
        }
        let count = [Modifiers.control, .option, .shift, .command].filter(modifiers.contains).count
        guard count >= 2 else {
            return "Add another modifier key: other apps use \(display)."
        }
        if modifiers.contains(.command), key == "Space" || key == "Tab" {
            return "macOS uses \(display) itself."
        }
        if modifiers == [.command, .shift], Self.shiftCommandKeys.contains(key.uppercased()) {
            return "\(display) is used by macOS or most apps. Try ⌃⌥⌘ instead."
        }
        return nil
    }

    /// ⇧⌘ shortcuts macOS or almost every app uses: screenshots, redo, save as, new folder…
    private static let shiftCommandKeys: Set<String> = ["3", "4", "5", "6", "Z", "S", "N", "T", "G", "A", "O", "/"]
}

// MARK: - Shortcut lists

/// One row of a ⌘? list: the keys and what they do.
struct ShortcutRow: Equatable, Sendable {
    let keys: String
    let action: String
}

/// One group of rows in a ⌘? list.
struct ShortcutGroup: Equatable, Sendable {
    let title: String
    let rows: [ShortcutRow]
}

/// The shortcut lists ⌘? shows: in the menu bar popover, in the log sheet and in the dashboard.
/// Each list leads with the place it's shown in, then logging, so the rows read the same
/// wherever they appear. `globalKey` is the "open from anywhere" shortcut when it's turned on.
enum ShortcutCatalog {
    static let showList = ShortcutRow(keys: "⌘?", action: "Show this list")
    /// ⌘L in the popover while its Log treatment button shows (docs/AlertActions.md).
    static let lowTreatment = ShortcutRow(keys: "⌘L during a low", action: "Log treatment, filled in from Treat a low")

    static func popover(globalKey: LogHotKey?) -> [ShortcutGroup] {
        [
            ShortcutGroup(title: "Menu bar", rows: [
                ShortcutRow(keys: "⌘L", action: "Log insulin, food or a moment"),
                lowTreatment,
                ShortcutRow(keys: UsualKeys.range(count: UsualKeys.limit) ?? "", action: "Fill in one of Your usual, in the log window"),
                ShortcutRow(keys: "⌘R", action: "Refresh"),
                ShortcutRow(keys: "⌘D", action: "Open the dashboard"),
                ShortcutRow(keys: "⌘1  ⌘2  ⌘3  ⌘4", action: "Chart: 3, 6, 12 or 24 hours"),
                ShortcutRow(keys: "⌘+  ⌘−", action: "Chart: fewer or more hours"),
                ShortcutRow(keys: "←  → on the chart", action: "Step through chart readings"),
                ShortcutRow(keys: "⌘I", action: "Show or hide details"),
                ShortcutRow(keys: "⌘C", action: "Copy the reading"),
                ShortcutRow(keys: "⌘,", action: "Settings"),
                ShortcutRow(keys: "Hold ⌘", action: "Show shortcuts on the buttons"),
                showList,
            ]),
            navigation(escape: "Esc", closes: "the popover, or this list"),
            anywhere(globalKey),
        ].compactMap { $0 }
    }

    /// `usualCount` is how many "Your usual" entries the sheet is offering.
    static func logSheet(momentCount: Int, usualCount: Int = 0, globalKey: LogHotKey?) -> [ShortcutGroup] {
        [logging(momentCount: momentCount, usualCount: usualCount), anywhere(globalKey)].compactMap { $0 }
    }

    static func dashboard(globalKey: LogHotKey?) -> [ShortcutGroup] {
        [
            ShortcutGroup(title: "Dashboard", rows: [
                ShortcutRow(keys: "⌘1 – ⌘8", action: "Switch section"),
                ShortcutRow(keys: "⌃1 – ⌃8", action: "Pick a time range"),
                ShortcutRow(keys: "⌘[  ⌘]", action: "Previous or next period"),
                ShortcutRow(keys: "⌘J", action: "Back to now (in the Logbook: jump to a date)"),
                ShortcutRow(keys: "⌘=  ⌘−  ⌘0", action: "Zoom chart in, out, reset"),
                ShortcutRow(keys: "⌥←  ⌥→", action: "Pan the zoomed chart"),
                ShortcutRow(keys: "Drag on chart", action: "Select a stretch to see its numbers"),
                ShortcutRow(keys: "Esc", action: "Clear the chart selection"),
                ShortcutRow(keys: "⌘L", action: "Log insulin, food or a moment"),
                ShortcutRow(keys: "⌘F", action: "Search the Logbook (\u{201C}pizza last week\u{201D})"),
                ShortcutRow(keys: "Esc in the search", action: "Clear the search and filters"),
                ShortcutRow(keys: "⌘R", action: "Refresh"),
                ShortcutRow(keys: "⌃⌘F", action: "Enter or exit full screen"),
                ShortcutRow(keys: "⇧⌘P", action: "Export report as PDF"),
                ShortcutRow(keys: "⇧⌘E", action: "Export the Logbook for a clinic visit"),
                ShortcutRow(keys: "⌘/  ⌘?", action: "Show this list"),
            ]),
            navigation(escape: "Esc in a sheet", closes: "the sheet"),
            anywhere(globalKey),
        ].compactMap { $0 }
    }

    /// The log sheet's own keys. `momentCount` is how many moments the therapy type offers,
    /// `usualCount` how many "Your usual" entries are offered right now.
    static func logging(momentCount: Int, usualCount: Int = 0) -> ShortcutGroup {
        var rows = [
            ShortcutRow(keys: "←  →  ↑  ↓", action: "Move between the moments"),
            ShortcutRow(keys: "Return", action: "Pick the moment and fill it in"),
            ShortcutRow(keys: "Space", action: "Turn a moment on or off, to pick several"),
        ]
        if momentCount > 0 {
            let last = min(momentCount, 9)
            rows.append(ShortcutRow(keys: last == 1 ? "⌘1" : "⌘1 – ⌘\(last)", action: "Turn a moment on or off from anywhere in the sheet"))
        }
        if let keys = UsualKeys.range(count: usualCount) {
            rows.append(ShortcutRow(keys: keys, action: "Fill in one of Your usual"))
        }
        rows += [
            ShortcutRow(keys: "⌘F", action: "Search foods"),
            ShortcutRow(keys: "Return in a field", action: "Log, once the entry is ready"),
            ShortcutRow(keys: "Esc", action: "Cancel"),
            showList,
        ]
        return ShortcutGroup(title: "Logging", rows: rows)
    }

    /// Moving round with the keyboard (docs/KeyboardNavigation.md): the same in the popover,
    /// Insights and the Logbook. `escape` and `closes` say what Esc does where the list is shown
    /// (the dashboard's own Esc clears the chart selection).
    static func navigation(escape: String, closes: String) -> ShortcutGroup {
        ShortcutGroup(title: "Moving around", rows: [
            ShortcutRow(keys: "Tab  ⇧Tab", action: "Next or previous card or control"),
            ShortcutRow(keys: "↑  ↓  ←  →", action: "Move between cards, rows and buttons"),
            ShortcutRow(keys: "Return  Space", action: "Open or press what has the focus ring"),
            ShortcutRow(keys: escape, action: "Close \(closes)"),
        ])
    }

    /// Every list at once, for Settings → Logging → Keyboard → Keyboard Shortcuts.
    static func all(momentCount: Int, globalKey: LogHotKey?) -> [ShortcutGroup] {
        let popoverRows = popover(globalKey: nil).first?.rows ?? []
        let dashboardRows = dashboard(globalKey: nil).first?.rows ?? []
        return [
            navigation(escape: "Esc", closes: "a sheet, or the popover"),
            ShortcutGroup(title: "Menu bar", rows: popoverRows.filter { $0 != showList }),
            ShortcutGroup(title: "Dashboard", rows: dashboardRows.filter { $0.keys != "⌘/  ⌘?" }),
            logging(momentCount: momentCount),
            anywhere(globalKey),
        ].compactMap { $0 }
    }

    private static func anywhere(_ key: LogHotKey?) -> ShortcutGroup? {
        guard let key else { return nil }
        return ShortcutGroup(title: "From any app", rows: [
            ShortcutRow(keys: key.display, action: "Open the log window"),
        ])
    }
}
