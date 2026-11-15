import SwiftUI

/// The "Today so far" card on the iPhone Today screen and the Mac dashboard: time in range, the
/// average and lows since midnight, each beside the same hours on your usual day. Worked out off
/// the main thread once per data change (`TodaySoFarCache`) and drawn still: nothing here animates
/// or runs a timer (docs/Redesign.md power rules). The card hides itself until today has an hour of
/// readings, so it never adds an empty box to the Today stack.
struct TodaySoFarView: View {
    let readings: [GlucoseReading]
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    /// The card surface's padding; nil uses the card default (the Mac dashboard).
    var padding: CGFloat?

    /// The same window as "Your usual day", so the two cards compare against the same days.
    @AppStorage("insights.dayPatternDays") private var windowDays = DayPattern.Window.fortnight.rawValue
    @State private var value: TodaySoFar?

    private var window: DayPattern.Window { DayPattern.Window(rawValue: windowDays) ?? .fortnight }

    var body: some View {
        let key = TodaySoFarCache.key(readings: readings, window: window, low: lowMgdl, high: highMgdl)
        VStack(spacing: 0) {
            if let value { card(value) }
        }
        .task(id: key) {
            if let hit = TodaySoFarCache.shared.cached(key) {
                value = hit
            } else {
                value = await TodaySoFarCache.shared.value(for: key, readings: readings)
            }
        }
    }

    private func card(_ t: TodaySoFar) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Eyebrow(title: TodaySoFarText.title, systemImage: "sun.max", trailing: TodaySoFarText.period(t))
            Text(TodaySoFarText.headline(t))
                .dsFont(.headline)
                .fixedSize(horizontal: false, vertical: true)
            DSAccessibleStack(verticalAlignment: .top, spacing: DS.Space.md) {
                StatTile("In range", value: Format.percent(t.today.timeInRange),
                         caption: TodaySoFarText.rangeCaption(t), tone: rangeTone(t))
                StatTile("Average", value: unit.format(mgdl: t.today.meanMgdl), unit: unit.label,
                         caption: TodaySoFarText.meanCaption(t, unit: unit),
                         tone: .glucose(GlucoseRange.classify(mgdl: t.today.meanMgdl, low: lowMgdl, high: highMgdl)))
                StatTile("Lows", value: TodaySoFarText.lowsValue(t.today.lows),
                         caption: TodaySoFarText.lowsCaption(t),
                         tone: t.today.lows > 0 ? .glucose(.low) : .neutral)
            }
            .monospacedDigit()
            Text(TodaySoFarText.footnote(t))
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard(.standard, padding: padding)
        // One stop for VoiceOver: the whole comparison in a few sentences.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TodaySoFarText.title)
        .accessibilityValue(TodaySoFarText.spoken(t, unit: unit))
    }

    /// Green when today's ahead of usual, neutral otherwise: the card observes, it doesn't scold.
    private func rangeTone(_ t: TodaySoFar) -> Tone {
        t.rangeChange == .better ? .success : .neutral
    }
}
