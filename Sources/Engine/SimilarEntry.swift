import Foundation

// "You logged a similar meal 3 min ago · View" (docs/SimilarEntry.md). While a new meal or dose is
// being filled in, the log sheet checks the last 10 minutes of the logbook for the same kind of
// entry with about the same amount: the same meal said to Siri and then typed into the app, or
// logged on the iPhone and then on the Mac. If there is one, the sheet shows one quiet line above
// Log, and View shows that entry in place. It's only a note: it never blocks saving, never changes
// an amount, never deletes anything, and isn't shown to followers.
//
// It sits before the save, alongside two checks that already existed: `RepeatCheck` ("Already
// logged?", asked at Log, only for one-tap fills) and `DoubleLog` ("Logged twice?" with Undo on the
// toast, after saving). This one covers entries typed in by hand, and says so while typing.

enum SimilarEntry {
    /// Only entries logged for the last this long (and this close to the new entry's time) count.
    static let window: TimeInterval = 10 * 60
    /// An entry timed this far ahead of now still counts as just logged (another device's clock).
    static let clockSlack: TimeInterval = 60
    /// Doses within this many units (or `share` of the larger) are about the same.
    static let unitsSlack = 0.5
    /// Meals within this many grams of carbs (or `share` of the larger) are about the same.
    static let carbsSlack = 5.0
    static let share = 0.10

    /// What the line is about.
    enum Kind: String, Equatable, Sendable {
        case meal, dose
        case mealAndDose = "meal and dose"
    }

    struct Match: Equatable {
        /// The earlier entry View shows: the most recent one when a meal and a dose both match.
        var entry: LogEntry
        var kind: Kind
        /// Whole minutes since `entry` was logged, 0 for under a minute.
        var minutes: Int

        /// "You logged a similar meal 3 min ago". "just now" under a minute.
        var line: String {
            "You logged a similar \(kind.rawValue) \(minutes == 0 ? "just now" : "\(minutes) min ago")"
        }

        /// What VoiceOver reads for the line, with the minutes spelled out.
        var spoken: String {
            let span = minutes == 0 ? "just now" : (minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago")
            return "You logged a similar \(kind.rawValue) \(span)"
        }
    }

    /// The earlier entry the meal and dose being logged (`drafts`) look like, or nil. Only meals
    /// and doses with an amount are checked, only against entries of the same kind timed within the
    /// last `window` of `now` and within `window` of the draft, and the closest in time wins.
    /// Nothing in `excluding` (the draft's own ids, or the entry being edited) is ever a match.
    /// Always nil for a follower: their logbook is someone else's.
    static func match(for drafts: [LogEntry], in entries: [LogEntry], now: Date,
                      excluding: Set<UUID> = [], isFollower: Bool = false) -> Match? {
        guard !isFollower else { return nil }
        let skip = excluding.union(drafts.map(\.id))
        let recent = entries.filter { e in
            !skip.contains(e.id) && DoubleLog.checks(e)
                && e.timestamp <= now.addingTimeInterval(clockSlack)
                && now.timeIntervalSince(e.timestamp) <= window
        }
        var found: [(draft: LogEntry, earlier: LogEntry)] = []
        for draft in drafts where hasAmount(draft) {
            let near = recent.filter { abs($0.timestamp.timeIntervalSince(draft.timestamp)) <= window && similar($0, draft) }
            if let best = near.min(by: { abs($0.timestamp.timeIntervalSince(draft.timestamp)) < abs($1.timestamp.timeIntervalSince(draft.timestamp)) }) {
                found.append((draft, best))
            }
        }
        guard let latest = found.map(\.earlier).max(by: { $0.timestamp < $1.timestamp }) else { return nil }
        let kinds = Set(found.map { kindOf($0.draft) })
        let kind: Kind = kinds.count > 1 ? .mealAndDose : (kinds.first ?? .meal)
        let minutes = max(0, Int(now.timeIntervalSince(latest.timestamp) / 60))
        return Match(entry: latest, kind: kind, minutes: minutes)
    }

    /// A dose with units, or a meal with carbs or a food named.
    static func hasAmount(_ entry: LogEntry) -> Bool {
        switch entry {
        case .dose(let d): return d.units > 0
        case .meal(let m): return m.carbs > 0 || !DoubleLog.foodKey(m.food).isEmpty
        case .siteChange, .context: return false
        }
    }

    /// The same kind of entry with about the same amount. A dose must be the same kind of insulin
    /// (and the same insulin, when both name one). A meal must have about the same carbs (and the
    /// same food, when both name one); a meal with no carbs matches only the same food with none.
    static func similar(_ a: LogEntry, _ b: LogEntry) -> Bool {
        switch (a, b) {
        case (.dose(let x), .dose(let y)):
            guard x.kind == y.kind, x.units > 0, y.units > 0, close(x.units, y.units, slack: unitsSlack) else { return false }
            let kx = DoubleLog.nameKey(x.name), ky = DoubleLog.nameKey(y.name)
            return kx.isEmpty || ky.isEmpty || kx == ky
        case (.meal(let x), .meal(let y)):
            let fx = DoubleLog.foodKey(x.food), fy = DoubleLog.foodKey(y.food)
            let sameFood = fx.isEmpty || fy.isEmpty || fx == fy
            if x.carbs <= 0 || y.carbs <= 0 {
                return x.carbs <= 0 && y.carbs <= 0 && !fx.isEmpty && fx == fy
            }
            return sameFood && close(x.carbs, y.carbs, slack: carbsSlack)
        default:
            return false
        }
    }

    static func close(_ a: Double, _ b: Double, slack: Double) -> Bool {
        abs(a - b) <= max(slack, share * max(abs(a), abs(b))) + 1e-9
    }

    private static func kindOf(_ entry: LogEntry) -> Kind {
        if case .dose = entry { return .dose }
        return .meal
    }

    /// What View shows of the earlier entry: "12:41 · 45 g · Toast".
    static func detail(_ entry: LogEntry, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        style.locale = locale
        return "\(entry.timestamp.formatted(style)) · \(entry.shortTitle)"
    }
}
