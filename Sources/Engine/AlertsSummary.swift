import Foundation

// Insights "Alerts" (docs/InsightsAlerts.md): over the last 7, 14 or 30 days, how many low and
// high alerts went off, of which kind, and how each one ended: "Log treatment" tapped, snoozed,
// dismissed, or nothing. Tapping the card opens Settings › Alerts › Alert History.
//
// Method:
// 1. The alerts are the Alert History's (`AlertHistory.items`), over the card's period instead of
//    the last 7 days: low and high alerts only, the Mac's and the iPhone's copies of one alert
//    counted once with the best outcome kept. Test alerts are never recorded, so never counted.
// 2. The period ends at the card's latest (now, or where Insights is stepped back to) and runs
//    back the period's calendar days, so it keeps its clock time over a daylight-saving change.
//    An alert at the exact start belongs to the period before.
// 3. Kinds fold into four groups: lows (urgent low and low), predicted lows, highs (very high and
//    high) and predicted highs.
// 4. Compare to previous period (docs/InsightsCompare.md) sets the counts against the period of
//    the same length before. That period must have readings on 4 of every 7 of its days, as the
//    other cards ask, and GlucOS must have been keeping alerts by then: its oldest alert record
//    reaches back to within a day of that period's start. Without that the "before" would read as
//    no alerts just because none were recorded yet.
//
// Observational only: it counts what happened and never suggests a dose, a treatment or a change
// to settings. Plain Foundation, so it's unit-tested. Cheap enough (a few hundred records at most,
// kept 90 days) to work out on each data change.

struct AlertsSummary: Hashable {
    /// The same 7, 14 and 30 days as Lows and Highs.
    typealias Period = LowsSummary.Period

    /// Which kind of alert, in the card's order.
    enum Group: Int, CaseIterable, Hashable, Identifiable {
        case low, predictedLow, high, predictedHigh

        var id: Int { rawValue }

        init?(_ kind: AlertNotice.Kind) {
            guard let side = kind.treatment else { return nil }
            let predicted = AlertNotice.Kind.predicted.contains(kind)
            switch side {
            case .low: self = predicted ? .predictedLow : .low
            case .high: self = predicted ? .predictedHigh : .high
            }
        }

        var isLow: Bool { self == .low || self == .predictedLow }
    }

    /// How an alert ended, in the card's order.
    enum Ending: Int, CaseIterable, Hashable, Identifiable {
        case treating, snoozed, dismissed, noResponse

        var id: Int { rawValue }

        init(_ outcome: AlertHistory.Outcome) {
            switch outcome {
            case .treating: self = .treating
            case .snoozed: self = .snoozed
            case .dismissed: self = .dismissed
            case .noResponse: self = .noResponse
            }
        }

        /// The Alert History's own symbol for it.
        var symbol: String {
            switch self {
            case .treating: return AlertHistory.Outcome.treating.symbol
            case .snoozed: return AlertHistory.Outcome.snoozed(minutes: nil).symbol
            case .dismissed: return AlertHistory.Outcome.dismissed.symbol
            case .noResponse: return AlertHistory.Outcome.noResponse.symbol
            }
        }
    }

    let period: Period
    /// Where the period ends.
    let end: Date
    /// Where it starts (exclusive).
    let start: Date
    /// The period's alerts, newest first.
    let items: [AlertHistory.Item]
    /// The oldest alert GlucOS keeps, when it's well inside the period: before then nothing was
    /// recorded, so the footnote says the counts start there.
    var countedSince: Date? = nil

    var count: Int { items.count }

    func count(_ group: Group) -> Int { items.filter { Group($0.kind) == group }.count }
    func count(_ ending: Ending) -> Int { items.filter { Ending($0.outcome) == ending }.count }

    /// Low and predicted low alerts.
    var lows: Int { items.filter(\.isLow).count }
    /// High and predicted high alerts.
    var highs: Int { count - lows }
    /// Alerts something was done about: a button, or dismissed.
    var answered: Int { count - count(.noResponse) }

