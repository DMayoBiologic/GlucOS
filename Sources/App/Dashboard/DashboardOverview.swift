import SwiftUI

// MARK: - Overview

struct OverviewSection: View {
    let data: DashboardData
    let snapshot: GlucoseSnapshot
    let events: [ChartEvent]
    /// The period before this one, on its own timestamps.
    let comparison: [GlucoseReading]

    @EnvironmentObject private var logbook: LogbookStore
    @EnvironmentObject private var settings: AppSettings

    /// The forecast runs a few hours at most, so it's only drawn where that's visible.
    private var drawsForecast: Bool { data.isLive && data.range.duration <= 3 * 86_400 }

    /// Insulin and carbs on board are about now, so they only show on a live period, and not
    /// before anything has been logged or a therapy chosen.
    private var showsOnBoard: Bool {
        data.isLive && (settings.therapy != .notSet || !logbook.doses.isEmpty || !logbook.meals.isEmpty)
    }

    var body: some View {
        // Only compare against a previous period that's reasonably complete.
        let previousStats: GlucoseStats? = {
            let start = data.domain.lowerBound.addingTimeInterval(-data.range.duration)
            guard GlucoseAnalytics.coverage(comparison, from: start, to: data.domain.lowerBound) >= 0.5 else { return nil }
            return GlucoseStats.compute(comparison, low: data.lowMgdl, high: data.highMgdl)
        }()
        DashboardPage { layout in
            OverviewHeader(snapshot: snapshot, data: data, previous: previousStats, layout: layout)

            if showsOnBoard {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    OnBoardRow(onBoard: OnBoardNow(doses: logbook.doses, meals: logbook.meals,
                                                   contexts: logbook.contexts, at: ctx.date),
                               forecast: snapshot.currentOutlook(at: ctx.date),
                               noForecastReason: snapshot.isStale(at: ctx.date) ? ForecastUnavailable.stale(age: 0).message
                                                                                 : snapshot.outlook?.unavailableReason,
                               therapy: settings.therapy, unit: data.unit, lowMgdl: data.lowMgdl,
                               spacing: layout.gutter)
                }
            }

            Group {
                if data.readings.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Space.md) {
                        SectionHeader("Glucose", subtitle: data.periodTitle)
                        EmptyStateView(systemImage: "chart.xyaxis.line", title: "No Readings in This Period",
                                       message: data.isLive
                                           ? "Nothing has come in for this stretch yet. Pick a longer range in the toolbar."
                                           : "GlucOS has nothing stored for this stretch. Use the arrows in the toolbar to try another period.")
                            .frame(maxHeight: .infinity)
                    }
                } else {
                    // On the reading panel's 30 s clock, so the chart's latest point greys out
                    // at the same moment the panel does.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        TrendChart(readings: data.readings, domain: data.domain, unit: data.unit,
                                   lowMgdl: data.lowMgdl, highMgdl: data.highMgdl, events: events,
                                   comparison: comparison, comparisonShift: data.range.duration,
                                   latestIsStale: data.isLive && snapshot.isStale(at: context.date),
                                   now: data.isLive ? context.date : nil,
                                   forecast: drawsForecast ? (snapshot.currentOutlook(at: context.date)?.forecast ?? []) : [],
                                   forecastBasis: snapshot.outlook?.basis)
                    }
                    .id("\(data.range.rawValue)-\(data.isLive ? "live" : String(data.domain.upperBound.timeIntervalSince1970))")
                }
            }
            // Room above for the header, and below for the top of the next row of cards.
            .frame(height: layout.chartHeight(reserving: (layout.widthClass == .compact ? 470 : 330) + (showsOnBoard ? 150 : 0)))
            .dashboardCard()

            if let note = data.historyNote { HistoryNote(text: note) }
            if let st = data.stats, let b = data.breakdown {
                CardGrid(minColumnWidth: 300, maxColumns: 3, spacing: layout.gutter) {
                    TimeInRangeCard(breakdown: b, data: data)
                    StatisticsCard(stats: st, data: data)
                    HighlightsCard(data: data)
                }
            }
            Disclaimer()
        }
    }
}

