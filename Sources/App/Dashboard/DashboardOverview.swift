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
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HeroBanner(snapshot: snapshot, data: data, previous: previousStats)
                    if data.readings.isEmpty {
                        ContentUnavailableView("No Readings in This Period", systemImage: "chart.xyaxis.line",
                                               description: Text(data.isLive
                                                                 ? "Pick a longer range in the toolbar."
                                                                 : "GlucOS has nothing stored for this stretch. Try a different period."))
                            .frame(height: 360)
                    } else {
                        TrendChart(readings: data.readings, domain: data.domain, unit: data.unit,
                                   lowMgdl: data.lowMgdl, highMgdl: data.highMgdl, events: events,
                                   comparison: comparison, comparisonShift: data.range.duration,
                                   latestIsStale: data.isLive && snapshot.isStale(),
                                   now: data.isLive ? Date() : nil)
                            .id("\(data.range.rawValue)-\(data.isLive ? "live" : String(data.domain.upperBound.timeIntervalSince1970))")
                            .frame(height: Self.chartHeight(for: geo.size.height))
                            .dashboardCard()
                    }
                    if let note = data.historyNote { HistoryNote(text: note) }
                    if let st = data.stats, let b = data.breakdown {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)],
                                  alignment: .leading, spacing: 16) {
                            TimeInRangeCard(breakdown: b, data: data, previous: previousStats)
                            SummaryCard(stats: st, data: data)
                            HighlightsCard(data: data)
                        }
                    }
                    Disclaimer()
                }
                .padding(20)
            }
        }
    }

    /// The chart grows with the window, within reason.
    static func chartHeight(for available: CGFloat) -> CGFloat {
        min(640, max(340, available * 0.52))
    }
}

private struct ChipDelta {
    let value: Double
    let text: String
    let goodWhenUp: Bool?
}

/// The live reading, front and centre, with the period's headline numbers beside it. Stacks
/// vertically when the window is narrow.
private struct HeroBanner: View {
    let snapshot: GlucoseSnapshot
    let data: DashboardData
    let previous: GlucoseStats?

