import Foundation

/// What an Insights card says when it has nothing to show, and the one thing that helps
/// (docs/EmptyStates.md). Each card already knows why it's empty (`emptyLine`); this picks between
/// "no readings at all", "a longer period has enough", "still gathering days" and, for the Tags
/// card, "nothing tagged in this period".
///
/// The card works the choice out off the main thread only once it's empty, so a card with figures
/// never pays for it.
struct InsightsEmptyState: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// GlucOS has no readings yet.
        case noReadings
        /// Too little in this period, but a longer one of the card's own periods has enough.
        case tryLonger(days: Int)
        /// Not enough days of readings in any period yet. `daysSoFar` counts days with any reading.
        case gathering(daysSoFar: Int, needed: Int)
        /// The Tags card: nothing tagged in this period, and no longer period has a tag either.
        case nothingTagged(days: Int)
        /// The Alerts card: no low or high alert went off in this period, nor in a longer one.
        case noAlerts(days: Int)
    }

    enum Action: Equatable, Sendable {
        /// Switch the card's period picker to this many days.
        case showPeriod(days: Int)
        /// Open the log sheet.
        case log
    }

    let reason: Reason
    let title: String
    let message: String
    let action: Action?

    /// The button's words: "Show 30 Days", "Log Something".
    var actionTitle: String? {
        switch action {
        case .showPeriod(let days): return "Show \(days) Days"
        case .log: return "Log Something"
        case nil: return nil
        }
    }

    /// The symbol beside the words.
    var systemImage: String {
        switch reason {
        case .noReadings: return "drop"
        case .tryLonger: return "calendar.badge.clock"
        case .gathering: return "hourglass"
        case .nothingTagged: return "tag"
        case .noAlerts: return "bell.slash"
        }
    }

    // MARK: Choosing

    /// A card fed by readings. `waiting` is the card's own `emptyLine`; `needed` the days it asks
    /// for; `longerWithData` the shortest of its longer periods that has figures, if any (from
    /// `firstWithData`). `currentDays` is nil for a card without a period picker.
    static func readings(daysSoFar: Int, needed: Int, waiting: String, currentDays: Int?,
                         longerWithData: Int?) -> InsightsEmptyState {
        if daysSoFar == 0 {
            return InsightsEmptyState(reason: .noReadings, title: "No readings yet",
                                      message: "This card fills in once GlucOS has readings from your sensor.",
                                      action: nil)
        }
        if let current = currentDays, let longer = longerWithData, longer > current {
            return InsightsEmptyState(reason: .tryLonger(days: longer),
                                      title: "Not enough in \(current) days",
                                      message: "There's enough over the last \(longer) days to show here.",
                                      action: .showPeriod(days: longer))
        }
        let progress = daysSoFar < needed ? " So far: \(dayCount(daysSoFar)) of \(needed)." : ""
        return InsightsEmptyState(reason: .gathering(daysSoFar: daysSoFar, needed: needed),
                                  title: "Still gathering readings",
                                  message: waiting + progress, action: nil)
    }

    /// The Tags card when its period has no tagged entry. A longer period with a tag comes first;
    /// otherwise "Log Something" where the screen can open the log sheet.
    static func tags(currentDays: Int, longerWithTags: Int?, canLog: Bool) -> InsightsEmptyState {
        if let longer = longerWithTags, longer > currentDays {
            return InsightsEmptyState(reason: .tryLonger(days: longer),
                                      title: "Nothing tagged in \(currentDays) days",
                                      message: "There are tagged entries over the last \(longer) days.",
                                      action: .showPeriod(days: longer))
        }
        return InsightsEmptyState(reason: .nothingTagged(days: currentDays),
                                  title: "Nothing tagged in \(currentDays) days",
                                  message: "Add a tag such as Exercise or Stress when you log, and how the next 4 hours went shows here.",
                                  action: canLog ? .log : nil)
    }

    // MARK: Helpers

    /// The card's periods longer than `current`, shortest first.
    static func longer(than current: Int, in options: [Int]) -> [Int] {
        options.filter { $0 > current }.sorted()
    }

    /// The shortest period in `options` for which `has` says the card would have figures.
    /// Stops at the first one, so a card rarely works out more than one extra period.
    static func firstWithData(_ options: [Int], has: (Int) -> Bool) -> Int? {
        for days in options.sorted() where has(days) { return days }
        return nil
    }

    /// How many local days have at least one reading. Walks the archive once, and only asks the
    /// calendar for a new day when a reading falls outside the last one, so a sorted 90-day
    /// archive costs about one `startOfDay` per day.
    static func readingDays(_ readings: [GlucoseReading], calendar: Calendar = .autoupdatingCurrent) -> Int {
        var days = Set<Date>()
        var current: DateInterval?
        for r in readings where r.mgdl > 0 {
            if let c = current, r.timestamp >= c.start, r.timestamp < c.end { continue }
            let start = calendar.startOfDay(for: r.timestamp)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            current = DateInterval(start: start, end: end)
            days.insert(start)
        }
        return days.count
    }

    static func dayCount(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }
}
