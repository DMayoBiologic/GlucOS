import Foundation

/// Which readings the glucose chart shows and plots, and the time span its axis covers. Plain
/// Foundation so it can be unit-tested; `GlucoseChart` draws from it.
///
/// The chart animates by moving its axis rather than by swapping data: the time domain is set
/// explicitly and animated, while every reading that will be on screen at either end of the
/// movement is already plotted (the ones off the left edge are masked). So switching 3h / 6h /
/// 12h / 24h, or a new reading arriving, slides and rescales the marks that are already there
/// instead of fading one set of marks out and another in.
struct ChartSpan: Equatable {
    /// The time axis, oldest to newest (the forecast's end when there is one).
    let domain: ClosedRange<Date>
    /// The readings inside the axis: what the chart describes, summarises and lets you inspect.
    let visible: ArraySlice<GlucoseReading>
    /// What is drawn: `visible`, plus readings up to `dataHours` back and one `lead` past the
    /// left edge, so they can slide in or out instead of popping.
    let plotted: ArraySlice<GlucoseReading>

    /// How far past the left edge readings stay plotted, so the oldest one slides off the edge as
    /// new readings arrive rather than vanishing from inside the chart.
    static let lead: TimeInterval = 10 * 60

    /// - Parameters:
    ///   - readings: oldest → newest.
    ///   - domainHours: the span the axis shows.
    ///   - dataHours: the span that is plotted (at least `domainHours`); larger only while the
    ///     range is changing.
    ///   - forecastEnd: the last forecast sample's time, which the axis reaches to.
    ///   - lead: readings kept past the left edge. 0 for charts that never animate (widgets).
    ///   - pannedTo: the right edge while the chart is panned back (`ChartPan`); nil follows the
    ///     newest reading. While panned the forecast is left out, and readings one `lead` past the
    ///     right edge stay plotted too, so they slide in and out of that edge as well.
    ///   - keepPlotted: a stretch that stays plotted as well, while the axis glides between two
    ///     pans (or back to now), so the readings on the way slide through rather than popping.
    init?(readings: [GlucoseReading], domainHours: Double, dataHours: Double,
          forecastEnd: Date? = nil, lead: TimeInterval = ChartSpan.lead, pannedTo: Date? = nil,
          keepPlotted: ClosedRange<Date>? = nil) {
        guard let first = readings.first, let last = readings.last else { return nil }
        let panned = pannedTo.map { min($0, last.timestamp) }
        let anchor = panned ?? last.timestamp
        // Never earlier than the first reading, so a short history fills the width as it always has.
        let start = max(anchor.addingTimeInterval(-domainHours * 3600), first.timestamp)
        let end = panned ?? max(anchor, forecastEnd ?? anchor)
        domain = start...max(end, start.addingTimeInterval(60))
        let visibleEnd = panned.map { PeriodSpan.firstIndex(in: readings, after: $0) } ?? readings.count
        let plotUntil = panned.map { p in max(p, keepPlotted?.upperBound ?? p).addingTimeInterval(max(0, lead)) }
        let plotEnd = plotUntil.map { PeriodSpan.firstIndex(in: readings, after: $0) } ?? readings.count
        let lo = Self.firstIndex(in: readings, atOrAfter: start)
        visible = readings[min(lo, visibleEnd)..<visibleEnd]
        let plotStart = min(anchor.addingTimeInterval(-max(dataHours, domainHours) * 3600), start,
                            keepPlotted?.lowerBound ?? start)
            .addingTimeInterval(-max(0, lead))
        let plo = Self.firstIndex(in: readings, atOrAfter: plotStart)
        plotted = readings[min(plo, plotEnd)..<plotEnd]
    }

