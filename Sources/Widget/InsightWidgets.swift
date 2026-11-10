import WidgetKit
import SwiftUI

// MARK: - Time in Range

struct TimeInRangeWidget: Widget {
    let kind = "au.com.declanmayo.glucos.time-in-range"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: TimeInRangeIntent.self, provider: TimeInRangeProvider()) { entry in
            TimeInRangeWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetBackdrop(tint: entry.summary == nil ? Palette.stale : Palette.brand, intensity: 0.45)
                }
                .widgetURL(URL(string: "glucos://dashboard"))
        }
        .configurationDisplayName("Time in Range")
        .description("How much of the last day or weeks you spent in each range.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct TimeInRangeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: InsightEntry

    var body: some View {
        if let sum = entry.summary {
            if family == .systemSmall { small(sum) } else { medium(sum) }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                WidgetCaption(text: "Time in range · \(entry.period.shortLabel)", systemImage: "chart.pie")
                Spacer(minLength: 0)
                Text("No readings yet")
                    .font(.headline)
                Text("GlucOS builds this up while it runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func ring(_ sum: RangeSummary, lineWidth: CGFloat) -> some View {
        TimeInRangeRing(segments: sum.segments, inRange: sum.inRange, lineWidth: lineWidth)
    }

    /// Libre's history is sparse when the Mac was asleep or GlucOS wasn't running. Say so rather
    /// than present a partial picture as the whole one.
    @ViewBuilder
    private func coverageNote(_ sum: RangeSummary) -> some View {
        if sum.coverage < 0.7 {
            Label("\(Format.percent(sum.coverage)) of period has data", systemImage: "exclamationmark.circle")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func small(_ sum: RangeSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetCaption(text: "In range · \(entry.period.shortLabel)")
            ring(sum, lineWidth: 9)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if sum.coverage < 0.7 {
                coverageNote(sum)
            } else {
                HStack {
                    WidgetStat(title: "Below", value: Format.percent(sum.below), dot: GlucoseRange.low.tint, valueSize: 12)
                    WidgetStat(title: "Above", value: Format.percent(sum.above), dot: GlucoseRange.high.tint, valueSize: 12)
                }
            }
        }
    }

    private func medium(_ sum: RangeSummary) -> some View {
        let unit = entry.snapshot.unit
        return HStack(spacing: 14) {
            ring(sum, lineWidth: 10)
                .frame(width: 112)
            VStack(alignment: .leading, spacing: 4) {
                WidgetCaption(text: "Time in range · \(entry.period.shortLabel)", systemImage: "chart.pie")
                band("Very high", sum.veryHigh, .veryHigh)
                band("High", sum.high, .high)
                band("In range", sum.inRange, .inRange)
                band("Low", sum.low, .low)
                band("Urgent low", sum.urgentLow, .urgentLow)
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    miniFact("Avg", unit.format(mgdl: sum.meanMgdl))
                    miniFact("GMI", String(format: "%.1f%%", sum.gmiPercent))
                    miniFact("CV", Format.percent(sum.cv))
                }
                coverageNote(sum)
            }
        }
    }

    private func band(_ title: String, _ fraction: Double, _ range: GlucoseRange) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(range.tint)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            GeometryReader { geo in
                Capsule()
                    .fill(range.tint.opacity(0.85))
                    .frame(width: max(2, geo.size.width * fraction))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(width: 44, height: 4)
            Text(Format.percent(fraction))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private func miniFact(_ title: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(title).foregroundStyle(.secondary)
            Text(value).fontWeight(.bold).monospacedDigit()
        }
        .font(.system(size: 10.5))
        .lineLimit(1)
    }
}

// MARK: - Sensor

struct SensorWidget: Widget {
    let kind = "au.com.declanmayo.glucos.sensor"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SensorProvider()) { entry in
            SensorWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetBackdrop(tint: SensorWidgetView.tint(for: entry), intensity: 0.5) }
                .widgetURL(URL(string: "glucos://open"))
        }
        .configurationDisplayName("Sensor")
        .description("How long your current sensor has left.")
        .supportedFamilies([.systemSmall])
    }
}

struct SensorWidgetView: View {
    let entry: InsightEntry

    static func tint(for entry: InsightEntry) -> Color {
        guard let sensor = entry.snapshot.sensor else { return Palette.stale }
        let left = sensor.daysRemaining(at: entry.date)
        if left <= 0.5 { return GlucoseRange.low.tint }
        if left <= 1.5 { return GlucoseRange.high.tint }
        return Palette.brand
    }

    var body: some View {
        let tint = Self.tint(for: entry)
        VStack(alignment: .leading, spacing: 6) {
            WidgetCaption(text: "Sensor", systemImage: "sensor.tag.radiowaves.forward")
            if let sensor = entry.snapshot.sensor {
                let left = sensor.daysRemaining(at: entry.date)
                let fraction = left / Double(max(1, sensor.lifetimeDays))
                ZStack {
                    ProgressRing(fraction: fraction, tint: tint, lineWidth: 8)
                    VStack(spacing: -2) {
                        Text(left >= 1 ? "\(Int(left.rounded(.down)))" : "\(max(0, Int(left * 24)))")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text(left >= 1 ? (Int(left) == 1 ? "day left" : "days left") : (Int(left * 24) == 1 ? "hour left" : "hours left"))
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(left > 0 ? "Ends \(sensor.expires.formatted(.dateTime.weekday(.abbreviated).hour().minute()))" : "Sensor expired")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(left <= 1.5 ? AnyShapeStyle(tint) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                Spacer(minLength: 0)
                Text("No sensor info")
                    .font(.headline)
                Text("Shown once GlucOS has a reading.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Time in range", as: .systemMedium) {
    TimeInRangeWidget()
} timeline: {
    InsightEntry(date: .now, snapshot: .preview,
                 summary: RangeSummary(readings: GlucoseSnapshot.preview.history, low: 70, high: 180, span: 12 * 3600),
                 period: .last24Hours)
}

#Preview("Sensor", as: .systemSmall) {
    SensorWidget()
} timeline: {
    InsightEntry(date: .now, snapshot: .preview, summary: nil, period: .last24Hours)
}
