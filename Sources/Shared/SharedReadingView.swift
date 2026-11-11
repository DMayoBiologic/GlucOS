import SwiftUI

/// Someone's shared reading: value, delta, age and trend, then the last 3 hours. Used by the iPhone
/// app's following cards and by the live bubble in Messages, so both read the same.
struct SharedReadingView: View {
    let card: GlucoseActivityState
    let now: Date
    var valueSize: CGFloat = 44
    var dialSize: CGFloat = 52
    var chartHeight: CGFloat = 70

    var body: some View {
        let stale = card.isStale(at: now)
        let tone = card.range.tone(stale: stale)
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .center, spacing: DS.Space.md) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                        Text(card.valueText)
                            .font(.system(size: valueSize, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(stale ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(tone.color))
                            .strikethrough(stale, color: .secondary)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        Text(card.glucoseUnit.label).dsFont(.label).foregroundStyle(.secondary)
                    }
                    HStack(spacing: DS.Space.xs) {
                        if !stale, let delta = card.deltaText { Text(delta).monospacedDigit() }
                        Text(card.readingDate, style: .relative) + Text(" ago")
                    }
                    .dsFont(.caption)
                    .foregroundStyle(stale ? AnyShapeStyle(Tone.warning.textColor) : AnyShapeStyle(Color.secondary))
                }
                Spacer(minLength: DS.Space.sm)
                TrendDial(trend: stale ? .unknown : card.glucoseTrend, tint: tone.color, size: dialSize)
                    .opacity(stale ? 0.6 : 1)
                    .accessibilityHidden(true)
            }
            if chartHeight > 0 {
                GlucoseChart(readings: card.historyReadings, unit: card.glucoseUnit, lowMgdl: card.lowMgdl,
                             highMgdl: card.highMgdl, hours: GlucoseActivityState.historyHours, showAxes: false,
                             latestIsStale: stale)
                    .frame(height: chartHeight)
            }
        }
    }
}
