import Foundation

// An Alert History row opened into its chart (docs/AlertHistory.md, "Chart in a row"): tap a row
// and it grows in place into a small chart of the two hours around the alert, an hour either side,
// with the reading line, the alert's moment marked and whatever was logged in that time along the
// bottom. One row is open at a time; tapping it again closes it.
//
// Method:
// 1. The chart always spans the same two hours, so an alert a few minutes old draws only its first
//    hour and the line stops at now rather than stretching to fill the width.
// 2. The trace is the Logbook day chart's (`DayChart.segments`): 5-minute means, broken where
//    readings stop for more than 20 minutes.
//
// Observational only: it shows what was stored and logged, and says nothing about what to do.

enum AlertHistoryChart {
    /// How far the chart reaches before the alert...
    static let before: TimeInterval = 60 * 60
    /// ...and after it.
    static let after: TimeInterval = 60 * 60

    /// The two hours the chart spans, an hour either side of the alert.
    static func window(for item: AlertHistory.Item) -> DateInterval {
        DateInterval(start: item.firedAt.addingTimeInterval(-before), end: item.firedAt.addingTimeInterval(after))
    }

    /// Where the trace stops: the end of the window, or now if that's sooner.
    static func traceEnd(for item: AlertHistory.Item, now: Date) -> Date {
        let end = window(for: item).end
        return max(min(end, now), window(for: item).start)
    }

    /// True while the hour after the alert hasn't all passed yet, so the chart is still filling in.
    static func isFilling(_ item: AlertHistory.Item, now: Date) -> Bool {
        now < window(for: item).end
    }

    /// The reading line, as runs of 5-minute means, oldest first. `readings` in any order.
    static func segments(_ readings: [GlucoseReading], for item: AlertHistory.Item, now: Date) -> [[DayChartPoint]] {
        let w = window(for: item)
        return DayChart.segments(readings, from: w.start, to: traceEnd(for: item, now: now))
    }

    /// Whether something logged at `date` belongs on the chart.
    static func contains(_ date: Date, for item: AlertHistory.Item, now: Date) -> Bool {
        let w = window(for: item)
        return date >= w.start && date <= traceEnd(for: item, now: now)
    }

    /// Which row is open after a tap on `tapped`: the same row closes, another row opens in its
    /// place. One at a time, so the list never holds two charts.
    static func toggled(open: UUID?, tapped: UUID) -> UUID? {
        open == tapped ? nil : tapped
    }

    /// The open row, unless it is no longer listed (filtered away by the chips, or aged out of the
    /// 7 days): then nothing is open.
    static func stillOpen(_ open: UUID?, among ids: [UUID]) -> UUID? {
        guard let open, ids.contains(open) else { return nil }
        return open
    }
}

// MARK: - Words

enum AlertHistoryChartText {
    static let showHint = "Shows a chart of the two hours around this alert."
    static let hideHint = "Hides the chart."
    static let openLogbook = "Open in Logbook"
    static let openLogbookHint = "Opens the Logbook around this alert."
    static let noReadings = "No readings stored around this alert"

    /// The caption under an open chart: "Lowest 3.1 at 2:20 pm · Highest 5.6 at 3:05 pm", or that
    /// there were no readings.
    static func caption(_ segments: [[DayChartPoint]], unit: GlucoseUnit, calendar: Calendar = .autoupdatingCurrent,
                        locale: Locale = .autoupdatingCurrent) -> String {
        DayChartText.caption(segments, unit: unit, calendar: calendar, locale: locale) ?? noReadings
    }

    /// The one line VoiceOver adds for an open row: "Chart from 1:14 pm to 3:14 pm: lowest 3.1
    /// mmol/L at 2:20 pm, highest 5.6 mmol/L at 3:05 pm, 2 entries logged." While the hour after
    /// the alert is still running it says "so far" and ends at now.
    static func spoken(_ item: AlertHistory.Item, segments: [[DayChartPoint]], logged: Int, unit: GlucoseUnit,
                       now: Date, calendar: Calendar = .autoupdatingCurrent,
                       locale: Locale = .autoupdatingCurrent) -> String {
        let w = AlertHistoryChart.window(for: item)
        let filling = AlertHistoryChart.isFilling(item, now: now)
        let from = ClockLabel.time(w.start, calendar: calendar, locale: locale)
        let to = filling ? "now" : ClockLabel.time(w.end, calendar: calendar, locale: locale)
        var parts: [String] = []
        if let e = DayChart.extremes(segments) {
            let lo = "lowest \(unit.format(mgdl: e.lowest.mgdl, withUnit: true)) at \(ClockLabel.time(e.lowest.date, calendar: calendar, locale: locale))"
            let hi = "highest \(unit.format(mgdl: e.highest.mgdl, withUnit: true)) at \(ClockLabel.time(e.highest.date, calendar: calendar, locale: locale))"
            parts.append(filling ? "\(lo) so far" : lo)
            parts.append(hi)
        } else {
            parts.append("no readings stored")
        }
        parts.append(logged == 0 ? "nothing logged" : logged == 1 ? "1 entry logged" : "\(logged) entries logged")
        return "Chart from \(from) to \(to): " + parts.joined(separator: ", ") + "."
    }
}
