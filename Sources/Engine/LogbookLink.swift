import Foundation

// Opening the Logbook from somewhere else with a chip and a stretch of time already picked
// (docs/LogbookSearch.md, "From the Insights cards"). Today that's the Insights Lows, Highs,
// Overnight, Weekdays and weekends, Week in review, In-range streaks, Best and toughest days, Tags and Time in range by hour cards: tapping one shows its chip over the
// same days the card counted.

/// The chip and period the Logbook opens with. Nothing is typed into the search field: the period
/// shows as the usual chip above the list ("Last 14 days ✕"), and ✕ or Clear Filters drops it.
struct LogbookLink: Hashable, Sendable {
    let filter: LogbookFilter
    let period: LogbookQuery.Period
    /// The tag chip to pick (the Tags card). With one, the Logbook opens on that tag chip alone,
    /// with no kind chip: `filter` is then `.tagged`, which only says where the link came from.
    var tag: String? = nil

    init(filter: LogbookFilter, period: LogbookQuery.Period, tag: String? = nil) {
        self.filter = filter
        self.period = period
        self.tag = tag
    }

    /// The kind chip the Logbook opens on: none for a tag link, so every kind tagged shows, and none
    /// for an hour link, whose hour rides on the period chip ("7–8 am · Last 14 days"), and none for
    /// the "while you were away" line, whose period chip says it all.
    var kindChip: LogbookFilter? { tag == nil && filter != .hourOfDay && filter != .whileAway ? filter : nil }

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

    /// The Overnight card's period, read the same way, on the Overnight chip: everything logged
    /// between midnight and 6 am on those days, lows, treatments, alerts and all.
    static func overnight(_ period: OvernightSummary.Period, newestReading: Date?, now: Date) -> LogbookLink {
        card(.overnight, days: period.days, newestReading: newestReading, now: now)
    }

    /// One side of the Weekdays and weekends card, read the same way, on the Weekdays or Weekends
    /// chip: everything logged on those days of the week over the card's period.
    static func weekPart(_ side: WeekdayWeekend.Side, _ period: WeekdayWeekend.Period, newestReading: Date?,
                         now: Date) -> LogbookLink {
        card(side.filter, days: period.days, newestReading: newestReading, now: now)
    }

    /// One week of the Week in review card, on the This week or Last week chip: everything logged
    /// over the 7 days the card counted for it (`WeekInReview.interval`). This week runs on to now,
    /// as the other cards' periods do, so something logged after the last reading still shows.
    static func week(_ side: WeekInReview.Side, newestReading: Date?, now: Date) -> LogbookLink {
        let span = WeekInReview.interval(side, end: newestReading ?? now)
        switch side {
        case .current:
            return LogbookLink(filter: side.filter,
                               period: .init(label: "Last 7 days", phrase: "in the last 7 days",
                                             interval: DateInterval(start: span.start, end: max(span.end, now))))
        case .previous:
            return LogbookLink(filter: side.filter,
                               period: .init(label: "7 days before", phrase: "in the 7 days before the last 7",
                                             interval: span))
        }
    }

    /// The In-range streaks card's longest run, on the Longest streak chip: everything logged on
    /// the run's days, local midnight to midnight ("3 Nov – 14 Nov"). A run that takes in today
    /// ends at tonight's midnight, so something logged after the last reading still shows.
    static func bestStreak(_ run: InRangeStreaks.Run, now: Date, calendar: Calendar = .autoupdatingCurrent) -> LogbookLink {
        let span = InRangeStreaksText.span(run, now: now, calendar: calendar)
        return LogbookLink(filter: .bestStreak,
                           period: .init(label: span, phrase: InRangeStreaksText.phrase(run, now: now, calendar: calendar),
                                         interval: run.interval))
    }

    /// One tag on the Tags card, over the card's period read the same way as the Lows card's: the
    /// Logbook opens on that tag's chip, every kind of entry carrying it.
    static func tag(_ tag: String, _ period: TagInsights.Period, newestReading: Date?, now: Date) -> LogbookLink {
        let base = card(.tagged, days: period.days, newestReading: newestReading, now: now)
        return LogbookLink(filter: .tagged, period: base.period, tag: tag)
    }

    /// One hour of the Time in range by hour card: everything logged in that local clock hour on
    /// every day of the card's period, read the same way as the Lows card's. No kind chip: the
    /// period chip names the hour, and its ✕ drops hour and days together.
    static func hour(_ hour: Int, _ period: HourlyInRange.Period, newestReading: Date?, now: Date) -> LogbookLink {
        let base = card(.hourOfDay, days: period.days, newestReading: newestReading, now: now)
        let span = HourlyInRangeText.span(hour)
        return LogbookLink(filter: .hourOfDay,
                           period: .init(label: "\(span) · Last \(period.days) days",
                                         phrase: "between \(HourlyInRangeText.clock(hour)) and \(HourlyInRangeText.clock(hour + 1)) in the last \(period.days) days",
                                         interval: base.period.interval, hour: hour))
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
