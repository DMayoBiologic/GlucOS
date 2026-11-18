import SwiftUI
import WidgetKit
import Charts
import AppIntents

// Building blocks shared by every GlucOS widget. Colour rules, in one place:
// - Only a fresh reading is ever drawn in its range colour. Stale, expired and missing data is
//   neutral grey and says so in words, so nothing old can look reassuring.
// - In the vibrant (desktop, unfocused) and accented (tinted) rendering modes colour is gone, so
//   every state is also carried by text and an icon.

extension WidgetRenderingMode {
    /// True when the widget is drawn in full colour, i.e. our palette is actually visible.
    var isFullColor: Bool { self == .fullColor }
}

extension GlucoseEntry {
    /// `.stale` unless the reading is fresh, so old data can never take a range colour.
    var tone: Tone { snapshot.range?.tone(stale: freshness != .fresh) ?? .stale }
    var tint: Color { tone.color }
}

// MARK: - Backdrop

/// The window background, washed with the current range colour. Neutral unless fresh.
struct WidgetBackdrop: View {
    var tint: Color
    var intensity: Double = 0.9

    var body: some View {
        ZStack {
            Palette.windowBackground
            AmbientGlow(tint: tint, intensity: intensity)
        }
    }
}

/// The Glucose widget's background: the Signal range field (docs/Redesign.md §9), still, in the
/// reading's colour. Grey once the reading is stale, and plain in the accented and vibrant modes,
/// where colour is gone anyway. The urgent-low border is `UrgentLowBorder`, in the foreground, so
/// StandBy (which removes the container background) still shows it.
///
/// Nothing drifts here: widgets run no timers. Between two timeline entries the system cross-fades
/// the field to the new colour, which is the still-frame version of the sweep.
struct SignalWidgetBackdrop: View {
    let entry: GlucoseEntry
    @Environment(\.widgetRenderingMode) private var mode

    private var fresh: Bool { entry.freshness == .fresh }

    var body: some View {
        ZStack {
            Palette.windowBackground
            if mode.isFullColor {
                RangeField(tone: entry.tone, intensity: fresh ? 0.95 : 0.6, range: fresh ? entry.snapshot.range : nil)
            }
        }
    }
}

/// A 2 pt crimson border inside the widget's edge while a fresh reading is urgent low (§3.1), so it
/// reads without colour vision too, beside the pill's symbol and words. Drawn over the foreground
/// and pushed out past the content margins to the widget's edge, so it survives StandBy and the
/// other places WidgetKit removes the background.
struct UrgentLowBorder: ViewModifier {
    let entry: GlucoseEntry
    @Environment(\.widgetContentMargins) private var margins

