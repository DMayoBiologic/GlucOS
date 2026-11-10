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
            Color(nsColor: .windowBackgroundColor)
            AmbientGlow(tint: tint, intensity: intensity)
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
        .font(.system(size: compact ? 9.5 : 10.5, weight: .bold))
        .foregroundStyle(full ? AnyShapeStyle(entry.tint) : AnyShapeStyle(HierarchicalShapeStyle.primary))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, compact ? 6 : 7)
        .padding(.vertical, 3)
        .background(full ? entry.tint.opacity(0.15) : Color.primary.opacity(0.1), in: Capsule())
        .fixedSize(horizontal: false, vertical: true)
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
                        .strikethrough(entry.freshness == .stale && !mode.isFullColor, color: .secondary)
                        .foregroundStyle(valueStyle)
                        .contentTransition(.numericText(value: cur.mgdl))
                        .widgetAccentable()
                } else {
                    Text("––").foregroundStyle(.tertiary)
                }
            }
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

/// Trend, change and age, e.g. "Rising · +0.3 · 2m ago". For an expired reading, what the last
/// value was and when, so it's clear the dashes aren't a sensor fault you can ignore.
struct DetailLine: View {
    let entry: GlucoseEntry
    var showsTrendWord = true

    var body: some View {
        let s = entry.snapshot
        Group {
            if let cur = s.current {
                switch entry.freshness {
                case .fresh, .stale:
                    HStack(spacing: 4) {
                        if showsTrendWord, entry.freshness == .fresh, cur.trend != .unknown {
                            Text(cur.trend.description).fontWeight(.semibold)
                        }
                        if let d = s.deltaMgdl {
                            Text(s.unit.formatDelta(mgdl: d)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        AgeLabel(entry: entry)
                    }
                case .expired, .none:
                    HStack(spacing: 3) {
                        Image(systemName: "clock.badge.exclamationmark")
                        Text("Last \(s.unit.format(mgdl: cur.mgdl)) at \(cur.timestamp.formatted(date: .omitted, time: .shortened))")
                    }
                    .foregroundStyle(Tone.warning.textColor)
                }
            } else {
                Text(s.lastError == nil ? "Waiting for GlucOS" : "Open GlucOS to reconnect")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2.weight(.medium))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .accessibilityHidden(true)
    }
}

struct AgeLabel: View {
    let entry: GlucoseEntry

    var body: some View {
        if let cur = entry.snapshot.current {
            let stale = entry.freshness != .fresh
            HStack(spacing: 2) {
                if stale { Image(systemName: "exclamationmark.triangle.fill").imageScale(.small) }
                Text(Format.age(cur.age(at: entry.date)))
            }
            .foregroundStyle(stale ? AnyShapeStyle(Tone.warning.textColor) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            .monospacedDigit()
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
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
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
