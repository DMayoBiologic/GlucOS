import SwiftUI

// MARK: - Overview

struct OverviewSection: View {
    let data: DashboardData
    let snapshot: GlucoseSnapshot
    let events: [ChartEvent]
    /// The period before this one, on its own timestamps.
    let comparison: [GlucoseReading]

    var body: some View {
        // Only compare against a previous period that's reasonably complete.
        let previousStats: GlucoseStats? = {
            let start = data.domain.lowerBound.addingTimeInterval(-data.range.duration)
            guard GlucoseAnalytics.coverage(comparison, from: start, to: data.domain.lowerBound) >= 0.5 else { return nil }
            return GlucoseStats.compute(comparison, low: data.lowMgdl, high: data.highMgdl)
        }()
        DashboardPage { layout in
            OverviewHeader(snapshot: snapshot, data: data, previous: previousStats, layout: layout)

            Group {
                if data.readings.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        DashboardCardHeader("Glucose", subtitle: data.periodTitle)
                        ContentUnavailableView {
                            Label("No Readings in This Period", systemImage: "chart.xyaxis.line")
                        } description: {
                            Text(data.isLive
                                 ? "Nothing has come in for this stretch yet. Pick a longer range in the toolbar."
                                 : "GlucOS has nothing stored for this stretch. Use the arrows in the toolbar to try another period.")
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    TrendChart(readings: data.readings, domain: data.domain, unit: data.unit,
                               lowMgdl: data.lowMgdl, highMgdl: data.highMgdl, events: events,
                               comparison: comparison, comparisonShift: data.range.duration,
                               latestIsStale: data.isLive && snapshot.isStale(),
                               now: data.isLive ? Date() : nil)
                        .id("\(data.range.rawValue)-\(data.isLive ? "live" : String(data.domain.upperBound.timeIntervalSince1970))")
                }
            }
            // Room above for the header, and below for the top of the next row of cards.
            .frame(height: layout.chartHeight(reserving: layout.widthClass == .compact ? 470 : 330))
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
    let snapshot: GlucoseSnapshot
    let data: DashboardData
    let previous: GlucoseStats?
    let layout: DashboardLayout

    var body: some View {
        switch layout.widthClass {
        case .compact:
            VStack(spacing: layout.gutter) {
                CurrentReadingPanel(snapshot: snapshot, isLive: data.isLive)
                tiles
            }
        case .regular, .wide:
            HStack(alignment: .top, spacing: layout.gutter) {
                CurrentReadingPanel(snapshot: snapshot, isLive: data.isLive)
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
                HeadlineTile(title: "Time in range", value: Format.percent(st.timeInRange),
                             tint: GlucoseRange.inRange.tint,
                             change: previous.map { StatChange(value: st.timeInRange - $0.timeInRange,
                                                               text: DeltaFormat.points(st.timeInRange - $0.timeInRange),
                                                               goodWhenUp: true) },
                             caption: "goal over 70%", periodNoun: noun,
                             help: "Share of readings between \(data.unit.format(mgdl: data.lowMgdl)) and \(data.unit.format(mgdl: data.highMgdl)) \(data.unit.label).")
                HeadlineTile(title: "Average", value: data.unit.format(mgdl: st.meanMgdl), unit: data.unit.label,
                             tint: Palette.brand,
                             change: previous.map { StatChange(value: st.meanMgdl - $0.meanMgdl,
                                                               text: DeltaFormat.glucose(st.meanMgdl - $0.meanMgdl, unit: data.unit),
                                                               goodWhenUp: nil) },
                             caption: "\(st.count) readings", periodNoun: noun)
                HeadlineTile(title: "Variability", value: Format.percent(cv),
                             tint: cv <= 0.36 ? Palette.brand : Palette.amber,
                             change: previous.map { StatChange(value: cv - $0.coefficientOfVariation,
                                                               text: DeltaFormat.points(cv - $0.coefficientOfVariation),
                                                               goodWhenUp: false) },
                             caption: "goal 36% or less", periodNoun: noun,
                             help: "Coefficient of variation: standard deviation ÷ average. 36% or less is considered stable.")
                HeadlineTile(title: "Time below", value: Format.percent(st.timeBelowRange),
                             tint: st.timeBelowRange > 0.04 ? GlucoseRange.low.tint : .primary,
                             change: previous.map { StatChange(value: st.timeBelowRange - $0.timeBelowRange,
                                                               text: DeltaFormat.points(st.timeBelowRange - $0.timeBelowRange),
                                                               goodWhenUp: false) },
                             caption: "goal under 4%", periodNoun: noun,
                             help: "Share of readings below \(data.unit.format(mgdl: data.lowMgdl, withUnit: true)).")
            }
        }
    }
}

/// One headline number for the period: what it is, the value, how it moved since the previous
/// period and the goal to compare it with.
private struct HeadlineTile: View {
    let title: String
    let value: String
    var unit: String?
    var tint: Color = .primary
    var change: StatChange?
    var caption: String?
    let periodNoun: String
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(title: title)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if let change {
                    DeltaLabel(text: change.text, delta: change.value, goodWhenUp: change.goodWhenUp)
                        .help("Change from the previous \(periodNoun)")
                }
                if let caption {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard(padding: 14, radius: 16)
        .help(help ?? "")
        .accessibilityElement(children: .combine)
    }
}

/// The live reading, front and centre. Keeps its own clock so it greys out and says so the
/// moment the data goes stale, without waiting for anything else on the page to change.
private struct CurrentReadingPanel: View {
    let snapshot: GlucoseSnapshot
    /// False when the page shows an earlier period, so the panel says this one is "now".
    let isLive: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            panel(now: ctx.date)
        }
    }