    /// Binary search: readings are sorted by time.
    static func firstIndex(in readings: [GlucoseReading], atOrAfter date: Date) -> Int {
        var lo = 0, hi = readings.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if readings[mid].timestamp < date { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

/// The chart's range while it changes from one span to another. A widening change plots the
/// wider data first (off the left edge, unseen) and then moves the axis; a narrowing one moves the
/// axis first and drops the extra data once the movement has finished. Either way the axis is
/// the only thing that animates.
struct ChartSpanTransition: Equatable {
    /// The span the axis shows.
    var domainHours: Double
    /// The span that is plotted.
    var dataHours: Double
    /// The span whose level of detail the drawn trace keeps while the axis moves: where the move
    /// started. Charts that thin readings to fit (the Mac dashboard) thin by this until the move
    /// has finished, so the trace keeps its shape while it glides and is redrawn only once, at
    /// the end. Equal to `domainHours` when nothing is changing.
    private(set) var detailHours: Double
    /// Bumped on every change, so a movement that finishes after a newer one began doesn't trim
    /// the newer one's data.
    var generation = 0

    init(hours: Double) {
        domainHours = hours
        dataHours = hours
        detailHours = hours
    }

    /// True between `prepare` and `settle`: more is plotted than the axis shows, or the trace
    /// still has the detail of the span the move started from.
    var isChanging: Bool { dataHours != domainHours || detailHours != domainHours }

    /// Step one, without animation: plot enough for both ends of the move.
    mutating func prepare(for hours: Double) {
        generation += 1
        dataHours = max(dataHours, domainHours, hours)
        detailHours = domainHours
    }

    /// Step two, animated: move the axis.
    mutating func move(to hours: Double) {
        domainHours = hours
    }

    /// Step three, without animation, once the move has finished: stop plotting what's now off
    /// screen. Ignored if another change has started since.
    mutating func settle(generation: Int) {
        guard generation == self.generation else { return }
        dataHours = domainHours
        detailHours = domainHours
    }

    /// Straight to the new span, for Reduce Motion.
    mutating func jump(to hours: Double) {
        generation += 1
        domainHours = hours
        dataHours = hours
        detailHours = hours
    }
}

/// The Mac dashboard chart's readings for a period: like `ChartSpan`, but the axis ends at the
/// period's end (a 5-minute boundary on a live period, or a past moment) rather than at the
/// newest reading, and runs from 3 hours to 30 days. `readings` is the whole archive, oldest →
/// newest; only binary searches and slices are taken from it, so a 90-day archive costs nothing
/// to window.
struct PeriodSpan {
    /// The period on the axis (the chart runs the axis on past it when it draws a forecast).
    let domain: ClosedRange<Date>
    /// The readings inside the period: what the chart describes, summarises and lets you inspect.
    let visible: ArraySlice<GlucoseReading>
    /// What is drawn: `visible`, plus everything the other end of a range change needs and one
    /// `ChartSpan.lead` past the left edge, so readings slide in and out instead of popping.
    let plotted: ArraySlice<GlucoseReading>
    /// While the span changes: readings at or after this keep the detail they had when the move
    /// began, and older ones (off screen until the axis widens) are thinned for the wider span.
    /// Nil when nothing is changing.
    let detailStart: Date?
    /// The stretch `plotted` covers, for anything else drawn with the trace (logged events).
    let plotDomain: ClosedRange<Date>

    init(readings: [GlucoseReading], end: Date, transition t: ChartSpanTransition,
         lead: TimeInterval = ChartSpan.lead) {
        let start = end.addingTimeInterval(-t.domainHours * 3600)
        domain = start...end
        let upper = Self.firstIndex(in: readings, after: end)
        let lo = ChartSpan.firstIndex(in: readings, atOrAfter: start)
        visible = readings[min(lo, upper)..<upper]
        let plotStart = end.addingTimeInterval(-max(t.dataHours, t.domainHours) * 3600 - max(0, lead))
        let plo = ChartSpan.firstIndex(in: readings, atOrAfter: plotStart)
        plotted = readings[min(plo, upper)..<upper]
        plotDomain = min(plotStart, start)...end
        detailStart = t.isChanging ? end.addingTimeInterval(-t.detailHours * 3600) : nil
    }

    /// The first reading later than `date`.
    static func firstIndex(in readings: [GlucoseReading], after date: Date) -> Int {
        var lo = 0, hi = readings.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if readings[mid].timestamp <= date { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

/// The spans the Today chart (iPhone) and the popover chart (Mac) switch between, and how a pinch
/// or a keyboard step moves from one to the next. The choice itself is stored in `AppSettings`
/// (`chartHours`), so it's remembered across launches. Named apart from the widget's own
/// `ChartWindow` intent type.
enum ChartHours {
    static let choices = [3, 6, 12, 24]
    /// What a fresh install, or a stored value that's no longer offered, shows.
    static let standard = 12
    /// How much each chart is handed, whatever span is picked: the longest span plus a quarter
    /// of an hour (more than `ChartSpan.lead`), so switching glides rather than waiting on data.
    static let longestPlotted: Double = Double(choices.max() ?? 24) + 0.25

    /// How far fingers have to spread (or pinch together) for each step. Spreading by 1.4× shows
    /// the next shorter span; spreading by 1.4² two steps.
    static let pinchStep = 1.4

    static func sanitized(_ stored: Int?) -> Int {
        guard let stored, choices.contains(stored) else { return standard }
        return stored
    }

    /// The next shorter span (zooming in), staying at the shortest.
    static func shorter(than hours: Int) -> Int { stepped(hours, by: -1) }

    /// The next longer span (zooming out), staying at the longest.
    static func longer(than hours: Int) -> Int { stepped(hours, by: 1) }

    /// The span a pinch that started on `start` has reached at `scale` (the gesture's
    /// magnification, 1 at rest). Spreading the fingers zooms in to fewer hours, pinching them
    /// together shows more. Steps are whole, so the chart moves in the same jumps as the control.
    static func pinched(from start: Int, scale: Double) -> Int {
        guard scale.isFinite, scale > 0 else { return sanitized(start) }
        let steps = log(scale) / log(pinchStep)
        // A little short of a whole step still counts, so the step lands while the fingers are
        // still moving rather than only at the very end.
        let whole = Int((abs(steps) + 0.1).rounded(.down))
        return stepped(start, by: steps > 0 ? -whole : whole)
    }

    private static func stepped(_ hours: Int, by delta: Int) -> Int {
        let i = choices.firstIndex(of: hours) ?? choices.firstIndex(of: standard) ?? 0
        return choices[min(choices.count - 1, max(0, i + delta))]
    }
}
