import SwiftUI

// Shared visual language for the menu bar popover and the widget, so a reading looks the same
// everywhere: one colour per range, SF Symbols for trend, and the same time-in-range bar.

extension GlucoseRange {
    /// The range's hue from the GlucOS palette (see Theme.swift). Adapts to light and dark mode.
    var color: Color { tint }

    /// Colour for the big number. In range stays `.primary` so the value reads as calm text.
    var valueColor: Color { self == .inRange ? .primary : color }

    var label: String {
        switch self {
        case .urgentLow: return "Urgent low"
        case .low: return "Low"
        case .inRange: return "In range"
        case .high: return "High"
        case .veryHigh: return "Very high"
        }
    }

    var systemImage: String {
        switch self {
        case .urgentLow: return "exclamationmark.octagon.fill"
        case .low: return "arrow.down.circle.fill"
        case .inRange: return "checkmark.circle.fill"
        case .high: return "arrow.up.circle.fill"
        case .veryHigh: return "exclamationmark.octagon.fill"
        }
    }
}

extension GlucoseUnit {
    /// Spoken form for VoiceOver ("mmol/L" is read letter by letter otherwise).
    var spokenLabel: String {
        switch self {
        case .mmol: return "millimoles per litre"
        case .mgdl: return "milligrams per decilitre"
        }
    }
}

extension GlucoseSnapshot {
    /// One sentence describing the current reading, for VoiceOver.
    func accessibilitySummary(at now: Date = Date()) -> String {
        guard let current else { return "No glucose reading" }
        var parts = ["Glucose \(unit.format(mgdl: current.mgdl)) \(unit.spokenLabel)"]
        if let range { parts.append(range.label) }
        if current.trend != .unknown { parts.append(current.trend.description) }
        if let d = deltaMgdl { parts.append("change \(unit.formatDelta(mgdl: d).replacingOccurrences(of: "−", with: "minus "))") }
        parts.append(Format.age(current.age(at: now)))
        if isStale(at: now) { parts.append("Data is stale") }
        return parts.joined(separator: ", ")
    }
}

/// Trend arrow as an SF Symbol, so it matches the weight and baseline of the surrounding text.
struct TrendSymbol: View {
    let trend: Trend

    var body: some View {
        Image(systemName: trend.systemImage)
            .fontWeight(.bold)
            .symbolRenderingMode(.hierarchical)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityLabel(trend.description)
    }
}

/// Small capsule naming the range ("In range", "Low"…), tinted with the range colour.
struct RangeBadge: View {
    let range: GlucoseRange
    var stale: Bool = false

    var body: some View {
        let tint = stale ? Palette.stale : range.color
        Label(stale ? "Stale" : range.label,
              systemImage: stale ? "exclamationmark.triangle.fill" : range.systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(tint.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 0.5))
            .fixedSize()
    }
}

/// Stacked below / in range / above bar, the way CGM reports present time in range.
struct TimeInRangeBar: View {
    let stats: GlucoseStats
    var height: CGFloat = 8

    private var segments: [(fraction: Double, color: Color)] {
        let all: [(fraction: Double, color: Color)] = [
            (stats.timeBelowRange, GlucoseRange.low.tint), (stats.timeInRange, GlucoseRange.inRange.tint),
            (stats.timeAboveRange, GlucoseRange.high.tint),
        ]
        return all.filter { $0.fraction > 0.001 }
    }

    var body: some View {
        GeometryReader { geo in
            let gaps = CGFloat(max(0, segments.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(segments.indices, id: \.self) { i in
                    Rectangle()
                        .fill(segments[i].color.gradient)
                        .frame(width: max(2, (geo.size.width - gaps) * segments[i].fraction))
                }
            }
        }
        .frame(height: height)
        .background(.quaternary, in: Capsule())
        .clipShape(Capsule())
        .accessibilityElement()
        .accessibilityLabel("Time in range")
        .accessibilityValue("\(Format.percent(stats.timeInRange)) in range, \(Format.percent(stats.timeBelowRange)) below, \(Format.percent(stats.timeAboveRange)) above")
    }
}
