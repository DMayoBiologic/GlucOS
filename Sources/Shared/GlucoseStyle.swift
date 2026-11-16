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

/// Small capsule naming the range ("In range", "Low"…), tinted with the range colour. Grey and
/// labelled "Stale" when the reading is old, so it can never reassure.
struct RangeBadge: View {
    let range: GlucoseRange
    var stale: Bool = false

    var body: some View {
        TonePill(text: stale ? "Stale" : range.label,
                   systemImage: stale ? "exclamationmark.triangle.fill" : range.systemImage,
                   tone: range.tone(stale: stale))
    }
}

/// Stacked below / in range / above bar, the way CGM reports present time in range.
struct TimeInRangeBar: View {
    let stats: GlucoseStats
    var height: CGFloat = 8
    /// Grows from the left when it first appears, with the ring beside it. App screens only; a
    /// widget always gets the full bar.
    var drawsIn: Bool = false
    @State private var progress: Double

    init(stats: GlucoseStats, height: CGFloat = 8, drawsIn: Bool = false) {
        self.stats = stats
        self.height = height
        self.drawsIn = drawsIn
        _progress = State(initialValue: drawsIn ? 0 : 1)
    }

    /// Below, in and above range, always all three in the same order, so a share that grows from
    /// nothing (a first low) widens into place rather than shifting the other colours along.
    private var segments: [(fraction: Double, color: Color)] {
        [(stats.timeBelowRange, GlucoseRange.low.tint), (stats.timeInRange, GlucoseRange.inRange.tint),
         (stats.timeAboveRange, GlucoseRange.high.tint)]
    }

    private static func shows(_ fraction: Double) -> Bool { fraction > 0.001 }

    var body: some View {
        GeometryReader { geo in
            let shown = segments.map { Self.shows($0.fraction) }
            let lastShown = shown.lastIndex(of: true)
            let gaps = CGFloat(max(0, shown.filter { $0 }.count - 1)) * 2
            HStack(spacing: 0) {
                ForEach(segments.indices, id: \.self) { i in
                    Rectangle()
                        .fill(segments[i].color.gradient)
                        .frame(width: shown[i] ? max(2, (geo.size.width - gaps) * segments[i].fraction) : 0)
                        // The 2-point gap after every shown share but the last.
                        .padding(.trailing, shown[i] && i != lastShown ? 2 : 0)
                }
            }
            .frame(width: geo.size.width * progress, alignment: .leading)
            .clipped()
        }
        .frame(height: height)
        .background(.quaternary, in: Capsule())
        .clipShape(Capsule())
        // Each share glides to its new width on a new period or new readings; instant under Reduce Motion.
        .dsAnimation(.emphasized, value: [stats.timeBelowRange, stats.timeInRange, stats.timeAboveRange])
        .modifier(DrawIn(enabled: drawsIn, progress: $progress))
        .accessibilityElement()
        .accessibilityLabel("Time in range")
        .accessibilityValue("\(Format.percent(stats.timeInRange)) in range, \(Format.percent(stats.timeBelowRange)) below, \(Format.percent(stats.timeAboveRange)) above")
    }
}
