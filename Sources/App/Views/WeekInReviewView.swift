import SwiftUI

/// The Insights "Week in review" card on the Mac and iPhone: time in range, the average and lows
/// over the last 7 days beside the 7 before, and the best and hardest part of the day this week.
/// Worked out off the main thread once per data change (`WeekInReviewCache`) and drawn still:
/// nothing here animates or runs a timer (docs/Redesign.md power rules). Callers give it their own
/// card surface.
struct WeekInReviewView: View {
    let readings: [GlucoseReading]
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double

    @State private var value: WeekInReview?
    @State private var shownKey: WeekInReviewCache.Key?

    var body: some View {
        let key = WeekInReviewCache.key(readings: readings, low: lowMgdl, high: highMgdl)
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Eyebrow(title: WeekInReviewText.title, systemImage: "calendar", trailing: WeekInReviewText.period)
            if let value {
                content(value)
            } else if shownKey == key {
                Text(WeekInReviewText.emptyLine)
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Working it out: hold the space without a spinner.
                Color.clear.frame(height: 120)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: key) {
            if let hit = WeekInReviewCache.shared.cached(key) {
                value = hit
            } else {
                value = await WeekInReviewCache.shared.value(for: key, readings: readings)
            }
            shownKey = key
        }
    }

    @ViewBuilder
    private func content(_ w: WeekInReview) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(WeekInReviewText.headline(w))
                .dsFont(.headline)
                .fixedSize(horizontal: false, vertical: true)
            DSAccessibleStack(verticalAlignment: .top, spacing: DS.Space.md) {
                StatTile("In range", value: Format.percent(w.thisWeek.timeInRange),
                         caption: WeekInReviewText.rangeCaption(w),
                         tone: w.rangeChange == .better ? .success : .neutral)
                StatTile("Average", value: unit.format(mgdl: w.thisWeek.meanMgdl), unit: unit.label,
                         caption: WeekInReviewText.meanCaption(w, unit: unit),
                         tone: .glucose(GlucoseRange.classify(mgdl: w.thisWeek.meanMgdl, low: lowMgdl, high: highMgdl)))
                StatTile("Lows", value: WeekInReviewText.lowsValue(w.thisWeek.lows),
                         caption: WeekInReviewText.lowsCaption(w),
                         tone: w.thisWeek.lows > 0 ? .glucose(.low) : .neutral)
            }
            .monospacedDigit()
            let lines = WeekInReviewText.lines(w)
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    ForEach(lines, id: \.self) {
                        Text($0)
                            .dsFont(.callout)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text(WeekInReviewText.footnote(w))
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // One stop for VoiceOver: the whole week in a few sentences.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WeekInReviewText.title)
        .accessibilityValue(WeekInReviewText.spoken(w, unit: unit))
    }
}