    func body(content: Content) -> some View {
        content.overlay {
            if entry.freshness == .fresh, entry.snapshot.range == .urgentLow {
                ContainerRelativeShape()
                    .strokeBorder(GlucoseRange.urgentLow.tint, lineWidth: 2)
                    .padding(EdgeInsets(top: -margins.top, leading: -margins.leading,
                                        bottom: -margins.bottom, trailing: -margins.trailing))
                    .widgetAccentable()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Status pill

/// "In range", "Low", "Stale"… with the matching icon. Always legible without colour.
struct StatusPill: View {
    let entry: GlucoseEntry
    var compact = false
    @Environment(\.widgetRenderingMode) private var mode

    private var content: (label: String, icon: String) {
        let s = entry.snapshot
        // Ten minutes without a reading: why, where GlucOS can tell (`WidgetGap`), calmly.
        if entry.freshness != .fresh, let gap = WidgetGap.state(s, at: entry.date) {
            return (gap.reason?.short ?? "No readings", gap.reason?.systemImage ?? "clock")
        }
        switch entry.freshness {
        case .fresh:
            let r = s.range ?? .inRange
            return (r.label, r.systemImage)
        case .stale:
            return ("Stale", "exclamationmark.triangle.fill")
        case .expired:
            return (s.lastError == nil ? "No recent data" : "Can't connect", "wifi.exclamationmark")
        case .none:
            return (s.lastError == nil ? "No data" : "Can't connect", "drop.degreesign.slash")
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A new range pushes the pill in the direction of travel (§4.2): up from below when the
    /// reading rose into it, down from above when it fell. The system plays it between two timeline
    /// entries; a cross-fade under Reduce Motion.
    private var swap: AnyTransition {
        if reduceMotion { return .opacity }
        // "Stale" and the no-readings words fade in and out, like the line under the figure
        // (`WidgetGapMotion`): nothing is travelling up or down while there are no readings.
        if entry.freshness != .fresh { return .opacity }
        let falling = (entry.snapshot.deltaMgdl ?? 0) < 0
        return .push(from: falling ? .top : .bottom)
    }

    var body: some View {
        let c = content
        let full = mode.isFullColor
        HStack(spacing: 3) {
            Image(systemName: c.icon)
                .imageScale(.small)
                .widgetAccentable()
            Text(c.label)
                .textCase(.uppercase)
                .tracking(0.3)
        }
        .id(c.label)
        .transition(swap)
        .font(.system(size: compact ? 9.5 : 10.5, weight: .bold))
        .foregroundStyle(full ? AnyShapeStyle(entry.tint) : AnyShapeStyle(HierarchicalShapeStyle.primary))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, compact ? 6 : 7)
        .padding(.vertical, 3)
        .background(full ? entry.tint.opacity(0.15) : Color.primary.opacity(0.1), in: Capsule())
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(Capsule())
        // Not `dsAnimation`: that drops the animation under Reduce Motion, and the swap there is
        // meant to be a cross-fade, which moves nothing.
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : DSMotion.standard.animation, value: c.label)
        .accessibilityHidden(true)
    }
}

// MARK: - Hero value

/// The big number. Withdrawn (shown as dashes) once the reading is over 30 minutes old.
struct HeroValue: View {
    let entry: GlucoseEntry
    var size: CGFloat
    var showsUnit = true
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var valueStyle: AnyShapeStyle {
        switch entry.freshness {
        case .fresh:
            return mode.isFullColor ? AnyShapeStyle(entry.snapshot.range?.valueColor ?? .primary)
                                    : AnyShapeStyle(HierarchicalShapeStyle.primary)
        default:
            return AnyShapeStyle(HierarchicalShapeStyle.secondary)
        }
    }

    var body: some View {
        let s = entry.snapshot
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Group {
                if let cur = s.current, entry.freshness.showsValue {
                    Text(s.unit.format(mgdl: cur.mgdl))
                        .foregroundStyle(valueStyle)
                        // Counts over to the next reading and cross-fades its colour (§6.5).
                        .readingChange(mgdl: cur.mgdl, tone: entry.freshness == .fresh
                                       ? s.range.map(Tone.glucose) ?? .neutral : .stale)
                        // The same drawn line as the apps and the Live Activity (§4.3), in every
                        // rendering mode: stale is never only a colour.
                        .staleStrike(entry.freshness == .stale, thickness: max(2, size * 0.05))
                        .widgetAccentable()
                        .gapPhaseTransition()
                } else {
                    // The number withdrawn half an hour into a gap fades to dashes, and the first
                    // reading after it fades back in.
                    Text("––").foregroundStyle(.tertiary)
                        .gapPhaseTransition()
                }
            }
            .animation(GapSwapTiming.animation(reduceMotion: reduceMotion), value: entry.freshness.showsValue)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.55)
            .lineLimit(1)
            .invalidatableContent()

            if showsUnit, entry.freshness.showsValue {
                Text(s.unit.label)
                    .font(.system(size: max(9, size * 0.2), weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.snapshot.accessibilitySummary(at: entry.date))
    }
}

// MARK: - Detail line

/// Trend, change and age, e.g. "Rising · +0.3 · 2m ago". Ten minutes after the last reading,
/// "No readings for 12 min" instead (`WidgetGap`, the chart's gap words), with the last value once
/// the number is withdrawn, so it's clear the dashes aren't a sensor fault you can ignore.
struct DetailLine: View {
    let entry: GlucoseEntry
    var showsTrendWord = true
    /// The age as a ticking timer (`ReadingAge`) instead of "2 min ago", which only changes when
    /// the timeline does.
    var live = true

    var body: some View {
        let s = entry.snapshot
        let motion = WidgetGapMotion.key(s, at: entry.date)
        Group {
            if let cur = s.current, let gap = WidgetGap.state(s, at: entry.date) {
                // "No readings for 12 min", and once the number has gone, what it was. The words
                // fade in over the reading's line, the minutes roll with the timeline's
                // per-minute entries, and the line fades back when readings resume
                // (`WidgetGapMotion`). Nothing ticks between entries.
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                    if entry.freshness == .expired {
                        ViewThatFits(in: .horizontal) {
                            Text("\(WidgetGap.headline(gap)) · last \(s.unit.format(mgdl: cur.mgdl))")
                                .gapMinutesRoll(motion)
                            Text(WidgetGap.headline(gap))
                                .gapMinutesRoll(motion)
                        }
                    } else {
                        Text(WidgetGap.headline(gap))
                            .gapMinutesRoll(motion)
                    }
                }
                .foregroundStyle(.secondary)
                .gapPhaseTransition()
            } else if let cur = s.current {
                Group {
                    switch entry.freshness {
                    case .fresh, .stale:
                        HStack(spacing: 4) {
                            if showsTrendWord, entry.freshness == .fresh, cur.trend != .unknown {
                                Text(cur.trend.description).fontWeight(.semibold)
                            }
                            if let d = s.deltaMgdl {
                                Text(s.unit.formatDelta(mgdl: d)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            AgeLabel(entry: entry, live: live)
                        }
                    case .expired, .none:
                        HStack(spacing: 3) {
                            Image(systemName: "clock.badge.exclamationmark")
                            Text("Last \(s.unit.format(mgdl: cur.mgdl)) at \(cur.timestamp.formatted(date: .omitted, time: .shortened))")
                        }
                        .foregroundStyle(Tone.warning.textColor)
                    }
                }
                .gapPhaseTransition()
            } else {
                Text(s.lastError == nil ? "Waiting for GlucOS" : "Open GlucOS to reconnect")
                    .foregroundStyle(.secondary)
            }
        }
        .gapSwapAnimation(motion)
        .font(.caption2.weight(.medium))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .accessibilityHidden(true)
    }
}

/// How old the reading is. Live: a count-up timer the system ticks between timeline entries
/// (`ReadingAge`, §9 "age timer"). Otherwise the age at the entry's date, in words.
struct AgeLabel: View {
    let entry: GlucoseEntry
    var live = true

    var body: some View {
        if let cur = entry.snapshot.current {
            let stale = entry.freshness != .fresh
            if live {
                ReadingAge(readingDate: cur.timestamp, stale: stale, timerWidth: 36)
            } else {
                words(cur, stale: stale)
            }
        }
    }

    private func words(_ cur: GlucoseReading, stale: Bool) -> some View {
        HStack(spacing: 2) {
            if stale { Image(systemName: "exclamationmark.triangle.fill").imageScale(.small) }
            Text(Format.age(cur.age(at: entry.date)))
        }
        .foregroundStyle(stale ? AnyShapeStyle(Tone.warning.textColor) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
        .monospacedDigit()
    }
}

// MARK: - Footer

/// The forecast note and the freshness meter on one line (§9, medium and up): "≈ 6.8 in 30 min"
/// or the amber "Low ≈ 20 min" on the left, the meter filling over the reading's life on the
/// right. The meter fills live between timeline entries; the note only while the reading is fresh.
struct WidgetSignalFooter: View {
    let entry: GlucoseEntry
    var meterWidth: CGFloat = 36

    var body: some View {
        let s = entry.snapshot
        if let cur = s.current, entry.freshness.showsValue {
            let fresh = entry.freshness == .fresh
            let outlook = fresh ? s.currentOutlook(at: entry.date) : nil
            let back = fresh ? s.backInRange(at: entry.date)?.minutes : nil
            let noteKind = outlook?.lowExpectedAt != nil ? "low" : back != nil ? "back" : "forecast"
            HStack(spacing: 6) {
                if let outlook {
                    ForecastNote(unit: s.unit,
                                 headline: OutlookFormat.headlineSample(outlook).map { (minutes: $0.minutes, mgdl: $0.sample.mgdl) },
                                 lowExpectedAt: outlook.lowExpectedAt,
                                 backInRangeMinutes: back,
                                 readingDate: cur.timestamp, compact: true)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .minimumScaleFactor(0.8)
                        .id(noteKind)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
                FreshnessMeter(readingDate: cur.timestamp, stale: !fresh, tint: entry.tint, width: meterWidth)
                    .widgetAccentable()
            }
            .dsAnimation(.standard, value: noteKind)
        }
    }
}

// MARK: - Trend

/// The trend dial, or nothing when the reading can't be trusted (a stale arrow is misleading).
struct WidgetTrend: View {
    let entry: GlucoseEntry
    var size: CGFloat

    var body: some View {
        if let cur = entry.snapshot.current, entry.freshness == .fresh {
            TrendDial(trend: cur.trend, tint: entry.tint, size: size)
                .widgetAccentable()
                .accessibilityHidden(true)
        } else {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: max(1.5, size * 0.04), dash: [3, 3]))
                .overlay(Image(systemName: "questionmark").font(.system(size: size * 0.34, weight: .bold)).foregroundStyle(.secondary))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Buttons

/// Asks the app for a new reading. Works without opening the popover.
struct RefreshButton: View {
    var size: CGFloat = 24

    var body: some View {
        Button(intent: RefreshGlucoseIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: size * 0.46, weight: .bold))
                .frame(width: size, height: size)
                .background(Color.primary.opacity(0.09), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Refresh glucose")
    }
}

/// Opens the pop-out dashboard.
struct DashboardLink: View {
    var size: CGFloat = 24

    var body: some View {
        Link(destination: URL(string: "glucos://dashboard")!) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: size * 0.44, weight: .bold))
                .frame(width: size, height: size)
                .background(Color.primary.opacity(0.09), in: Circle())
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel("Open dashboard")
    }
}

// MARK: - Stat cell

struct WidgetStat: View {
    let title: String
    let value: String
    var dot: Color? = nil
    var valueSize: CGFloat = 14
    /// The number behind `value`, so it rolls to the next timeline's figure instead of swapping.
    var numeric: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                if let dot { Circle().fill(dot).frame(width: 5, height: 5) }
                Text(title)
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            Text(value)
                .font(.system(size: valueSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .contentTransition(.numericText(value: numeric ?? 0))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Chart

/// The widget's glucose chart. Unlike the popover chart it runs to "now" on the right edge, so
/// missing data shows up as an empty stretch before the dashed now line, and the trace breaks
/// over gaps instead of drawing a confident line between two distant readings.
struct WidgetChart: View {
    let snapshot: GlucoseSnapshot
    let now: Date
    let hours: Double
    /// Colour for the latest point and the fill: grey unless the reading is fresh.
    let tint: Color
    var showsAxes = false
    var lineWidth: CGFloat = 2.25

    private struct Segment: Identifiable {
        let id: Int
        let points: [GlucoseReading]
        let style: LinearGradient
    }

    private var start: Date { now.addingTimeInterval(-hours * 3600) }

    private var window: [GlucoseReading] {
        var points = snapshot.history
        if let cur = snapshot.current, !points.contains(where: { $0.timestamp == cur.timestamp }) { points.append(cur) }
        return points.filter { $0.timestamp >= start && $0.timestamp <= now.addingTimeInterval(60) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private func segments(_ window: [GlucoseReading]) -> [Segment] {
        var groups: [[GlucoseReading]] = []
        for r in window {
            if let prev = groups.last?.last, r.timestamp.timeIntervalSince(prev.timestamp) <= 20 * 60 {
                groups[groups.count - 1].append(r)
            } else {
                groups.append([r])
            }
        }
        return groups.enumerated().map { i, pts in
            let values = pts.map(\.mgdl)
            return Segment(id: i, points: pts,
                           style: ThresholdGradient.style(minMgdl: values.min() ?? 0, maxMgdl: values.max() ?? 0,
                                                          low: snapshot.lowMgdl, high: snapshot.highMgdl))
        }
    }

    private func yDomain(_ window: [GlucoseReading]) -> ClosedRange<Double> {
        let values = window.map(\.mgdl) + [snapshot.lowMgdl, snapshot.highMgdl]
        let lo = min(values.min() ?? 60, 60) - 8
        let hi = max(values.max() ?? 200, 200) + 8
        return snapshot.unit.value(fromMgdl: lo)...snapshot.unit.value(fromMgdl: hi)
    }

    var body: some View {
        let window = self.window
        let segs = segments(window)
        let domain = yDomain(window)
        let unit = snapshot.unit
        let last = window.last
        let gapToNow = last.map { now.timeIntervalSince($0.timestamp) } ?? .infinity

        Chart {
            RectangleMark(xStart: .value("Start", start), xEnd: .value("Now", now),
                          yStart: .value("Low", unit.value(fromMgdl: snapshot.lowMgdl)),
                          yEnd: .value("High", unit.value(fromMgdl: snapshot.highMgdl)))
                .foregroundStyle(GlucoseRange.inRange.tint.opacity(0.09))

            RuleMark(y: .value("Low", unit.value(fromMgdl: snapshot.lowMgdl)))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                .foregroundStyle(GlucoseRange.inRange.tint.opacity(0.45))
            RuleMark(y: .value("High", unit.value(fromMgdl: snapshot.highMgdl)))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                .foregroundStyle(GlucoseRange.inRange.tint.opacity(0.45))

            ForEach(segs) { seg in
                ForEach(seg.points) { r in
                    AreaMark(x: .value("Time", r.timestamp),
                             yStart: .value("Floor", domain.lowerBound),
                             yEnd: .value("Glucose", unit.value(fromMgdl: r.mgdl)),
                             series: .value("Segment", seg.id))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [tint.opacity(0.24), tint.opacity(0)],
                                                        startPoint: .top, endPoint: .bottom))
                }
            }

            ForEach(segs) { seg in
                ForEach(seg.points) { r in
                    LineMark(x: .value("Time", r.timestamp),
                             y: .value("Glucose", unit.value(fromMgdl: r.mgdl)),
                             series: .value("Segment", seg.id))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(seg.style)
                        .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                }
            }

            // Data stopped arriving: mark "now" so the empty stretch reads as missing, not flat.
            if gapToNow > GlucoseSnapshot.staleAfter {
                RuleMark(x: .value("Now", now))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .foregroundStyle(Tone.warning.color.opacity(0.7))
            }

            if let last {
                PointMark(x: .value("Time", last.timestamp), y: .value("Glucose", unit.value(fromMgdl: last.mgdl)))
                    .symbolSize(lineWidth * 70)
                    .foregroundStyle(tint.opacity(0.22))
                PointMark(x: .value("Time", last.timestamp), y: .value("Glucose", unit.value(fromMgdl: last.mgdl)))
                    .symbolSize(lineWidth * 24)
                    .foregroundStyle(Palette.windowBackground)
                PointMark(x: .value("Time", last.timestamp), y: .value("Glucose", unit.value(fromMgdl: last.mgdl)))
                    .symbolSize(lineWidth * 12)
                    .foregroundStyle(tint)
            }
        }
        .chartXScale(domain: start...now)
        .chartYScale(domain: domain)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: hours > 6 ? 3 : 1)) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel(format: .dateTime.hour())
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .chartXAxis(showsAxes ? .automatic : .hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [snapshot.lowMgdl, snapshot.highMgdl].map { unit.value(fromMgdl: $0) }) { v in
                AxisValueLabel {
                    if let d = v.as(Double.self) {
                        Text(unit == .mmol ? String(format: "%.1f", d) : String(format: "%.0f", d))
                            .font(.system(size: 9))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis(showsAxes ? .automatic : .hidden)
        .accessibilityLabel("Glucose chart, last \(Int(hours)) hours")
    }
}

/// Small uppercase caption above a widget section, e.g. "LAST 3H".
struct WidgetCaption: View {
    let text: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text.uppercased()).tracking(0.5)
        }
        .font(.system(size: 9.5, weight: .bold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
