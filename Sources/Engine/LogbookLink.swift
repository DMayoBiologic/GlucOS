import Foundation

// Opening the Logbook from somewhere else with a chip and a stretch of time already picked
// (docs/LogbookSearch.md, "From the Lows and Highs cards"). Today that's the Insights Lows and
// Highs cards: tapping one shows its chip over the same days the card counted.

/// The chip and period the Logbook opens with. Nothing is typed into the search field: the period
/// shows as the usual chip above the list ("Last 14 days ✕"), and ✕ or Clear Filters drops it.
struct LogbookLink: Hashable, Sendable {
    let filter: LogbookFilter
    let period: LogbookQuery.Period

    /// The Lows card's period, as the Logbook reads it. The card counts the `days` × 24 hours up to
    /// the newest reading (`LowsSummary.compute`), so the Logbook starts there too rather than at
    /// a midnight, which would leave out the first day's early lows. It runs on to now, so a
    /// treatment logged after the last reading (a sensor gap, a stale phone) still shows.
    static func lows(_ period: LowsSummary.Period, newestReading: Date?, now: Date) -> LogbookLink {
        card(.lows, days: period.days, newestReading: newestReading, now: now)
    }

    /// The Highs card's period, read the same way as the Lows card's (`HighsSummary.compute`), on
    /// the Highs chip: high alerts and insulin marked as a correction.
    static func highs(_ period: HighsSummary.Period, newestReading: Date?, now: Date) -> LogbookLink {
        card(.highs, days: period.days, newestReading: newestReading, now: now)
    }

    private static func card(_ filter: LogbookFilter, days: Int, newestReading: Date?, now: Date) -> LogbookLink {
        let end = max(newestReading ?? now, now)
        let start = (newestReading ?? now).addingTimeInterval(-Double(days) * 86_400)
        return LogbookLink(filter: filter,
                           period: .init(label: "Last \(days) days", phrase: "in the last \(days) days",
                                         interval: DateInterval(start: start, end: end)))
    }

    /// Where the zoom on iPhone grows from: one per card, so it still finds the card on the way
    /// back after a new reading has moved the period on.
    var sourceID: String { Self.sourceID(for: filter) }

    static func sourceID(for filter: LogbookFilter) -> String { "logbook-\(filter.rawValue)" }
}
