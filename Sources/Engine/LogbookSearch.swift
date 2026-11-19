import Foundation

// Searching the Logbook (docs/LogbookSearch.md): "pizza last week", "4 u friday", "notes".
// Everything here works on what's already on the device (the synced logbook and the alert
// records), so search keeps working with no connection.

/// The Logbook's quick filter chips. One at a time, on top of whatever the search says.
enum LogbookFilter: String, CaseIterable, Hashable, Identifiable, Sendable {
    case meals, insulin, lows, highs, overnight, weekdays, weekends, thisWeek, lastWeek, bestStreak, bestDay, toughestDay, tagged, hourOfDay, whileAway, aroundAlert, aroundGap, recentDay, notes, sites, moments, alerts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meals: return "Meals"
        case .insulin: return "Insulin"
        case .lows: return "Lows"
        case .highs: return "Highs"
        case .overnight: return "Overnight"
        case .weekdays: return "Weekdays"
        case .weekends: return "Weekends"
        case .thisWeek: return "This week"
        case .lastWeek: return "Last week"
        case .bestStreak: return "Longest streak"
        case .bestDay: return "Best day"
        case .toughestDay: return "Toughest day"
        case .tagged: return "Tagged"
        case .hourOfDay: return "Hour of day"
        case .whileAway: return "While away"
        case .aroundAlert: return "Around an alert"
        case .aroundGap: return "Around a gap"
        case .recentDay: return "One day"
        case .notes: return "Notes"
        case .sites: return "Sites"
        case .moments: return "Moments"
        case .alerts: return "Alerts"
        }
    }

    /// Whether a logged entry belongs under this chip. `lowIDs` is `LogbookSearch.lowTreatmentIDs`.
    func matches(_ entry: LogEntry, lowIDs: Set<UUID>) -> Bool {
        switch self {
        case .meals: if case .meal = entry { return true } else { return false }
        case .insulin: if case .dose = entry { return true } else { return false }
        case .lows: return lowIDs.contains(entry.id)
        // Insulin marked as a correction: what was logged about a high.
        case .highs: if case .dose(let d) = entry { return d.purpose == .correction } else { return false }
        // Anything logged between midnight and 6 am (the Insights Overnight card's nights).
        case .overnight: return OvernightSummary.isOvernight(entry.timestamp)
        // The Insights Weekdays and weekends card's two sides, by the device's weekend days.
        case .weekdays, .weekends: return matchesWeekPart(entry.timestamp)
        // The Insights Week in review card's two weeks: everything, over the week's own period.
        case .thisWeek, .lastWeek: return true
        // The Insights In-range streaks card's longest run: everything, over the run's own days.
        case .bestStreak: return true
        // The Insights Best and toughest days card's two days: everything, over the day itself.
        case .bestDay, .toughestDay: return true
        // The Insights Tags card: everything, narrowed by the tag chip it opens with.
        case .tagged: return true
        // The Insights Time in range by hour card: everything, narrowed to its hour by the period
        // it opens with (`LogbookQuery.Period.hour`).
        case .hourOfDay: return true
        // The "while you were away" line under the reading: everything, over the span it covers.
        case .whileAway: return true
        // A row of Settings › Alerts › History: everything, over the time around that alert.
        case .aroundAlert: return true
        // The Insights Sensor coverage card's longest gap: everything, over the time around it.
        case .aroundGap: return true
        // A day of the last 7 days card behind the time-in-range figure: everything that day.
        case .recentDay: return true
        case .notes: return !entry.searchNote.isEmpty
        case .sites: if case .siteChange = entry { return true } else { return false }
        case .moments: if case .context = entry { return true } else { return false }
        case .alerts: return false
        }
    }

    /// Whether an alert row belongs under this chip: every alert under Alerts, low ones under Lows,
    /// high ones under Highs, those between midnight and 6 am under Overnight, by the day of the
    /// week under Weekdays and Weekends, and all of them under This week and Last week (the period
    /// does the narrowing).
    func matches(_ alert: AlertLogRow) -> Bool {
        switch self {
        case .alerts: return true
        case .lows: return alert.isLow
        case .highs: return alert.isHigh
        case .overnight: return OvernightSummary.isOvernight(alert.timestamp)
        case .weekdays, .weekends: return matchesWeekPart(alert.timestamp)
        case .thisWeek, .lastWeek, .bestStreak, .bestDay, .toughestDay, .hourOfDay, .whileAway, .aroundAlert, .aroundGap, .recentDay: return true
        default: return false
        }
    }

    private func matchesWeekPart(_ date: Date) -> Bool {
        WeekdayWeekend.side(of: date).filter == self
    }

    /// Whether the chip bar lists this chip by itself. Overnight, Weekdays, Weekends, This week,
    /// Last week, Longest streak, Best day, Toughest day, Tagged, Hour of day, While away, Around an alert, Around a gap and One day show only when a card or line
    /// opens the Logbook on them: they're times, not kinds of entry.
    var isListed: Bool {
        ![.overnight, .weekdays, .weekends, .thisWeek, .lastWeek, .bestStreak, .bestDay, .toughestDay, .tagged, .hourOfDay, .whileAway, .aroundAlert, .aroundGap, .recentDay].contains(self)
    }

    /// The Insights card that opens the Logbook on this chip, where Back on the Mac scrolls to:
    /// both Weekdays and Weekends come from the one card, and so do This week and Last week, and
    /// Best day and Toughest day.
    var insightsCard: LogbookFilter {
        switch self {
        case .weekends: return .weekdays
        case .lastWeek: return .thisWeek
        case .toughestDay: return .bestDay
        default: return self
        }
    }

    /// The chips worth showing, in order: only those that would show something.
    static func available(entries: [LogEntry], alerts: [AlertLogRow]) -> [LogbookFilter] {
        let lowIDs = LogbookSearch.lowTreatmentIDs(entries)
        return allCases.filter { f in
            f.isListed && (entries.contains { f.matches($0, lowIDs: lowIDs) } || alerts.contains { f.matches($0) })
        }
    }
}

