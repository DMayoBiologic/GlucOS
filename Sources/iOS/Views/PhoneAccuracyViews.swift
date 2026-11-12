import SwiftUI

/// How the forecasts shown on this iPhone turned out over the last week, and whether the trend
/// timing has been tuned to the user. Hidden until there's something to report.
struct PhoneForecastAccuracyCard: View {
    @EnvironmentObject var store: GlucoseStore
    @ObservedObject var outlook: OutlookStore
    @ObservedObject var ledger: ForecastLedgerStore

    init(outlook: OutlookStore) {
        self.outlook = outlook
        self.ledger = outlook.ledger
    }

    var body: some View {
        let week = ledger.lastWeek
        if !week.all.isEmpty {
            card(week)
        }
    }

    private func card(_ week: LiveAccuracy) -> some View {
        let unit = store.snapshot.unit
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack {
                Eyebrow(title: "Forecast accuracy", systemImage: "checkmark.seal")
                Spacer(minLength: 0)
                if outlook.model.tuning.isTuned {
                    TonePill(text: "Tuned to you", tone: .brand)
                }
            }
            ForEach([15, 30, 60], id: \.self) { m in
                if let h = week.clean(at: m) ?? week.all(at: m) {
                    HStack {
                        Text("\(m) min ahead").dsFont(.callout)
                        Spacer(minLength: DS.Space.sm)
                        Text("±\(unit.format(mgdl: h.meanAbsoluteError)) \(unit.label)")
                            .dsFont(.callout)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                        Text("· \(h.checks) checks").dsFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let line = ForecastAccuracyText.trendLine(lastWeek: week, before: ledger.weeksBefore, unit: unit) {
                Text(line).dsFont(.caption).fixedSize(horizontal: false, vertical: true)
            }
            Text("Typical error of the forecasts shown here in the last 7 days, when nothing was logged afterwards. \(ForecastAccuracyText.tuningLine(outlook.model.tuning))")
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard(.standard, padding: DS.Space.lg)
    }
}