    /// Each group with its count, the empty ones left out.
    var groups: [(group: Group, count: Int)] {
        Group.allCases.map { ($0, count($0)) }.filter { $0.count > 0 }
    }

    /// Each ending with its count, the empty ones left out.
    var endings: [(ending: Ending, count: Int)] {
        Ending.allCases.map { ($0, count($0)) }.filter { $0.count > 0 }
    }

    // MARK: Compute

    /// The low and high alerts recorded, ignoring every other kind.
    private static func logged(_ records: [AlertRecord]) -> [AlertRecord] {
        records.filter { r in r.alertKind.map(AlertLog.isLogged) ?? false }
    }

    /// Whether the card is on the screen at all: once any low or high alert has been recorded.
    /// Until then it stays out, its place in the order kept (like Tags).
    static func shows(_ records: [AlertRecord]) -> Bool {
        records.contains { r in r.alertKind.map(AlertLog.isLogged) ?? false }
    }

    /// The period of `period` days up to `end`.
    static func compute(records: [AlertRecord], period: Period, end: Date,
                        calendar: Calendar = .autoupdatingCurrent) -> AlertsSummary {
        let start = InsightsPeriodStep.start(end: end, days: period.days, calendar: calendar)
        let items = AlertHistory.items(records: records, readings: [], now: end, since: start, calendar: calendar)
            .filter { $0.firedAt > start }
        let oldest = logged(records).map(\.firedAt).min()
        let since = oldest.flatMap { o in o.timeIntervalSince(start) > InsightsCompare.maximumDriftDays * 86_400 && o <= end ? o : nil }
        return AlertsSummary(period: period, end: end, start: start, items: items, countedSince: since)
    }

    /// The same-length period just before `current`, or nil when it can't fairly be compared:
    /// too few days of readings in it, or alerts weren't being kept yet.
    static func previous(records: [AlertRecord], readings: [GlucoseReading], current: AlertsSummary,
                         calendar: Calendar = .autoupdatingCurrent) -> AlertsSummary? {
        let end = current.start
        let start = InsightsPeriodStep.start(end: end, days: current.period.days, calendar: calendar)
        guard let oldest = logged(records).map(\.firedAt).min(),
              oldest.timeIntervalSince(start) <= InsightsCompare.maximumDriftDays * 86_400 else { return nil }
        let slice = readings.filter { $0.timestamp > start && $0.timestamp <= end }
        let days = min(InsightsEmptyState.readingDays(slice, calendar: calendar), current.period.days)
        guard InsightsCompare.hasEnough(covered: days, of: current.period.days) else { return nil }
        var prev = compute(records: records, period: current.period, end: end, calendar: calendar)
        prev.countedSince = nil
        return prev
    }

    /// The shortest of the longer periods with any alert in it, for the empty state's button.
    static func longerWithAlerts(records: [AlertRecord], than period: Period, end: Date,
                                 calendar: Calendar = .autoupdatingCurrent) -> Period? {
        let options = InsightsEmptyState.longer(than: period.days, in: Period.allCases.map(\.days))
        return InsightsEmptyState.firstWithData(options) { days in
            guard let p = Period(rawValue: days) else { return false }
            return compute(records: records, period: p, end: end, calendar: calendar).count > 0
        }.flatMap(Period.init(rawValue:))
    }
}

// MARK: - Compare

extension InsightsCompare {
    /// Alerts: the total, the low ones and the high ones. Fewer is better.
    static func alerts(_ current: AlertsSummary, _ previous: AlertsSummary?) -> InsightsDelta? {
        previous.map { .count(current.count, $0.count) }
    }

    static func lowAlerts(_ current: AlertsSummary, _ previous: AlertsSummary?) -> InsightsDelta? {
        previous.map { .count(current.lows, $0.lows) }
    }