    var body: some View {
        let tint = snapshot.displayTint()
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 24) {
                reading(tint: tint)
                Spacer(minLength: 12)
                chips
            }
            VStack(alignment: .leading, spacing: 16) {
                reading(tint: tint)
                chips
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.ultraThinMaterial)
                AmbientGlow(tint: tint)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(LinearGradient(colors: [tint.opacity(0.5), tint.opacity(0.08)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing),
                              lineWidth: 1)
        }
        .shadow(color: tint.opacity(0.15), radius: 18, y: 8)
    }

    @ViewBuilder
    private func reading(tint: Color) -> some View {
        let stale = snapshot.isStale()
        if let cur = snapshot.current {
            HStack(alignment: .center, spacing: 18) {
                TrendDial(trend: cur.trend, tint: tint, size: 84)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if let range = snapshot.range { RangeBadge(range: range, stale: stale) }
                        if !data.isLive {
                            Text("NOW")
                                .font(.caption2.weight(.bold))
                                .tracking(0.6)
                                .foregroundStyle(.secondary)
                                .help("This is your current reading. The numbers beside it are for the period you're viewing.")
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(snapshot.unit.format(mgdl: cur.mgdl))
                            .font(.system(size: 64, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(stale ? Color.secondary : (snapshot.range?.valueColor ?? .primary))
                            .contentTransition(.numericText(value: cur.mgdl))
                        Text(snapshot.unit.label)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text(cur.trend.description).fontWeight(.semibold)
                        if let d = snapshot.deltaMgdl, !stale {
                            Text(snapshot.unit.formatDelta(mgdl: d)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Text("·").foregroundStyle(.tertiary)
                        Text(Format.age(cur.age()))
                            .foregroundStyle(stale ? Color.orange : Color.secondary)
                    }
                    .font(.callout)
                }
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(snapshot.accessibilitySummary())
        } else {
            Label("No current reading", systemImage: "drop")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var chips: some View {
        if let st = data.stats {
            HStack(spacing: 10) {
                chip("In range", Format.percent(st.timeInRange), tint: GlucoseRange.inRange.tint,
                     delta: previous.map { ChipDelta(value: st.timeInRange - $0.timeInRange,
                                                     text: DeltaFormat.points(st.timeInRange - $0.timeInRange), goodWhenUp: true) })
                chip("Average", data.unit.format(mgdl: st.meanMgdl), tint: Palette.brand,
                     delta: previous.map { ChipDelta(value: st.meanMgdl - $0.meanMgdl,
                                                     text: DeltaFormat.glucose(st.meanMgdl - $0.meanMgdl, unit: data.unit), goodWhenUp: nil) })
                chip("CV", Format.percent(st.coefficientOfVariation),
                     tint: st.coefficientOfVariation <= 0.36 ? Palette.brand : .orange,
                     delta: previous.map { ChipDelta(value: st.coefficientOfVariation - $0.coefficientOfVariation,
                                                     text: DeltaFormat.points(st.coefficientOfVariation - $0.coefficientOfVariation),
                                                     goodWhenUp: false) })
            }
            .fixedSize()
        }
    }

    private func chip(_ title: String, _ value: String, tint: Color,
                      delta: ChipDelta?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            if let delta {
                DeltaLabel(text: delta.text, delta: delta.value, goodWhenUp: delta.goodWhenUp)
                    .help("Change from the previous \(data.range.periodNoun)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 92, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct TimeInRangeCard: View {
    let breakdown: RangeBreakdown
    let data: DashboardData
    let previous: GlucoseStats?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle("Time in Range", trailing: "target \(data.unit.format(mgdl: data.lowMgdl))–\(data.unit.format(mgdl: data.highMgdl))")
            HStack(alignment: .center, spacing: 16) {
                TimeInRangeRing(
                    segments: breakdown.rows.reversed().map { (fraction: $0.fraction, color: $0.range.reportColor) },
                    inRange: breakdown.inRange, lineWidth: 14)
                    .frame(width: 150, height: 150)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(breakdown.rows) { row in
                        HStack(spacing: 6) {
                            Capsule().fill(row.range.reportColor.gradient)
                                .frame(width: 4, height: 14)
                            Text(row.range.label)
                                .font(.callout)
                            Spacer(minLength: 8)
                            Text(GlucoseAnalytics.perDay(row.fraction))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .help("Average time per day")
                            Text(Format.percent(row.fraction))
                                .font(.callout.weight(row.range == .inRange ? .bold : .semibold))
                                .monospacedDigit()
                                .frame(minWidth: 40, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if let previous {
                HStack(spacing: 6) {
                    Text("vs previous \(data.range.periodNoun):").font(.caption).foregroundStyle(.secondary)
                    DeltaLabel(text: DeltaFormat.points(breakdown.inRange - previous.timeInRange),
                               delta: breakdown.inRange - previous.timeInRange, goodWhenUp: true)
                    Text("in range").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Consensus targets: over 70% in range, under 4% below, under 1% urgent low.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .dashboardCard()
    }
}

private struct SummaryCard: View {
    let stats: GlucoseStats
    let data: DashboardData

    var body: some View {
        let u = data.unit
        let cv = stats.coefficientOfVariation
        VStack(alignment: .leading, spacing: 12) {
            CardTitle("Summary", trailing: "\(stats.count) readings")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Metric("Average", u.format(mgdl: stats.meanMgdl), sub: u.label)
                    Metric("GMI", String(format: "%.1f%%", stats.gmiPercent),
                           sub: stats.spanHours >= 14 * 24 - 1 ? "estimated A1c" : "needs 14 days",
                           help: "Glucose Management Indicator: an A1c estimate from average glucose. Only reliable over 14+ days of data.")
                }
                GridRow {
                    Metric("Std deviation", u.format(mgdl: stats.sdMgdl), sub: u.label)
                    Metric("Variability (CV)", Format.percent(cv),
                           sub: cv <= 0.36 ? "stable (≤ 36%)" : "above 36% target",
                           tint: cv <= 0.36 ? nil : Color.orange,
                           help: "Coefficient of variation: standard deviation ÷ average. 36% or less is considered stable.")
                }
                GridRow {
                    Metric("Lowest", u.format(mgdl: stats.minMgdl), sub: u.label)
                    Metric("Highest", u.format(mgdl: stats.maxMgdl), sub: u.label)
                }
                GridRow {
                    Metric("Data captured", Format.percent(data.coverage),
                           sub: "of 15-min periods",
                           tint: data.coverage < 0.7 ? Color.orange : nil,
                           help: "Share of 15-minute periods in this range that have a reading. Under 70% makes the numbers less reliable.")
                    Metric("Span", spanText(stats.spanHours), sub: "first to last reading")
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
        VStack(alignment: .leading, spacing: 12) {
            CardTitle("Highlights")
            VStack(alignment: .leading, spacing: 10) {
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
