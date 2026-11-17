import SwiftUI

/// The "Today" card at the top of Insights when it's opened from the evening recap notification
/// (docs/EveningRecap.md): the recap's time in range, average, lows and highs, over the same hours
/// the notification covered. The figures count up as the card shows, once, like the rest of
/// Insights; no loop, still under Reduce Motion. Hidden when that day has too few readings.
struct EveningRecapCardView: View {
    let readings: [GlucoseReading]
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    let recapMinute: Int
    /// When the tapped notification went out: the day and hours to show.
    let firedAt: Date
    /// The card surface's padding; nil uses the card default (the Mac dashboard).
    var padding: CGFloat?

    @State private var value: EveningRecap?

    private struct Key: Hashable {
        var firedAt: Date
        var count: Int
        var low: Double
        var high: Double
        var minute: Int
    }

    var body: some View {
        let key = Key(firedAt: firedAt, count: readings.count, low: lowMgdl, high: highMgdl, minute: recapMinute)
        VStack(spacing: 0) {
            if let value { card(value) }
        }
        .task(id: key) {
            let readings = readings, low = lowMgdl, high = highMgdl, minute = recapMinute, now = firedAt
            value = await Task.detached(priority: .userInitiated) {
                EveningRecap.compute(readings: readings, low: low, high: high, minute: minute, now: now)
            }.value
        }
    }

    private func card(_ r: EveningRecap) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Eyebrow(title: EveningRecapText.cardTitle, systemImage: "moon.haze", trailing: EveningRecapText.period(r))
            Text(EveningRecapText.counts(r) + ".")
                .dsFont(.headline)
                .fixedSize(horizontal: false, vertical: true)
            DSAccessibleStack(verticalAlignment: .top, spacing: DS.Space.md) {
                StatTile("In range", value: Format.percent(r.timeInRange),
                         rolling: .init(r.timeInRange, order: 0) { Format.percent($0) })
                StatTile("Average", value: unit.format(mgdl: r.meanMgdl), unit: unit.label,
                         tone: .glucose(GlucoseRange.classify(mgdl: r.meanMgdl, low: lowMgdl, high: highMgdl)),
                         rolling: .init(r.meanMgdl, order: 1) { unit.format(mgdl: $0) })
                StatTile("Lows", value: EveningRecapText.countValue(r.lows),
                         tone: r.lows > 0 ? .glucose(.low) : .neutral,
                         rolling: .init(Double(r.lows), order: 2) { EveningRecapText.countValue(Int($0.rounded())) })
                StatTile("Highs", value: EveningRecapText.countValue(r.highs),
                         tone: r.highs > 0 ? .glucose(.high) : .neutral,
                         rolling: .init(Double(r.highs), order: 3) { EveningRecapText.countValue(Int($0.rounded())) })
            }
            .monospacedDigit()
            Text("From your evening recap. Lows and highs are 15 minutes or more outside your target. Observations, not advice.")
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard(.standard, padding: padding)
        .environment(\.figuresCountUp, true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(EveningRecapText.cardTitle)
        .accessibilityValue(EveningRecapText.spoken(r, unit: unit))
    }
}

/// The recap's time for a `DatePicker` showing hours and minutes, stored as minutes after midnight.
extension AppSettings {
    var eveningRecapTime: Binding<Date> {
        Binding(get: {
            EveningRecap.time(self.eveningRecapMinute, on: Date())
        }, set: { date in
            let c = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
            self.eveningRecapMinute = EveningRecap.sanitized((c.hour ?? 21) * 60 + (c.minute ?? 0))
        })
    }
}
