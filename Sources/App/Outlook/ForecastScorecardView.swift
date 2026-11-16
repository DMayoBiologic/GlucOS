import SwiftUI

/// The Insights card on the Mac and iPhone, and the top of the Outlook page's shown-forecasts
/// card: the typical error at 15, 30 and 60 minutes next to "no change", and how often the
/// reading landed inside the range. Callers hide it while `ForecastLedgerStore.scorecard` is nil
/// and give it their own card surface.
struct ForecastScorecardView: View {
    let card: ForecastScorecard
    let unit: GlucoseUnit
    /// The installed version's own figures, shown under the 7-day ones.
    var sinceUpdate: ForecastSinceUpdate? = nil
    var tuned = false
    /// Off on the Outlook page, which has its own header.
    var showsHeader = true

    @State private var drawn: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            if let sinceUpdate {
                versionView(sinceUpdate)
            }
            VStack(alignment: .leading, spacing: DS.Space.md) {
                ForEach(Array(card.rows.enumerated()), id: \.element.minutes) { order, row in
                    rowView(row, order: order)
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

    private func rowView(_ row: ForecastScorecard.Row, order: Int) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            DSAdaptiveRow(minMainWidth: 120, spacing: DS.Space.sm, verticalSpacing: DS.Space.xxs, alignment: .firstTextBaseline) {
                Text("\(row.minutes) min ahead").dsFont(.callout)
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                    RollingFigure(row.error, order: order) {
                        ForecastScorecardText.error($0, unit: unit)
                    }
                    .dsFont(.callout)
                    .fontWeight(.semibold)
                    RollingFigure(row.noChange, order: order) {
                        ForecastScorecardText.noChange($0, unit: unit)
                    }
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                }
                .monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 3) {
                bar(row.error, color: Palette.brand, order: order)
                bar(row.noChange, color: Palette.stale.opacity(0.55), order: order)
            }
            .accessibilityHidden(true)
            HStack(spacing: 0) {
                Text("\(ForecastScorecardText.comparison(row)) · ")
                RollingFigure(Double(row.checks), order: order) { "\(Int($0.rounded())) checks" }
            }
            .dsFont(.caption)
            .foregroundStyle(row.comparison == .better ? AnyShapeStyle(Palette.brandText) : AnyShapeStyle(.secondary))
            .monospacedDigit()
            .dsAnimation(.ambient, value: row.comparison)
            if let sinceUpdate, let line = ForecastScorecardText.sinceUpdateRow(sinceUpdate, minutes: row.minutes, unit: unit) {
                Label(line, systemImage: "arrow.up.circle")
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(row))
    }

    private func spoken(_ row: ForecastScorecard.Row) -> String {
        var s = ForecastScorecardText.spoken(row, unit: unit)
        if let sinceUpdate, let extra = ForecastScorecardText.sinceUpdateSpoken(sinceUpdate, minutes: row.minutes, unit: unit) {
            s += " " + extra
        }
        return s
    }

    /// Which version the figures cover: since the last update, or every forecast in the week.
    private func versionView(_ u: ForecastSinceUpdate) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Label(ForecastScorecardText.sinceUpdateTitle(u), systemImage: "arrow.up.circle")
                .dsFont(.caption)
                .fontWeight(.semibold)
            if let line = ForecastScorecardText.sinceUpdateCollecting(u) {
                Text(line).dsFont(.caption).foregroundStyle(.secondary)
            } else if !u.coversWeek {
                Text("Each line shows the last 7 days, with this version alone underneath.")
                    .dsFont(.caption).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    /// A row's bar. It grows from the leading edge with the card, a beat after the row above, and
    /// glides to a new length when the week's figures change (a new check, a new scale). Drawn at
    /// full length at once under Reduce Motion.
    private func bar(_ mgdl: Double, color: Color, order: Int) -> some View {
        GeometryReader { geo in
            Capsule()
                .fill(color)
                .frame(width: max(4, geo.size.width * min(1, mgdl / scale) * drawn))
        }
        .frame(height: 5)
        .animation(reduceMotion ? nil : DSMotion.arrival.animation.delay(0.1 + Double(min(order, 8)) * 0.06), value: drawn)
        .dsAnimation(.arrival, value: mgdl / scale)
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
                RollingFigure(card.insideRange) { "\(Int(($0 * 100).rounded()))%" }
                    .dsFont(.callout)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.stale.opacity(0.2))
                    Capsule().fill(Palette.brand)
                        .frame(width: geo.size.width * card.insideRange * drawn)
                        .dsAnimation(.arrival, value: card.insideRange)
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