/// What was typed into the Logbook's search field, read into words to find and, when it says one,
/// a stretch of time ("yesterday", "last week", "friday", "last 3 days").
struct LogbookQuery: Equatable {
    /// A stretch of time the search named.
    struct Period: Hashable, Sendable {
        /// "Yesterday", "Since last week", "Friday": shown on the chip that says what was understood.
        let label: String
        /// How it reads in a sentence: "yesterday", "since last week", "on Friday".
        let phrase: String
        let interval: DateInterval
        /// One local clock hour (0 to 23) on every day of `interval`, when set: the Insights Time in
        /// range by hour card opens the Logbook on "7–8 am" across its days.
        var hour: Int? = nil

        /// Whether a moment is inside the period, and inside its hour when it has one.
        func contains(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
            guard interval.contains(date) else { return false }
            guard let hour else { return true }
            return calendar.component(.hour, from: date) == hour
        }
    }

    /// Lowercased words, every one of which must be found in an entry.
    let terms: [String]
    let period: Period?
    /// The search text with the time words taken out, for "Search All Dates".
    let withoutPeriod: String

    var isEmpty: Bool { terms.isEmpty && period == nil }

    /// This search with a period the Logbook was opened with (`LogbookLink`) when the words typed
    /// name none. A day typed into the field wins over it.
    func linked(_ linked: Period?) -> LogbookQuery {
        guard period == nil, let linked else { return self }
        return LogbookQuery(terms: terms, period: linked, withoutPeriod: withoutPeriod)
    }

    /// Small words that don't help find anything ("that pizza I had last week").
    static let fillers: Set<String> = [
        "a", "an", "the", "that", "this", "those", "i", "my", "me", "had", "ate", "took", "some",
        "on", "in", "at", "from", "of", "was", "when", "around", "about", "last",
    ]

    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    static func parse(_ text: String, now: Date, calendar: Calendar = .autoupdatingCurrent) -> LogbookQuery {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let keys = words.map(normalised)
        var period: Period?
        var periodSpan: Range<Int>?
        var i = 0
        while i < keys.count, period == nil {
            if let found = readPeriod(keys, at: i, now: now, calendar: calendar) {
                period = found.0
                periodSpan = i..<(i + found.1)
            } else {
                i += 1
            }
        }
        var terms: [String] = []
        var kept: [String] = []
        for (j, key) in keys.enumerated() where !(periodSpan?.contains(j) ?? false) {
            kept.append(words[j])
            if !key.isEmpty, !fillers.contains(key) { terms.append(key) }
        }
        // "on friday", "from last week": the little word before the time goes with it.
        if let span = periodSpan, span.lowerBound > 0, ["on", "from", "since", "in"].contains(keys[span.lowerBound - 1]) {
            kept.remove(at: span.lowerBound - 1)
        }
        return LogbookQuery(terms: terms, period: period, withoutPeriod: kept.joined(separator: " "))
    }

    /// Lowercased, with the punctuation around a word dropped ("pizza," → "pizza"; "4.5" stays).
    static func normalised(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }

