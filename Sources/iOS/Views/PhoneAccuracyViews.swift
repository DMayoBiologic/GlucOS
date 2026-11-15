import SwiftUI

/// How close the forecasts shown on this iPhone came over the last week, against assuming no
/// change, and how often the reading landed inside the range. Hidden until there are enough
/// checks to be fair (`ForecastScorecard.minimumChecks`).
struct PhoneForecastAccuracyCard: View {
    @EnvironmentObject var store: GlucoseStore
    @ObservedObject var outlook: OutlookStore
    @ObservedObject var ledger: ForecastLedgerStore

    init(outlook: OutlookStore) {
        self.outlook = outlook
        self.ledger = outlook.ledger
    }

    var body: some View {
        if let card = ledger.scorecard {
            content(card)
        }
    }

    private func content(_ card: ForecastScorecard) -> some View {
        let unit = store.snapshot.unit
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            ForecastScorecardView(card: card, unit: unit, sinceUpdate: ledger.sinceUpdate, tuned: outlook.model.tuning.isTuned)
            if let line = ForecastAccuracyText.trendLine(lastWeek: ledger.lastWeek, before: ledger.weeksBefore, unit: unit) {
                Text(line).dsFont(.caption).fixedSize(horizontal: false, vertical: true)
            }
            Text("\(ForecastAccuracyText.tuningLine(outlook.model.tuning))\(ForecastAccuracyText.rangeLine(outlook.model.rangeScale).map { " " + $0 } ?? "")")
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard(.standard, padding: DS.Space.lg)
    }
}
