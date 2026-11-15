import SwiftUI

/// The Insights card on the Mac and iPhone, and the top of the Outlook page's shown-forecasts
/// card: the typical error at 15, 30 and 60 minutes next to "no change", and how often the
/// reading landed inside the range. Callers hide it while `ForecastLedgerStore.scorecard` is nil
/// and give it their own card surface.
struct ForecastScorecardView: View {
    let card: ForecastScorecard
    let unit: GlucoseUnit
    var tuned = false
    /// Off on the Outlook page, which has its own header.
    var showsHeader = true

    @State private var drawn: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            if showsHeader {
                HStack {
                    Eyebrow(title: ForecastScorecardText.title, systemImage: "scope", trailing: "Last 7 days")
                    if tuned {
                        TonePill(text: "Tuned to you", tone: .brand)
                    }
                }
            }
            VStack(alignment: .leading, spacing: DS.Space.md) {
                ForEach(card.rows, id: \.minutes) { row in
                    rowView(row)
                }
            }
            legend
            rangeView
            Text(ForecastScorecardText.footnote(device: ForecastLedgerStore.device))
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(DrawIn(enabled: true, progress: $drawn))
    }

    /// The largest figure on the card sets the bars' full width, so rows compare with each other.
    private var scale: Double {
        max(1, card.rows.map { max($0.error, $0.noChange) }.max() ?? 1)
    }

    private func rowView(_ row: ForecastScorecard.Row) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            DSAdaptiveRow(minMainWidth: 120, spacing: DS.Space.sm, verticalSpacing: DS.Space.xxs, alignment: .firstTextBaseline) {
                Text("\(row.minutes) min ahead").dsFont(.callout)
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                    Text(ForecastScorecardText.error(row.error, unit: unit))
                        .dsFont(.callout)
                        .fontWeight(.semibold)
                    Text(ForecastScorecardText.noChange(row, unit: unit))
                        .dsFont(.caption)
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 3) {
                bar(row.error, color: Palette.brand)
                bar(row.noChange, color: Palette.stale.opacity(0.55))
            }
            .accessibilityHidden(true)
            Text("\(ForecastScorecardText.comparison(row)) · \(row.checks) checks")
                .dsFont(.caption)
                .foregroundStyle(row.comparison == .better ? AnyShapeStyle(Palette.brandText) : AnyShapeStyle(.secondary))
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ForecastScorecardText.spoken(row, unit: unit))
    }

    private func bar(_ mgdl: Double, color: Color) -> some View {
        GeometryReader { geo in
            Capsule()
                .fill(color)
                .frame(width: max(4, geo.size.width * min(1, mgdl / scale) * drawn))
        }
        .frame(height: 5)
    }

    private var legend: some View {
        HStack(spacing: DS.Space.lg) {
            LegendSwatch(color: Palette.brand, label: "Forecast")
            LegendSwatch(color: Palette.stale.opacity(0.55), label: "No change")
        }
        .dsFont(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private var rangeView: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("Inside the likely range").dsFont(.callout)
                Spacer(minLength: DS.Space.sm)
                Text("\(card.insidePercent)%")
                    .dsFont(.callout)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.stale.opacity(0.2))
                    Capsule().fill(Palette.brand)
                        .frame(width: geo.size.width * card.insideRange * drawn)
                    // What the range aims for.
                    Rectangle()
                        .fill(Color.primary.opacity(0.6))
                        .frame(width: 1.5, height: 11)
                        .offset(x: geo.size.width * ForecastScorecard.rangeTarget - 0.75)
                }
            }
            .frame(height: 7)
            .accessibilityHidden(true)
            Text(ForecastScorecardText.rangeLine(card))
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct LegendSwatch: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Capsule().fill(color).frame(width: 14, height: 5)
            Text(label)
        }
    }
}