    private static func readPeriod(_ k: [String], at i: Int, now: Date, calendar cal: Calendar) -> (Period, Int)? {
        let today = cal.startOfDay(for: now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        func days(_ n: Int, from d: Date) -> Date { cal.date(byAdding: .day, value: n, to: d)! }
        func next(_ n: Int) -> String? { i + n < k.count ? k[i + n] : nil }
        func span(_ label: String, _ start: Date, _ end: Date, _ length: Int, phrase: String? = nil) -> (Period, Int) {
            (Period(label: label, phrase: phrase ?? label.lowercased(),
                    interval: DateInterval(start: start, end: max(start, end))), length)
        }

        switch k[i] {
        case "today":
            return span("Today", today, tomorrow, 1)
        case "yesterday":
            return span("Yesterday", days(-1, from: today), today, 1)
        case "tonight":
            return span("Tonight", cal.date(bySettingHour: 17, minute: 0, second: 0, of: today)!, tomorrow, 1)
        case "this" where next(1) == "morning":
            return span("This morning", today, cal.date(bySettingHour: 12, minute: 0, second: 0, of: today)!, 2)
        case "this" where next(1) == "week":
            let start = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? days(-6, from: today)
            return span("This week", start, tomorrow, 2)
        case "this" where next(1) == "month":
            let start = cal.dateInterval(of: .month, for: now)?.start ?? days(-30, from: today)
            return span("This month", start, tomorrow, 2)
        case "last" where next(1) == "night":
            let yesterday = days(-1, from: today)
            return span("Last night", cal.date(bySettingHour: 17, minute: 0, second: 0, of: yesterday)!,
                        cal.date(bySettingHour: 7, minute: 0, second: 0, of: today)!, 2)
        case "last" where next(1) == "week":
            // Up to now, not just last Monday to Sunday: "that pizza last week" may well have been
            // four days ago on a Tuesday. Wider is better than missing it.
            let thisWeek = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? days(-6, from: today)
            return span("Since last week", days(-7, from: thisWeek), tomorrow, 2)
        case "last" where next(1) == "month":
            let thisMonth = cal.dateInterval(of: .month, for: now)?.start ?? days(-30, from: today)
            let start = cal.date(byAdding: .month, value: -1, to: thisMonth) ?? days(-30, from: thisMonth)
            return span("Since last month", start, tomorrow, 2)
        case "last" where next(1).flatMap({ Self.weekday($0) }) != nil:
            return weekdaySpan(Self.weekday(next(1)!)!, includingToday: false, length: 2, today: today, cal: cal)
        case "last", "past":
            // "last 3 days", "past 2 weeks".
            if let n = next(1).flatMap(Int.init), (1...365).contains(n), let unit = next(2) {
                if unit.hasPrefix("day") {
                    let label = n == 1 ? "Today" : "Last \(n) days"
                    return span(label, days(-(n - 1), from: today), tomorrow, 3, phrase: n == 1 ? "today" : "in the last \(n) days")
                }
                if unit.hasPrefix("week") {
                    let label = n == 1 ? "Last 7 days" : "Last \(n) weeks"
                    return span(label, days(-(7 * n - 1), from: today), tomorrow, 3, phrase: "in the \(label.lowercased())")
                }
            }
            return nil
        default:
            // "3 days ago".
            if let n = Int(k[i]), (0...365).contains(n), next(1)?.hasPrefix("day") == true, next(2) == "ago" {
                let day = days(-n, from: today)
                return span(n == 1 ? "1 day ago" : "\(n) days ago", day, days(1, from: day), 3)
            }
            if let w = weekday(k[i]) {
                return weekdaySpan(w, includingToday: true, length: 1, today: today, cal: cal)
            }
            return nil
        }
    }

    /// 1 (Sunday) to 7 (Saturday) for a weekday's name, its plural or its short form ("fri", "weds").
    /// "sat" and "sun" are left out: too easily part of a note.
    static func weekday(_ word: String) -> Int? {
        let w = word.count > 4 && word.hasSuffix("s") ? String(word.dropLast()) : word
        if let i = weekdays.firstIndex(of: w) { return i + 1 }
        let short = ["mon": 2, "tue": 3, "tues": 3, "wed": 4, "weds": 4, "thu": 5, "thur": 5, "thurs": 5, "fri": 6]
        return short[word]
    }

    /// The latest such weekday: today when it's today (unless "last"), else the one before.
    private static func weekdaySpan(_ weekday: Int, includingToday: Bool, length: Int, today: Date,
                                    cal: Calendar) -> (Period, Int) {
        let todayWeekday = cal.component(.weekday, from: today)
        var back = (todayWeekday - weekday + 7) % 7
        if back == 0, !includingToday { back = 7 }
        let day = cal.date(byAdding: .day, value: -back, to: today)!
        let name = weekdays[weekday - 1].prefix(1).uppercased() + weekdays[weekday - 1].dropFirst()
        let label = back == 0 ? "Today" : back == 1 ? "Yesterday" : (length == 2 ? "Last \(name)" : name)
        let phrase = back <= 1 ? label.lowercased() : "on \(name)"
        return (Period(label: label, phrase: phrase, interval: DateInterval(start: day, end: cal.date(byAdding: .day, value: 1, to: day)!)),
                length)
    }
}

enum LogbookSearch {
    /// How close a meal or dose has to be to a "Hypo treatment" tag to count as treating the low.
    /// The log sheet saves the food and the tag with one time, so this only allows for edits.
    static let lowTreatmentWindow: TimeInterval = 5 * 60

