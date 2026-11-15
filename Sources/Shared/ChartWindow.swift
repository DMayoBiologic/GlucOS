import Foundation

/// Which readings the glucose chart shows and plots, and the time span its axis covers. Plain
/// Foundation so it can be unit-tested; `GlucoseChart` draws from it.
///
/// The chart animates by moving its axis rather than by swapping data: the time domain is set
/// explicitly and animated, while every reading that will be on screen at either end of the
/// movement is already plotted (the ones off the left edge are masked). So switching 3h / 6h /
/// 12h / 24h, or a new reading arriving, slides and rescales the marks that are already there
/// instead of fading one set of marks out and another in.
struct ChartWindow: Equatable {
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
    init?(readings: [GlucoseReading], domainHours: Double, dataHours: Double,
          forecastEnd: Date? = nil, lead: TimeInterval = ChartWindow.lead) {
        guard let first = readings.first, let last = readings.last else { return nil }
        let anchor = last.timestamp
        // Never earlier than the first reading, so a short history fills the width as it always has.
        let start = max(anchor.addingTimeInterval(-domainHours * 3600), first.timestamp)
        let end = max(anchor, forecastEnd ?? anchor)
        domain = start...max(end, start.addingTimeInterval(60))
        visible = readings[Self.firstIndex(in: readings, atOrAfter: start)...]
        let plotStart = min(anchor.addingTimeInterval(-max(dataHours, domainHours) * 3600), start)
            .addingTimeInterval(-max(0, lead))
        plotted = readings[Self.firstIndex(in: readings, atOrAfter: plotStart)...]
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
struct ChartRangeTransition: Equatable {
    /// The span the axis shows.
    var domainHours: Double
    /// The span that is plotted.
    var dataHours: Double
    /// Bumped on every change, so a movement that finishes after a newer one began doesn't trim
    /// the newer one's data.
    var generation = 0

    init(hours: Double) {
        domainHours = hours
        dataHours = hours
    }

    /// Step one, without animation: plot enough for both ends of the move.
    mutating func prepare(for hours: Double) {
        generation += 1
        dataHours = max(dataHours, domainHours, hours)
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
    }

    /// Straight to the new span, for Reduce Motion.
    mutating func jump(to hours: Double) {
        generation += 1
        domainHours = hours
        dataHours = hours
    }
}
