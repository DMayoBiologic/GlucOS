import Foundation

// Insights explainers (improvement round 65, docs/InsightsExplainers.md): an info button beside each
// Glance figure (time in range, average, GMI, variability and lows) opens a short plain-language
// note on what the figure means and how GlucOS worked it out for the period on screen. A sheet on
// iPhone, a popover on the Mac. It scales in gently, and only fades under Reduce Motion.
//
// The notes describe the figure and nothing more: no advice, no targets beyond the ones the cards
// already name, and never a dose. Plain Foundation, so `swift test` covers it.

/// One of the Glance figures that has an explainer.
enum InsightsFigure: String, CaseIterable, Identifiable, Sendable {
    case timeInRange
    case average
    case gmi
    case variability
    case lows

    var id: String { rawValue }

    /// The figure's name as the card shows it.
    var title: String {
        switch self {
        case .timeInRange: return "Time in range"
        case .average: return "Average"
        case .gmi: return "GMI"
        case .variability: return "Variability (CV)"
        case .lows: return "Time below range"
        }
    }

    /// The info button's VoiceOver label: "About time in range".
    var buttonLabel: String {
        switch self {
        case .gmi: return "About GMI"
        case .variability: return "About variability"
        default: return "About " + title.lowercased()
        }
    }
}

/// The note behind one figure's info button, for one period.
struct InsightsExplainer: Equatable {
    let figure: InsightsFigure
    /// "Time in range".
    let title: String
    /// What the figure means, in a sentence or two.
    let meaning: String
    /// How GlucOS worked it out for this period, with the period's own numbers.
    let workedOut: String
    /// A caveat, when the figure has one (GMI over a short period, too few readings).
    let note: String?

    /// The heading above `workedOut`.
    static let workedOutHeading = "How it's worked out"

    /// Fewer readings than this and every note says the figure may not say much yet.
    static let fewReadings = 12
    /// GMI is only a fair estimate over about two weeks of readings.
    static let gmiHours: Double = 14 * 24 - 1

    /// Everything VoiceOver reads, in the order it's shown.
    var spoken: String {
        [title + ".", meaning, Self.workedOutHeading + ".", workedOut, note]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    /// The period's figures the notes quote.
    struct Context: Equatable {
        let stats: GlucoseStats
        let unit: GlucoseUnit
        let lowMgdl: Double
        let highMgdl: Double
        /// Fits after "over": "the last 7 days", "the 3 days ending 2 Nov".
        let period: String
    }

    static func make(_ figure: InsightsFigure, _ c: Context) -> InsightsExplainer {
        let s = c.stats
        let u = c.unit
        let readings = s.count == 1 ? "1 reading" : "\(s.count) readings"
        let low = u.format(mgdl: c.lowMgdl, withUnit: true)
        let high = u.format(mgdl: c.highMgdl, withUnit: true)
        let few = s.count < fewReadings
            ? "With only \(readings) so far, this figure may change a lot as more arrive." : nil

        switch figure {
        case .timeInRange:
            return InsightsExplainer(
                figure: figure, title: figure.title,
                meaning: "The share of your readings that were inside your target range.",
                workedOut: "Of the \(readings) over \(c.period), \(percent(s.timeInRange)) were between \(low) and \(high). Readings above or below that count as out of range. You can change the range in Settings.",
                note: few)
        case .average:
            return InsightsExplainer(
                figure: figure, title: figure.title,
                meaning: "Your mean glucose: the typical level your readings sat at.",
                workedOut: "All \(readings) over \(c.period) added together and divided by \(s.count), which gives \(u.format(mgdl: s.meanMgdl, withUnit: true)). It doesn't show how much readings rose and fell around it; variability does.",
                note: few)
        case .gmi:
            let mgdl = String(format: "%.0f", s.meanMgdl)
            let gmi = String(format: "%.1f%%", s.gmiPercent)
            let short = s.spanHours < gmiHours
                ? "Your readings cover less than 14 days, so treat it as a rough guide for now. "
                : ""
            return InsightsExplainer(
                figure: figure, title: figure.title,
                meaning: "The Glucose Management Indicator: an estimate of the A1c a lab test might give, worked out from your average glucose.",
                workedOut: "3.31 + 0.02392 × your average in mg/dL. Over \(c.period) your average was \(mgdl) mg/dL, which gives \(gmi).",
                note: short + "It can differ from a lab A1c, which measures something different over about three months.")
        case .variability:
            return InsightsExplainer(
                figure: figure, title: figure.title,
                meaning: "How much your readings rose and fell around your average, as a share of it. A lower figure means steadier readings.",
                workedOut: "The standard deviation of the \(readings) over \(c.period) (\(u.format(mgdl: s.sdMgdl, withUnit: true))) divided by the average (\(u.format(mgdl: s.meanMgdl, withUnit: true))), which gives \(percent(s.coefficientOfVariation)). 36% or less is the mark commonly used for steady readings.",
                note: few)
        case .lows:
            return InsightsExplainer(
                figure: figure, title: figure.title,
                meaning: "The share of your readings that were below the bottom of your target range.",
                workedOut: "Of the \(readings) over \(c.period), \(percent(s.timeBelowRange)) were under \(low). Readings under \(u.format(mgdl: 54, withUnit: true)) are counted here too.",
                note: few)
        }
    }

    /// Every figure's note for one period, in the order the cards show them.
    static func all(_ c: Context) -> [InsightsExplainer] {
        InsightsFigure.allCases.map { make($0, c) }
    }

    /// The period as it reads after "over": "the last 24 hours", "the last 7 days", and once
    /// stepped back "the 7 days ending 2 Nov" (or "the 6 hours ending 2 Nov, 3:00 pm").
    static func period(hours: Double, end: Date, isLatest: Bool,
                       calendar: Calendar = .autoupdatingCurrent,
                       locale: Locale = .autoupdatingCurrent) -> String {
        let whole = Int(hours.rounded())
        let length: String
        if whole < 48 || whole % 24 != 0 {
            length = whole == 1 ? "hour" : "\(whole) hours"
        } else {
            length = "\(whole / 24) days"
        }
        if isLatest { return "the last \(length)" }
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(whole < 24 ? "d MMM j:mm" : "d MMM")
        // The period ends at a midnight for whole days; name the day it covers, not the next one.
        let shown = whole >= 24 && calendar.startOfDay(for: end) == end ? end.addingTimeInterval(-1) : end
        return "the \(length) ending \(f.string(from: shown))"
    }

    private static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }
}

/// How the note arrives: a gentle scale-in with a fade, and only the fade under Reduce Motion.
enum InsightsExplainerEntrance {
    /// The scale the note starts at before it settles to 1.
    static let startScale: Double = 0.94
    static let fadeDuration: Double = 0.2

    static func scale(shown: Bool, reduceMotion: Bool) -> Double {
        shown || reduceMotion ? 1 : startScale
    }

    static func opacity(shown: Bool) -> Double {
        shown ? 1 : 0
    }
}
