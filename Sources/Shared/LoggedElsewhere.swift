import Foundation

/// Where an entry was logged from, when it wasn't the Logbook or the log bar: Siri or Shortcuts,
/// a Control Center control, the in-app alert banner, a notification's button, a widget, a Home
/// Screen quick action or the Mac's keyboard shortcut. Only the app that logged it knows; nothing about it is saved or synced.
enum LogOrigin: String, CaseIterable, Equatable, Sendable {
    case siri, controlCenter, alertBanner, notification, widget, homeScreen, keyboardShortcut

    /// The short caption under the entry, as it first shows: "Logged from Siri".
    var caption: String {
        switch self {
        case .siri: return "Logged from Siri"
        case .controlCenter: return "Logged from Control Center"
        case .alertBanner: return "Logged from the alert"
        case .notification: return "Logged from the notification"
        case .widget: return "Logged from the widget"
        case .homeScreen: return "Logged from the Home Screen"
        case .keyboardShortcut: return "Logged with your shortcut"
        }
    }
}

/// Entries logged from outside the Logbook get one soft highlight, with their caption, the next
/// time their Logbook row and their chart marker appear (docs/LoggedElsewhere.md). Each place
/// shows it once, VoiceOver hears it once for everything saved together, and it's forgotten after
/// `lifetime`. Plain Foundation so it can be unit-tested; `LoggedElsewhere` holds the app's copy.
struct LoggedElsewhereMarks {
    /// The places an entry can be highlighted, each once.
    enum Surface: CaseIterable, Hashable, Sendable {
        /// Its Logbook row: iPhone Today's Logbook card or the full Logbook, the Mac dashboard's table.
        case logbook
        /// Its marker on the chart the user logs against: iPhone Today, the Mac popover.
        case chart
    }

    /// Longer ago than this, an entry isn't news: it appears without a highlight.
    static let lifetime: TimeInterval = 10 * 60
    /// The log sheet holds its checkmark and closes after saving, so a highlight that would start
    /// behind it waits until about this long after the save.
    static let settle: TimeInterval = 1.1

    /// What a row or marker plays.
    struct Highlight: Equatable {
        var origin: LogOrigin
        /// Whether this is the first place to show the save, so VoiceOver hears it here and not again.
        var announces: Bool
        /// How long to wait before playing it, so it isn't spent behind the closing log sheet.
        var delay: TimeInterval
    }

    private struct Mark {
        var origin: LogOrigin
        var loggedAt: Date
        var batch: UUID
        var shown: Set<Surface> = []
    }

    private var marks: [UUID: Mark] = [:]
    private var announced: Set<UUID> = []

    /// Entries saved together from `origin` (a meal and its hypo-treatment tag, a dose and a meal).
    mutating func record(_ ids: [UUID], from origin: LogOrigin, at now: Date) {
        prune(now)
        guard !ids.isEmpty else { return }
        let batch = UUID()
        for id in ids { marks[id] = Mark(origin: origin, loggedAt: now, batch: batch) }
    }

    /// Whether `id` is waiting to be highlighted on `surface`, without using it up.
    func isPending(_ id: UUID, on surface: Surface, at now: Date) -> Bool {
        guard let m = marks[id] else { return false }
        return !m.shown.contains(surface) && now.timeIntervalSince(m.loggedAt) <= Self.lifetime
    }

    /// The highlight for `id` as it appears on `surface`, once. `nil` when it wasn't logged from
    /// elsewhere, has been shown there already, or is too old.
    mutating func take(_ id: UUID, on surface: Surface, at now: Date) -> Highlight? {
        prune(now)
        guard var m = marks[id], !m.shown.contains(surface) else { return nil }
        m.shown.insert(surface)
        marks[id] = m.shown.count == Surface.allCases.count ? nil : m
        let announces = !announced.contains(m.batch)
        announced.insert(m.batch)
        let delay = max(0, min(Self.settle, Self.settle - now.timeIntervalSince(m.loggedAt)))
        return Highlight(origin: m.origin, announces: announces, delay: delay)
    }

    /// The entry went (deleted, undone): nothing left to highlight.
    mutating func forget(_ ids: [UUID]) {
        for id in ids { marks[id] = nil }
    }

    private mutating func prune(_ now: Date) {
        marks = marks.filter { now.timeIntervalSince($0.value.loggedAt) <= Self.lifetime }
        let live = Set(marks.values.map(\.batch))
        announced.formIntersection(live)
    }

    /// What VoiceOver says for a row: "Logged from Siri: 45 g · Toast".
    static func spoken(_ origin: LogOrigin, entry title: String?) -> String {
        guard let title, !title.isEmpty else { return origin.caption }
        return "\(origin.caption): \(title)"
    }

    /// The chart's line when a marker logged from elsewhere pops in: "Meal added to chart, logged
    /// from Siri". Without a pop line (the chart opened onto it), just the caption.
    static func chartSpoken(_ origin: LogOrigin, pop: String?) -> String {
        guard let pop, !pop.isEmpty else { return origin.caption }
        let caption = origin.caption
        return "\(pop), \(caption.prefix(1).lowercased())\(caption.dropFirst())"
    }
}
