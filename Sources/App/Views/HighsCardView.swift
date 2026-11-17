import SwiftUI

/// The Insights "Highs" card on the Mac and iPhone, beside Lows: the share of the last 7, 14 or 30
/// days spent above range, how many highs there were, and the longest one (`HighsSummary`). Worked
/// out off the main thread once per data change (`HighsSummaryCache`).
///
/// Motion is the Lows card's: the figures count up where `figuresCountUp` is on (iPhone and Mac
/// Insights) and roll to new values when the period changes; the sentences cross-fade. Nothing
/// loops, and Reduce Motion shows the new values at once. Callers give it their own card surface.
///
/// With `openLogbook`, tapping the card (or its "See the last 14 days in the Logbook" row) opens the
/// Logbook on the Highs chip over the same days (`LogbookLink.highs`). The iPhone zooms the card
/// into it; the Mac cross-fades to its Logbook section (docs/LogbookSearch.md, "From the Lows and
/// Highs cards").
struct HighsCardView: View {
    let readings: [GlucoseReading]
    let unit: GlucoseUnit
    let highMgdl: Double
    var openLogbook: ((LogbookLink) -> Void)? = nil

    @AppStorage("insights.highsDays") private var periodDays = HighsSummary.Period.fortnight.rawValue
    @State private var value: HighsSummary?
    @State private var shownKey: HighsSummaryCache.Key?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var period: HighsSummary.Period { HighsSummary.Period(rawValue: periodDays) ?? .fortnight }
    /// "10.0 mmol/L".
    private var highLine: String { "\(unit.format(mgdl: highMgdl)) \(unit.label)" }
    private func peak(_ mgdl: Double) -> String { "\(unit.format(mgdl: mgdl)) \(unit.label)" }

    var body: some View {
        let key = HighsSummaryCache.key(readings: readings, high: highMgdl, period: period)
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Eyebrow(title: HighsSummaryText.title, systemImage: "arrow.up.to.line", trailing: "Above \(highLine)")
            Picker("Period", selection: $periodDays) {
                ForEach(HighsSummary.Period.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Period")

            // While another period is worked out the last one stays up, so its figures roll to the
            // new ones rather than blanking.
            if let value {
                content(value)
            } else if shownKey == key {
                Text(HighsSummaryText.emptyLine(period))
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
            let new: HighsSummary?
            if let hit = HighsSummaryCache.shared.cached(key) {
                new = hit
            } else {
                new = await HighsSummaryCache.shared.value(for: key, readings: readings)
            }
            // The figures roll by themselves; the sentences and tile colours cross-fade alongside.
            if value == nil || new == nil {
                value = new
            } else {
                DS.animate(.standard, reduceMotion: reduceMotion) { value = new }
            }
            shownKey = key
        }
    }

    @ViewBuilder
    private func content(_ s: HighsSummary) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(HighsSummaryText.headline(s))
                .dsFont(.headline)
                .fixedSize(horizontal: false, vertical: true)
            DSAccessibleStack(verticalAlignment: .top, spacing: DS.Space.md) {
                StatTile("Time above", value: HighsSummaryText.percent(s.timeAbove),
                         caption: HighsSummaryText.perDayCaption(s),
                         tone: s.timeAbove > 0 ? .glucose(.high) : .neutral,
                         rolling: .init(s.timeAbove) { HighsSummaryText.percent($0) })
                StatTile("Highs", value: HighsSummaryText.countValue(s.count),
                         rolling: .init(Double(s.count), order: 1) { HighsSummaryText.countValue(Int($0.rounded())) })
                if let longest = s.longest {
                    StatTile("Longest", value: LowsSummaryText.duration(longest.minutes),
                             rolling: .init(longest.minutes, order: 2) { LowsSummaryText.duration($0) })
                }
            }
            .monospacedDigit()
            InsightsSparklineView(series: InsightsSparkline.highs(s), tint: GlucoseRange.high.tint,
                                  label: HighsSummaryText.sparklineLabel)
            if let line = HighsSummaryText.longestLine(s, peak: peak) {
                Text(line)
                    .dsFont(.callout)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(HighsSummaryText.footnote(s, highLine: highLine))
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // One stop for VoiceOver: the period's highs in a few sentences.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(HighsSummaryText.title)
        .accessibilityValue([HighsSummaryText.spoken(s, highLine: highLine, peak: peak),
                             InsightsSparkline.highs(s).spokenLine(label: HighsSummaryText.sparklineLabel)]
            .compactMap { $0 }.joined(separator: " "))
        // The figures open the Logbook too, not just the row under them. The period picker stays
        // its own control.
        .contentShape(Rectangle())
        .onTapGesture { if s.count > 0 { open(s) } }
        if s.count > 0, openLogbook != nil {
            Button { open(s) } label: {
                HStack(spacing: DS.Space.xs) {
                    Text(HighsSummaryText.logbookLine(s.period))
                    Spacer(minLength: DS.Space.sm)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .dsFont(.label)
                .foregroundStyle(Palette.brand)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(HighsSummaryText.logbookHint)
        }
    }

    /// The Highs chip over the days the card counted, up to its newest reading.
    private func open(_ s: HighsSummary) {
        guard let openLogbook else { return }
        openLogbook(.highs(s.period, newestReading: s.end, now: Date()))
    }
}