    static func highAlerts(_ current: AlertsSummary, _ previous: AlertsSummary?) -> InsightsDelta? {
        previous.map { .count(current.highs, $0.highs) }
    }
}

// MARK: - Empty state

extension InsightsEmptyState {
    /// The Alerts card when its period had none. A longer period with alerts comes first.
    static func alerts(currentDays: Int, longerWithAlerts: Int?) -> InsightsEmptyState {
        if let longer = longerWithAlerts, longer > currentDays {
            return InsightsEmptyState(reason: .tryLonger(days: longer),
                                      title: "No alerts in \(currentDays) days",
                                      message: "There were low or high alerts over the last \(longer) days.",
                                      action: .showPeriod(days: longer))
        }
        return InsightsEmptyState(reason: .noAlerts(days: currentDays),
                                  title: "No alerts in \(currentDays) days",
                                  message: "No low or high alerts went off over the last \(currentDays) days. Test alerts aren't counted.",
                                  action: nil)
    }
}

// MARK: - Words

enum AlertsSummaryText {
    static let title = "Alerts"

    static func alerts(_ n: Int) -> String { n == 1 ? "1 alert" : "\(n) alerts" }

    static func countValue(_ n: Int) -> String { "\(n)" }

    /// "9 alerts in the last 14 days."
    static func headline(_ s: AlertsSummary) -> String {
        s.count == 0 ? "No alerts in \(s.period.spoken)." : "\(alerts(s.count)) in \(s.period.spoken)."
    }

    /// The names in the By kind rows.
    static func group(_ g: AlertsSummary.Group) -> String {
        switch g {
        case .low: return "Low and urgent low"
        case .predictedLow: return "Predicted low"
        case .high: return "High and very high"
        case .predictedHigh: return "Predicted high"
        }
    }

    /// The names in the How they ended key.
    static func ending(_ e: AlertsSummary.Ending) -> String {
        switch e {
        case .treating: return "Tapped \(AlertSnoozes.treatTitle)"
        case .snoozed: return "Snoozed"
        case .dismissed: return "Dismissed"
        case .noResponse: return "No response"
        }
    }

    static let byKind = "By kind"
    static let howTheyEnded = "How they ended"

    /// "7 of 9 were snoozed, dismissed or had Log treatment tapped." Nil with none.
    static func answeredLine(_ s: AlertsSummary) -> String? {
        guard s.count > 0 else { return nil }
        if s.answered == 0 { return s.count == 1 ? "Nothing was tapped on it." : "Nothing was tapped on any of them." }
        if s.answered == s.count { return s.count == 1 ? "It got a response." : "Every one got a response." }
        return "\(s.answered) of \(s.count) got a response."
    }

    static func footnote(_ s: AlertsSummary, calendar: Calendar = .autoupdatingCurrent,
                         locale: Locale = .autoupdatingCurrent) -> String {
        var t = "Each low and high alert counts once, even when the Mac and iPhone both showed it. Test alerts aren't counted."
        if let since = s.countedSince {
            t += " GlucOS has kept alerts since \(InsightsShare.dateRange(from: since, to: since, calendar: calendar, locale: locale))."
        }
        return t + " Observations, not advice."
    }

    /// The row at the foot of the card.
    static let historyLine = "Open Alert History"
    static let historyHint = "Opens Settings, Alerts, Alert History, which lists each alert of the last 7 days"

    /// The whole card for VoiceOver, in a few sentences.
    static func spoken(_ s: AlertsSummary) -> String {
        var parts = ["Alerts, \(s.period.spoken)"]
        guard s.count > 0 else { return parts[0] + ". No alerts." }
        parts.append("\(alerts(s.count)): \(s.lows) low, \(s.highs) high")
        parts.append("By kind: " + s.groups.map { "\(group($0.group)) \($0.count)" }.joined(separator: ", "))
        parts.append("How they ended: " + s.endings.map { "\(ending($0.ending)) \($0.count)" }.joined(separator: ", "))
        return parts.joined(separator: ". ") + "."
    }
}