    /// Entries that were about a low: the "Hypo treatment" tags, and food or insulin logged with one.
    static func lowTreatmentIDs(_ entries: [LogEntry]) -> Set<UUID> {
        let tags = entries.compactMap { e -> Date? in
            if case .context(let c) = e, c.tags.contains(.hypoTreatment) { return c.timestamp }
            return nil
        }
        guard !tags.isEmpty else { return [] }
        return Set(entries.filter { e in
            tags.contains { abs($0.timeIntervalSince(e.timestamp)) <= lowTreatmentWindow }
        }.map(\.id))
    }

    /// Whether an entry is found by the search: inside its time, and every word somewhere in it or
    /// in its day's note (`DayNotes`), so "sick" finds everything logged on a "Sick day" and
    /// "sick pizza" the pizza eaten on one.
    static func matches(_ entry: LogEntry, _ query: LogbookQuery, lowIDs: Set<UUID> = [], dayNote: String? = nil) -> Bool {
        if let p = query.period, !p.contains(entry.timestamp) { return false }
        let text = entry.searchText + (lowIDs.contains(entry.id) ? " low hypo" : "") + (dayNote.map { " " + $0 } ?? "")
        return query.terms.allSatisfy { contains(text, $0) }
    }

    static func matches(_ alert: AlertLogRow, _ query: LogbookQuery, dayNote: String? = nil) -> Bool {
        if let p = query.period, !p.contains(alert.timestamp) { return false }
        let text = alert.searchText + (dayNote.map { " " + $0 } ?? "")
        return query.terms.allSatisfy { contains(text, $0) }
    }

    /// Case and accent blind, and forgiving of a plural ("pizzas" finds "Pizza").
    static func contains(_ text: String, _ term: String) -> Bool {
        stems(term).contains { text.range(of: $0, options: options) != nil }
    }