/// A change from the previous period, for a tile.
struct StatChange {
    let value: Double
    let text: String
    /// Nil when neither direction is good or bad.
    let goodWhenUp: Bool?
}

/// The current reading beside the period's four headline numbers. The reading sits on the
/// left on a regular window and on top on a narrow one; the tiles go four across when there's
/// room and two by two when there isn't.
private struct OverviewHeader: View {
    @EnvironmentObject private var settings: AppSettings
    let snapshot: GlucoseSnapshot
    let data: DashboardData
    let previous: GlucoseStats?
    let layout: DashboardLayout

    var body: some View {
        switch data.stats == nil ? DashboardLayout.WidthClass.compact : layout.widthClass {
        case .compact:
            VStack(spacing: layout.gutter) {
                CurrentReadingPanel(snapshot: snapshot, isLive: data.isLive, showsForecast: settings.showForecast)
                tiles
            }
        case .regular, .wide:
            HStack(alignment: .top, spacing: layout.gutter) {
                CurrentReadingPanel(snapshot: snapshot, isLive: data.isLive, showsForecast: settings.showForecast)
                    .frame(width: layout.widthClass == .wide ? 400 : min(340, layout.contentWidth * 0.42))
                tiles
            }
            // Both sides take the height of the taller one, so their edges line up.
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var tiles: some View {
        if let st = data.stats {
            let cv = st.coefficientOfVariation
            let noun = data.range.periodNoun
            CardGrid(minColumnWidth: 150, maxColumns: 4, spacing: layout.gutter, evenRows: true, fillsHeight: true) {
                HeadlineTile(title: "Time in range", value: Format.percent(st.timeInRange), tone: .glucose(.inRange),
                             change: previous.map { StatChange(value: st.timeInRange - $0.timeInRange,
                                                               text: DeltaFormat.points(st.timeInRange - $0.timeInRange),
                                                               goodWhenUp: true) },
                             goal: "goal over 70%", periodNoun: noun,
                             help: "Share of readings between \(data.unit.format(mgdl: data.lowMgdl)) and \(data.unit.format(mgdl: data.highMgdl)) \(data.unit.label).")
                HeadlineTile(title: "Average", value: data.unit.format(mgdl: st.meanMgdl), unit: data.unit.label, tone: .brand,
                             change: previous.map { StatChange(value: st.meanMgdl - $0.meanMgdl,
                                                               text: DeltaFormat.glucose(st.meanMgdl - $0.meanMgdl, unit: data.unit),
                                                               goodWhenUp: nil) },
                             goal: "\(st.count) readings", periodNoun: noun)
                HeadlineTile(title: "Variability", value: Format.percent(cv), tone: cv <= 0.36 ? .brand : .warning,
                             change: previous.map { StatChange(value: cv - $0.coefficientOfVariation,
                                                               text: DeltaFormat.points(cv - $0.coefficientOfVariation),
                                                               goodWhenUp: false) },
                             goal: "goal 36% or less", periodNoun: noun,
                             help: "Coefficient of variation: standard deviation ÷ average. 36% or less is considered stable.")
                HeadlineTile(title: "Time below", value: Format.percent(st.timeBelowRange),
                             tone: st.timeBelowRange > 0.04 ? .glucose(.low) : .neutral,
                             change: previous.map { StatChange(value: st.timeBelowRange - $0.timeBelowRange,
                                                               text: DeltaFormat.points(st.timeBelowRange - $0.timeBelowRange),
                                                               goodWhenUp: false) },
                             goal: "goal under 4%", periodNoun: noun,
                             help: "Share of readings below \(data.unit.format(mgdl: data.lowMgdl, withUnit: true)).")
            }
        }
    }
}

/// One headline number for the period on its own card: what it is, the value, how it moved
/// since the previous period and the goal to compare it with.
private struct HeadlineTile: View {
    let title: String
    let value: String
    var unit: String?
    var tone: Tone = .neutral
    var change: StatChange?
    var goal: String?
    let periodNoun: String
    var help: String?

    var body: some View {
        StatTile(title, value: value, unit: unit, tone: tone, large: true, help: help) {
            HStack(spacing: DS.Space.sm - 2) {
                if let change {
                    DeltaLabel(text: change.text, delta: change.value, goodWhenUp: change.goodWhenUp)
                        .help("Change from the previous \(periodNoun)")
                }
                if let goal {
                    Text(goal)
                        .dsFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.top, DS.Space.xxs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dsCard(.standard, padding: DS.Space.md + 2)
    }
}

/// The live reading, front and centre. Keeps its own clock so it greys out and says so the
/// moment the data goes stale, without waiting for anything else on the page to change.
private struct CurrentReadingPanel: View {
    let snapshot: GlucoseSnapshot
    /// False when the page shows an earlier period, so the panel says this one is "now".
    let isLive: Bool
    var showsForecast: Bool = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            panel(now: ctx.date)
        }
    }

    private func panel(now: Date) -> some View {
        let stale = snapshot.isStale(at: now)
        let tint = snapshot.displayTint(at: now)
        return VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: DS.Space.sm - 2) {
                Eyebrow(title: isLive ? "Current reading" : "Now", systemImage: isLive ? nil : "clock")
                if let range = snapshot.range, snapshot.current != nil { RangeBadge(range: range, stale: stale) }
            }
            if let cur = snapshot.current {
                HStack(alignment: .center, spacing: DS.Space.lg) {
                    // An old trend arrow could be read as what's happening now.
                    TrendDial(trend: stale ? .unknown : cur.trend, tint: tint, size: 64)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm - 2) {
                            Text(snapshot.unit.format(mgdl: cur.mgdl))
                                .dsFont(.heroValue)
                                .foregroundStyle(stale ? Palette.stale : (snapshot.range?.valueColor ?? .primary))
                                .contentTransition(.numericText(value: cur.mgdl))
                                .lineLimit(1)
                                .minimumScaleFactor(0.55)
                            Text(snapshot.unit.label)
                                .dsFont(.unit)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                        HStack(spacing: DS.Space.sm - 2) {
                            Text(stale ? "Trend unknown" : cur.trend.description).fontWeight(.semibold)
                            if let d = snapshot.deltaMgdl, !stale {
                                Text(snapshot.unit.formatDelta(mgdl: d)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            Text("·").foregroundStyle(.tertiary)
                            Text(Format.age(cur.age(at: now)))
                                .foregroundStyle(stale ? Tone.warning.textColor : Color.secondary)
                        }
                        .dsFont(.callout)
                        .lineLimit(1)
                    }
                }
                RangeRail(mgdl: cur.mgdl, lowMgdl: snapshot.lowMgdl, highMgdl: snapshot.highMgdl, stale: stale,
                          forecastMgdl: stale || !showsForecast ? nil : snapshot.currentOutlook(at: now).flatMap(OutlookFormat.headlineSample)?.sample.mgdl,
                          thickness: 6, unit: snapshot.unit)
                if stale {
                    Label("No new reading for \(PopoverFormat.age(cur.age(at: now))). Check your sensor before relying on this number.",
                          systemImage: "exclamationmark.triangle.fill")
                        .fontWeight(.semibold)
                        .dsFont(.caption)
                        .foregroundStyle(Tone.warning.textColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Label("No current reading", systemImage: "drop")
                    .dsFont(.title)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dsCard(.hero(snapshot.displayTone(at: now)), radius: DS.Radius.panel)
        // The range field (docs/Redesign.md §8.3): living colour behind the reading, drifting
        // slowly while it's fresh. A window you look at, so it may move; never under Reduce Motion.
        .background {
            RangeField(tone: snapshot.displayTone(at: now),
                       rapid: !stale && (snapshot.current?.trend.isRapid ?? false), live: isLive)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        }
        .help(isLive ? "" : "This is your current reading. The numbers beside it are for the earlier period you're viewing.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.accessibilitySummary(at: now))
    }
}

private struct TimeInRangeCard: View {
    let breakdown: RangeBreakdown
    let data: DashboardData

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            SectionHeader("Time in Range",
                          subtitle: "Target \(data.unit.format(mgdl: data.lowMgdl))–\(data.unit.format(mgdl: data.highMgdl)) \(data.unit.label)")
            // Ring beside the legend when there's room, above it when the card is narrow, so the
            // labels never wrap.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: DS.Space.xl) {
                    ring(size: 124)
                    legend.frame(minWidth: 220)
                }
                VStack(alignment: .center, spacing: DS.Space.lg) {
                    ring(size: 116)
                    legend
                }
            }
            Spacer(minLength: 0)
            Text("Goals for most adults: over 70% in range, under 4% below, under 1% urgent low.")
                .dsFont(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dashboardCard()
    }

    private func ring(size: CGFloat) -> some View {
        TimeInRangeRing(
            segments: breakdown.rows.reversed().map { (fraction: $0.fraction, color: $0.range.reportColor) },
            inRange: breakdown.inRange, lineWidth: 12, drawsIn: true)
            .frame(width: size, height: size)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            ForEach(breakdown.rows) { row in
                LegendItem(color: row.range.reportColor, label: row.range.label,
                           value: Format.percent(row.fraction),
                           detail: GlucoseAnalytics.perDay(row.fraction),
                           emphasised: row.range == .inRange)
                    .help("\(row.range.label): \(Format.percent(row.fraction)) of readings, about \(GlucoseAnalytics.perDay(row.fraction)) a day")
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The rest of the period's numbers. The headline ones (average, variability, time in and
/// below range) are in the tiles at the top, so they aren't repeated here.
private struct StatisticsCard: View {
    let stats: GlucoseStats
    let data: DashboardData

    var body: some View {
        let u = data.unit
        let fullGMI = stats.spanHours >= 14 * 24 - 1
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            SectionHeader("Statistics", subtitle: "\(stats.count) readings over \(spanText(stats.spanHours))")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow {
                    Metric("Std deviation", u.format(mgdl: stats.sdMgdl), sub: u.label)
                    Metric("GMI", String(format: "%.1f%%", stats.gmiPercent),
                           sub: fullGMI ? "estimated A1c" : "needs 14 days",
                           tint: fullGMI ? nil : Color.secondary,
                           help: "Glucose Management Indicator: an A1c estimate from average glucose. Only reliable over 14+ days of data.")
                }
                GridRow {
                    Metric("Time above", Format.percent(stats.timeAboveRange),
                           sub: "goal under 25%",
                           tint: stats.timeAboveRange > 0.25 ? GlucoseRange.high.textTint : nil,
                           help: "Share of readings above \(u.format(mgdl: data.highMgdl, withUnit: true)).")
                    Metric("Data captured", Format.percent(data.coverage),
                           sub: data.coverage < 0.7 ? "under 70%: less reliable" : "of 15-min periods",
                           tint: data.coverage < 0.7 ? Tone.warning.textColor : nil,
                           help: "Share of 15-minute periods in this range that have a reading. Under 70% makes the numbers less reliable.")
                }
            }
        }
        .dashboardCard()
    }

    private func spanText(_ hours: Double) -> String {
        hours >= 48 ? String(format: "%.1f days", hours / 24) : String(format: "%.0f h", hours)
    }
}

/// The moments worth knowing about in this period.
private struct HighlightsCard: View {
    let data: DashboardData

    var body: some View {
        let h = PeriodHighlights.compute(data.readings, low: data.lowMgdl, high: data.highMgdl)
        let u = data.unit
        let multiDay = data.range.duration > 86_400
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            SectionHeader("Highlights", subtitle: "Moments worth knowing about")
            VStack(alignment: .leading, spacing: DS.Space.md) {
                if let lo = h.lowest {
                    row("arrow.down.to.line", tint: GlucoseRange.classify(mgdl: lo.mgdl, low: data.lowMgdl, high: data.highMgdl).tint,
                        title: "Lowest \(u.format(mgdl: lo.mgdl, withUnit: true))", detail: when(lo.timestamp, multiDay))
                }
                if let hi = h.highest {
                    row("arrow.up.to.line", tint: GlucoseRange.classify(mgdl: hi.mgdl, low: data.lowMgdl, high: data.highMgdl).tint,
                        title: "Highest \(u.format(mgdl: hi.mgdl, withUnit: true))", detail: when(hi.timestamp, multiDay))
                }
                row("checkmark.seal", tint: GlucoseRange.inRange.tint,
                    title: "Longest in range \(h.longestInRange > 0 ? LogFormat.duration(h.longestInRange) : "–")",
                    detail: h.longestInRangeStart.map { "from \(when($0, multiDay))" } ?? "no stretch of 15 min or more")
                row("exclamationmark.triangle", tint: h.lowEpisodes > 0 ? GlucoseRange.low.tint : .secondary,
                    title: h.lowEpisodes == 1 ? "1 low episode" : "\(h.lowEpisodes) low episodes",
                    detail: "below \(u.format(mgdl: data.lowMgdl, withUnit: true)) for 15 min or more")
                row("arrow.up.right", tint: h.highEpisodes > 0 ? GlucoseRange.high.tint : .secondary,
                    title: h.highEpisodes == 1 ? "1 high episode" : "\(h.highEpisodes) high episodes",
                    detail: "above \(u.format(mgdl: data.highMgdl, withUnit: true)) for 15 min or more")
            }
        }
        .dashboardCard()
    }

    private func when(_ date: Date, _ multiDay: Bool) -> String {
        multiDay ? date.formatted(.dateTime.weekday(.abbreviated).day().hour().minute())
                 : date.formatted(date: .omitted, time: .shortened)
    }

    private func row(_ icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.semibold).dsFont(.body).monospacedDigit()
                Text(detail).dsFont(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Lowest, highest, the longest run in range and episode counts for one period.
struct PeriodHighlights {
    var lowest: GlucoseReading?
    var highest: GlucoseReading?
    var longestInRange: TimeInterval = 0
    var longestInRangeStart: Date?
    var lowEpisodes = 0
    var highEpisodes = 0

    static func compute(_ sorted: [GlucoseReading], low: Double, high: Double) -> PeriodHighlights {
        var h = PeriodHighlights()
        h.lowest = sorted.min { $0.mgdl < $1.mgdl }
        h.highest = sorted.max { $0.mgdl < $1.mgdl }
        h.lowEpisodes = GlucoseAnalytics.lowEpisodes(sorted, low: low)
        h.highEpisodes = GlucoseAnalytics.highEpisodes(sorted, high: high)

        let maxGap: TimeInterval = 15 * 60
        var runStart: Date?
        var last: Date?
        func close() {
            if let s = runStart, let l = last {
                let len = l.timeIntervalSince(s)
                if len >= maxGap && len > h.longestInRange { h.longestInRange = len; h.longestInRangeStart = s }
            }
            runStart = nil
        }
        for r in sorted {
            let inRange = r.mgdl >= low && r.mgdl <= high
            if let l = last, r.timestamp.timeIntervalSince(l) > maxGap { close() }
            if inRange {
                if runStart == nil { runStart = r.timestamp }
            } else {
                close()
            }
            last = r.timestamp
        }
        close()
        return h
    }
}

extension GlucoseAnalytics {
    /// Runs above `high` lasting at least 15 minutes. Same rules as `lowEpisodes`.
    static func highEpisodes(_ sorted: [GlucoseReading], high: Double) -> Int {
        let minimum: TimeInterval = 15 * 60
        let maxGap: TimeInterval = 30 * 60
        var count = 0
        var start: Date?
        var lastHigh: Date?
        for r in sorted {
            if let s = start, let l = lastHigh, r.timestamp.timeIntervalSince(l) > maxGap {
                if l.timeIntervalSince(s) >= minimum { count += 1 }
                start = nil; lastHigh = nil
            }
            if r.mgdl > high {
                if start == nil { start = r.timestamp }
                lastHigh = r.timestamp
            } else if let s = start {
                if r.timestamp.timeIntervalSince(s) >= minimum { count += 1 }
                start = nil; lastHigh = nil
            }
        }
        if let s = start, let l = lastHigh, l.timeIntervalSince(s) >= minimum { count += 1 }
        return count
    }
}