    private func panel(now: Date) -> some View {
        let stale = snapshot.isStale(at: now)
        let tint = snapshot.displayTint(at: now)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Eyebrow(title: isLive ? "Current reading" : "Now", systemImage: isLive ? nil : "clock")
                if let range = snapshot.range, snapshot.current != nil { RangeBadge(range: range, stale: stale) }
            }
            if let cur = snapshot.current {
                HStack(alignment: .center, spacing: 16) {
                    TrendDial(trend: cur.trend, tint: tint, size: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(snapshot.unit.format(mgdl: cur.mgdl))
                                .font(.system(size: 54, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(stale ? Color.secondary : (snapshot.range?.valueColor ?? .primary))
                                .contentTransition(.numericText(value: cur.mgdl))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            Text(snapshot.unit.label)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                        HStack(spacing: 6) {
                            Text(stale ? "Trend unknown" : cur.trend.description).fontWeight(.semibold)
                            if let d = snapshot.deltaMgdl, !stale {
                                Text(snapshot.unit.formatDelta(mgdl: d)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            Text("·").foregroundStyle(.tertiary)
                            Text(Format.age(cur.age(at: now)))
                                .foregroundStyle(stale ? Palette.amber : Color.secondary)
                        }
                        .font(.callout)
                        .lineLimit(1)
                    }
                }
                if stale {
                    Label("No new reading for \(PopoverFormat.age(cur.age(at: now))). Check your sensor before relying on this number.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Label("No current reading", systemImage: "drop")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.ultraThinMaterial)
                AmbientGlow(tint: tint)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(LinearGradient(colors: [tint.opacity(0.5), tint.opacity(0.08)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing),
                              lineWidth: 1)
        }
        .shadow(color: tint.opacity(0.12), radius: 14, y: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.accessibilitySummary(at: now))
    }
}

private struct TimeInRangeCard: View {
    let breakdown: RangeBreakdown
    let data: DashboardData

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashboardCardHeader("Time in Range",
                                subtitle: "Target \(data.unit.format(mgdl: data.lowMgdl))–\(data.unit.format(mgdl: data.highMgdl)) \(data.unit.label)")
            // Ring beside the legend when there's room, above it when the card is narrow, so the
            // labels never wrap.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 20) {
                    ring(size: 124)
                    legend.frame(minWidth: 200)
                }
                VStack(alignment: .center, spacing: 14) {
                    ring(size: 116)
                    legend
                }
            }
            Spacer(minLength: 0)
            Text("Goals for most adults: over 70% in range, under 4% below, under 1% urgent low.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dashboardCard()
    }

    private func ring(size: CGFloat) -> some View {
        TimeInRangeRing(
            segments: breakdown.rows.reversed().map { (fraction: $0.fraction, color: $0.range.reportColor) },
            inRange: breakdown.inRange, lineWidth: 12)
            .frame(width: size, height: size)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(breakdown.rows) { row in
                HStack(spacing: 8) {
                    Capsule().fill(row.range.reportColor.gradient)
                        .frame(width: 4, height: 16)
                    Text(row.range.label)
                        .font(.callout)
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 10)
                    Text(GlucoseAnalytics.perDay(row.fraction))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .help("Average time per day")
                    Text(Format.percent(row.fraction))
                        .font(.callout.weight(row.range == .inRange ? .bold : .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minWidth: 40, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
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
        VStack(alignment: .leading, spacing: 14) {
            DashboardCardHeader("Statistics", subtitle: "\(stats.count) readings over \(spanText(stats.spanHours))")
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
                           tint: stats.timeAboveRange > 0.25 ? GlucoseRange.high.tint : nil,
                           help: "Share of readings above \(u.format(mgdl: data.highMgdl, withUnit: true)).")
                    Metric("Data captured", Format.percent(data.coverage),
                           sub: data.coverage < 0.7 ? "under 70%: less reliable" : "of 15-min periods",
                           tint: data.coverage < 0.7 ? Palette.amber : nil,
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
        VStack(alignment: .leading, spacing: 14) {
            DashboardCardHeader("Highlights", subtitle: "Moments worth knowing about")
            VStack(alignment: .leading, spacing: 11) {
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
                Text(title).font(.callout.weight(.semibold)).monospacedDigit()
                Text(detail).font(.caption).foregroundStyle(.secondary)
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