    /// Where the search's words sit in a line of the row, for highlighting. Sorted, never overlapping.
    static func highlights(in text: String, terms: [String]) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        for term in terms {
            // The longest spelling that's there, so "pizzas" lights "pizza" when that's all there is.
            for stem in stems(term) {
                var from = text.startIndex
                var hit = false
                while from < text.endIndex, let r = text.range(of: stem, options: options, range: from..<text.endIndex) {
                    found.append(r)
                    hit = true
                    from = r.upperBound
                }
                if hit { break }
            }
        }
        found.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for r in found {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    /// The empty list's line: "Nothing in Meals matches “pizza” since last week."
    /// With a tag chip picked: "Nothing tagged Exercise matches “pizza”."
    static func noMatchMessage(_ query: LogbookQuery, filter: LogbookFilter?, tag: String? = nil) -> String {
        var s = "Nothing"
        if let filter { s += " in \(filter.title)" }
        if let tag { s += " tagged \(tag)" }
        if !query.terms.isEmpty { s += " matches “\(query.terms.joined(separator: " "))”" }
        if let p = query.period {
            s += " " + p.phrase
        } else if query.terms.isEmpty, filter != nil || tag != nil {
            s += " logged yet"
        }
        return s + "."
    }

    /// The empty state's one button when nothing matched, named for what it takes away
    /// (docs/EmptyStates.md): "Clear Search" for words alone, "Clear Filter" for one chip,
    /// "Show All Dates" for a day alone (a typed day or an Insights card's days), and
    /// "Clear Filters" when more than one thing narrowed it. The Mac goes back to its toolbar's
    /// period rather than every date, so it passes `toAllDates: false` and a day alone reads
    /// "Clear Search".
    static func clearTitle(_ query: LogbookQuery, filter: LogbookFilter?, tag: String? = nil,
                           toAllDates: Bool = true) -> String {
        let words = !query.terms.isEmpty
        let day = query.period != nil
        let chips = (filter == nil ? 0 : 1) + (tag == nil ? 0 : 1)
        switch (words, day, chips) {
        case (true, false, 0): return "Clear Search"
        case (false, false, 1): return "Clear Filter"
        case (false, true, 0): return toAllDates ? "Show All Dates" : "Clear Search"
        default: return "Clear Filters"
        }
    }

    // MARK: The Mac Logbook (docs/LogbookSearch.md, "On the Mac")

    /// Whether the Mac Logbook looks past the toolbar's period. Any search does: the words, and the
    /// day when one is named, decide what shows. So does "Search All Dates". A chip on its own keeps
    /// to the toolbar's period, like the list does with nothing typed.
    static func looksPastToolbarPeriod(_ query: LogbookQuery, allDates: Bool) -> Bool {
        allDates || !query.isEmpty
    }

    /// Whether "Search All Dates" could find more when nothing matched: the day the search named
    /// narrowed it (and there's something else to find by), or a chip was kept to the toolbar's period.
    /// A tag chip counts like a chip.
    static func offersAllDates(_ query: LogbookQuery, filter: LogbookFilter?, tag: String? = nil, allDates: Bool) -> Bool {
        let chip = filter != nil || tag != nil
        if query.period != nil { return !query.terms.isEmpty || chip }
        return chip && !looksPastToolbarPeriod(query, allDates: allDates)
    }

    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// The word, then its singular when it looks like a plural, longest first: "pizzas" → "pizza",
    /// "sandwiches" → "sandwiche", "sandwich".
    private static func stems(_ term: String) -> [String] {
        var out = [term]
        guard term.count > 3, term.hasSuffix("s"), !term.hasSuffix("ss") else { return out }
        out.append(String(term.dropLast()))
        let root = term.dropLast(2)
        if term.hasSuffix("es"), ["s", "x", "z", "ch", "sh"].contains(where: { root.hasSuffix($0) }) {
            out.append(String(root))
        }
        return out
    }
}

extension LogEntry {
    /// Everything a search looks through: the row's title and note, the foods in a meal, the
    /// insulin's type, site and purpose, a moment's tags, the user's own tags, and the kind of entry it is.
    var searchText: String {
        var parts = [shortTitle, searchNote] + labels
        switch self {
        case .dose(let d):
            parts += ["insulin", d.kind.title, d.name, d.site?.title ?? "", d.purpose?.label ?? "", d.viaPump ? "pump" : ""]
        case .meal(let m):
            parts += ["meal food", m.food] + (m.items ?? []).map(\.name)
        case .siteChange(let s):
            parts += ["site", s.site.title]
        case .context(let c):
            // A plain note (an alert note) has no tags: "note" finds it.
            parts += AlertNote.isNote(c) ? ["note"] : c.sortedTags.map(\.title)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// What the user wrote in the note, if anything.
    var searchNote: String {
        switch self {
        case .dose(let d): return d.note
        case .meal(let m): return m.note
        case .siteChange(let s): return s.note
        case .context(let c): return c.note
        }
    }
}

// MARK: - Switching chips

/// The chips picked in the Logbook: the kind chip (All when nil) and the tag chip on top of it.
/// The list follows a pick a moment behind the highlight, so it can fade over to its new rows
/// (docs/LogbookSearch.md "Switching chips"). Tags compare as `LogbookTags.key` does, so
/// "exercise" and "Exercise" are the same pick.
struct LogbookFilterPick: Equatable, Sendable {
    var kind: LogbookFilter?
    var tag: String?

    init(kind: LogbookFilter?, tag: String?) {
        self.kind = kind
        self.tag = tag
    }

    static func == (a: LogbookFilterPick, b: LogbookFilterPick) -> Bool {
        a.kind == b.kind && a.tag.map(LogbookTags.key) == b.tag.map(LogbookTags.key)
    }

    /// How long the old rows take to fade out, and the new ones to fade in, in seconds.
    static let fadeOut = 0.09
    static let fadeIn = 0.2

    /// What VoiceOver says once the list has switched: how many rows the chips leave showing.
    static func announcement(count: Int) -> String {
        switch count {
        case 0: return "No matches"
        case 1: return "1 entry"
        default: return "\(count) entries"
        }
    }
}
