import Foundation

// "Meal 1 h 40 m ago · 45 g": a quiet line under the chart on iPhone Today and in the Mac popover,
// saying what was logged last and how long ago (docs/Redesign.md §7.1 and §8.2). Tapping it opens that entry
// in the Logbook. It repeats only what was logged: no insulin on board, no carbs left, no other
// working out from it. Plain Foundation so `swift test` covers it.

/// The newest logbook entry in the last 12 hours, as one line.
struct LastLogged: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case meal, dose, site, event
    }

    let entryID: UUID
    let kind: Kind
    let timestamp: Date
    /// "Meal", "Dose", "Site change", or the event's tags ("Exercise").
    let title: String
    /// What was logged with it ("45 g", "4 u"), or nil when there's nothing short to say.
    let detail: String?

    /// Older than this and the line goes: by then the chart's markers say more than "13 h ago".
    static let window: TimeInterval = 12 * 3600
    /// A clock a little ahead of the device that logged it (a synced entry) still reads "just now",
    /// but anything further ahead is a planned or mistyped time, not the last thing logged.
    static let futureSlack: TimeInterval = 120

    /// The newest entry logged in the last 12 hours, or nil when there isn't one.
    static func latest(_ entries: [LogEntry], now: Date) -> LastLogged? {
        let earliest = now.addingTimeInterval(-window)
        let latest = now.addingTimeInterval(futureSlack)
        // Ties (a meal and its dose logged together) go to the one listed first, as the Logbook does.
        var best: LogEntry?
        // A sensor start GlucOS logged by itself isn't something the user logged.
        for e in entries where e.timestamp >= earliest && e.timestamp <= latest && !e.isSensorStart {
            if best == nil || e.timestamp > best!.timestamp { best = e }
        }
        return best.map { LastLogged($0) }
    }

    init(_ entry: LogEntry) {
        entryID = entry.id
        timestamp = entry.timestamp
        switch entry {
        case .meal(let m):
            kind = .meal
            title = "Meal"
            if m.carbs > 0 {
                detail = LogFormat.grams(m.carbs)
            } else {
                let food = m.food.trimmingCharacters(in: .whitespacesAndNewlines)
                detail = food.isEmpty ? nil : food
            }
        case .dose(let d):
            kind = .dose
            title = "Dose"
            detail = LogFormat.units(d.units)
        case .siteChange(let s):
            kind = .site
            title = "Site change"
            detail = s.site.title
        case .context(let c):
            kind = .event
            let tags = c.sortedTags.map(\.title)
            title = tags.isEmpty ? "Note" : tags.joined(separator: ", ")
            detail = nil
        }
    }

    /// "Meal 1 h 40 m ago · 45 g", "Dose 25 m ago · 4 u", "Exercise just now".
    func text(now: Date) -> String {
        let head = "\(title) \(Self.ago(now.timeIntervalSince(timestamp)))"
        guard let detail else { return head }
        return "\(head) · \(detail)"
    }

    /// For VoiceOver: "Last logged: meal, 1 hour 40 minutes ago, 45 grams".
    func spoken(now: Date) -> String {
        var parts = ["Last logged: \(title.lowercased())", Self.spokenAgo(now.timeIntervalSince(timestamp))]
        if let detail { parts.append(Self.spokenDetail(detail)) }
        return parts.joined(separator: ", ")
    }

    /// Whole minutes, rounded down, so the line ticks over on the minute rather than early.
    /// "just now" under a minute (and for a clock slightly ahead), "25 m ago", "1 h ago",
    /// "1 h 40 m ago".
    static func ago(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) m ago" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h ago" : "\(h) h \(m) m ago"
    }

    static func spokenAgo(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 1 { return "just now" }
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if minutes < 60 { return "\(unit(minutes, "minute")) ago" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(unit(h, "hour")) ago" : "\(unit(h, "hour")) \(unit(m, "minute")) ago"
    }

    /// "45 g" → "45 grams", "4 u" → "4 units"; anything else as written.
    private static func spokenDetail(_ detail: String) -> String {
        if detail.hasSuffix(" g") { return String(detail.dropLast(2)) + " grams" }
        if detail.hasSuffix(" u") {
            let n = String(detail.dropLast(2))
            return n + (n == "1" ? " unit" : " units")
        }
        return detail
    }
}
