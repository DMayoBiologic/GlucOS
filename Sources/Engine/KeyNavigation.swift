import Foundation

// Keyboard navigation on the Mac (docs/KeyboardNavigation.md): Tab and the arrow keys move a
// visible focus ring through the menu bar popover, Insights and the Logbook; Return or Space
// does what a click would; Esc closes the sheet or the popover. The views register their focus
// stops in screen order (a preference), and the rules for where the ring goes live here, free of
// SwiftUI, so they're unit-tested.

/// One place the focus ring can land: a card, a chip, a button. `row` groups stops that sit side
/// by side (the toolbar's buttons, the two sides of the Weekdays and weekends card), so ← and →
/// move along it and ↑ and ↓ move between rows.
struct KeyStop: Equatable, Hashable, Sendable {
    let id: String
    let row: String
    /// The card this stop sits in (a side of Weekdays and weekends), if any.
    var parent: String?

    init(_ id: String, row: String? = nil, parent: String? = nil) {
        self.id = id
        self.row = row ?? id
        self.parent = parent
    }

    /// The stops inside a card, in layout order, owned by it: the card goes first, then each of
    /// them that isn't inside something nearer.
    static func card(_ card: KeyStop, holding inside: [KeyStop]) -> [KeyStop] {
        [card] + inside.map { stop in
            var stop = stop
            if stop.parent == nil { stop.parent = card.id }
            return stop
        }
    }
}

enum KeyNavigation {
    enum Move: Sendable, Equatable {
        case up, down, left, right
    }

    /// Stops in screen order, grouped into rows: neighbouring stops with the same `row` make one
    /// row. A stop listed twice (a view drawn twice in a layout pass) keeps its first place.
    static func rows(_ stops: [KeyStop]) -> [[String]] {
        var seen = Set<String>()
        var out: [[String]] = []
        var lastRow: String?
        for stop in stops where seen.insert(stop.id).inserted {
            if stop.row == lastRow, !out.isEmpty {
                out[out.count - 1].append(stop.id)
            } else {
                out.append([stop.id])
            }
            lastRow = stop.row
        }
        return out
    }

    /// Reading order: every stop, row by row, left to right. It's the order Tab goes in (the
    /// system's key loop follows the layout), so the views register their stops in layout order.
    static func order(_ stops: [KeyStop]) -> [String] {
        rows(stops).flatMap { $0 }
    }

    /// Where the ring goes from `current`, or nil to leave the key alone (so the popover's chart,
    /// a text field or the system still get it).
    ///
    /// - ↑ and ↓ go to the row above or below, to the stop nearest the same place along it. They
    ///   never wrap: ↓ on the last row is left alone.
    /// - ← and → move along a row and stop at its ends.
    /// - With focus somewhere that isn't a stop (a text field, a system control) the key is left
    ///   alone, so it never yanks the cursor out of a field.
    static func target(from current: String?, _ move: Move, in stops: [KeyStop]) -> String? {
        let rows = rows(stops)
        guard let current, let r = rows.firstIndex(where: { $0.contains(current) }),
              let c = rows[r].firstIndex(of: current) else { return nil }
        switch move {
        case .left:
            return c > 0 ? rows[r][c - 1] : nil
        case .right:
            return c < rows[r].count - 1 ? rows[r][c + 1] : nil
        case .up, .down:
            let to = move == .up ? r - 1 : r + 1
            guard rows.indices.contains(to) else { return nil }
            return rows[to][nearest(column: c, of: rows[r].count, in: rows[to].count)]
        }
    }

    /// Return on a card that has nothing of its own to do goes into it: to the first thing inside
    /// (the Lows card's "in the Logbook" line, the weekday side of Weekdays and weekends). Nil
    /// for a card with nothing inside.
    static func firstInside(_ card: String, in stops: [KeyStop]) -> String? {
        order(stops.filter { $0.parent == card }).first
    }

    /// The stop in a row of `count` nearest the place `column` has in a row of `from` stops: the
    /// right side of Weekdays and weekends goes up to the right-hand toolbar button, not the first.
    static func nearest(column: Int, of from: Int, in count: Int) -> Int {
        guard count > 1, from > 1 else { return 0 }
        let place = Double(column) / Double(from - 1)
        return min(count - 1, max(0, Int((place * Double(count - 1)).rounded())))
    }
}

/// When the ring shows. Like a web page's `:focus-visible`: the keyboard brings it up, a click
/// puts it away, so clicking a card never leaves a ring round it. Kept apart from the views for
/// the tests.
enum FocusRingVisibility {
    enum Input: Sendable, Equatable {
        /// A key press, by its macOS key code.
        case key(UInt16)
        case click
    }

    /// Tab, the arrow keys, Home, End, Page Up and Page Down.
    static let navigationKeyCodes: Set<UInt16> = [48, 123, 124, 125, 126, 115, 119, 116, 121]

    /// True or false when `input` changes whether the ring shows, nil when it leaves it be (typing
    /// in a field, Return, a shortcut).
    static func after(_ input: Input, modifiers commandOrControl: Bool = false) -> Bool? {
        switch input {
        case .click: return false
        case .key(let code):
            // ⌘← and friends are shortcuts (Insights' periods, the chart), not moving the ring.
            guard !commandOrControl, navigationKeyCodes.contains(code) else { return nil }
            return true
        }
    }
}
