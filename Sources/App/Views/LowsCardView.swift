import SwiftUI

/// The Insights "Lows" card on the Mac and iPhone: how many lows there were over the last 7, 14 or
/// 30 days, how long they usually lasted, how many were treated, and the time of day they start
/// (`LowsSummary`). Worked out off the main thread once per data change (`LowsSummaryCache`).
///
/// Motion follows the power rules in docs/Redesign.md: the time-of-day bars grow in once when the
/// card first shows, and the figures count up there where `figuresCountUp` is on (iPhone and Mac
/// Insights). A new period rolls each figure to its new value and glides the bars; nothing loops,
/// and Reduce Motion shows the new values at once. Callers give it their own card surface.
///
/// With `openLogbook`, tapping the card (or its "See these lows in the Logbook" row) opens the
/// Logbook on the Lows chip over the same days (`LogbookLink.lows`). The iPhone zooms the card
/// into it; the Mac cross-fades to its Logbook section (docs/LogbookSearch.md, "From the Insights cards").
struct LowsCardView: View {
    let readings: [GlucoseReading]
    let meals: [MealEntry]
    let contexts: [ContextEvent]
    let answers: [LowAnswer]
    let unit: GlucoseUnit
    let lowMgdl: Double
    var openLogbook: ((LogbookLink) -> Void)? = nil

    @AppStorage("insights.lowsDays") private var periodDays = LowsSummary.Period.fortnight.rawValue
    @State private var value: LowsSummary?
    @State private var shownKey: LowsSummaryCache.Key?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var period: LowsSummary.Period { LowsSummary.Period(rawValue: periodDays) ?? .fortnight }
    /// "3.9 mmol/L".
    private var lowLine: String { "\(unit.format(mgdl: lowMgdl)) \(unit.label)" }

    var body: some View {
        let key = LowsSummaryCache.key(readings: readings, meals: meals, contexts: contexts, answers: answers,
                                       low: lowMgdl, period: period)
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Eyebrow(title: LowsSummaryText.title, systemImage: "arrow.down.to.line", trailing: "Below \(lowLine)")
            Picker("Period", selection: $periodDays) {
                ForEach(LowsSummary.Period.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Period")

            // While another period is worked out the last one stays up, so its figures roll to the
            // new ones rather than blanking.
            if let value {
                content(value)
            } else if shownKey == key {
                Text(LowsSummaryText.emptyLine(period))
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Working it out: hold the space without a spinner.
                Color.clear.frame(height: 160)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: key) {
            let new: LowsSummary?
            if let hit = LowsSummaryCache.shared.cached(key) {
                new = hit
            } else {
                new = await LowsSummaryCache.shared.value(for: key, readings: readings, meals: meals,
                                                          contexts: contexts, answers: answers)
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
    private func content(_ s: LowsSummary) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(LowsSummaryText.headline(s))
                .dsFont(.headline)
                .fixedSize(horizontal: false, vertical: true)
            DSAccessibleStack(verticalAlignment: .top, spacing: DS.Space.md) {
                StatTile("Lows", value: LowsSummaryText.countValue(s.count),
                         tone: s.count > 0 ? .glucose(.low) : .neutral,
                         rolling: .init(Double(s.count)) { LowsSummaryText.countValue(Int($0.rounded())) })
                if let median = s.medianMinutes {
                    StatTile("Typical length", value: LowsSummaryText.duration(median), caption: "Middle value",
                             rolling: .init(median, order: 1) { LowsSummaryText.duration($0) })
                    let count = s.count
                    StatTile("Treated", value: LowsSummaryText.treatedValue(s.treated, of: count),
                             caption: LowsSummaryText.treatedCaption(s),
                             rolling: .init(Double(s.treated), order: 2) {
                                 LowsSummaryText.treatedValue(Int($0.rounded()), of: count)
                             })
                }
            }
            .monospacedDigit()
            InsightsSparklineView(series: InsightsSparkline.lows(s), tint: GlucoseRange.low.tint,
                                  label: LowsSummaryText.sparklineLabel)
            if s.count > 0 {
                LowsTimeOfDayBars(counts: s.byPart, cluster: s.cluster)
                if let line = LowsSummaryText.clusterLine(s) {
                    Text(line)
                        .dsFont(.callout)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(LowsSummaryText.footnote(s, lowLine: lowLine))
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // One stop for VoiceOver: the period's lows in a few sentences.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LowsSummaryText.title)
        .accessibilityValue([LowsSummaryText.spoken(s, lowLine: lowLine),
                             InsightsSparkline.lows(s).spokenLine(label: LowsSummaryText.sparklineLabel)]
            .compactMap { $0 }.joined(separator: " "))
        // The figures open the Logbook too, not just the row under them. The period picker stays
        // its own control.
        .contentShape(Rectangle())
        .onTapGesture { if s.count > 0 { open(s) } }
        if s.count > 0, openLogbook != nil {
            Button { open(s) } label: {
                HStack(spacing: DS.Space.xs) {
                    Text(LowsSummaryText.logbookLine(s.period))
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
            .accessibilityHint(LowsSummaryText.logbookHint)
        }
    }

    /// The Lows chip over the days the card counted, up to its newest reading.
    private func open(_ s: LowsSummary) {
        guard let openLogbook else { return }
        openLogbook(.lows(s.period, newestReading: s.end, now: Date()))
    }
}

/// When lows start, as four bars (night, morning, afternoon, evening), each with its count. The bars
/// grow in from the leading edge once, then glide to new counts. Hidden from VoiceOver: the card's
/// summary says the same in words.
private struct LowsTimeOfDayBars: View {
    let counts: [Int]
    let cluster: WeekInReview.Part?

    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let top = max(1, counts.max() ?? 1)
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            ForEach(WeekInReview.Part.allCases, id: \.self) { part in
                let n = part.rawValue < counts.count ? counts[part.rawValue] : 0
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(LowsSummaryText.partLabel(part))
                            .foregroundStyle(part == cluster ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.secondary))
                            .fontWeight(part == cluster ? .semibold : .regular)
                        Spacer(minLength: DS.Space.sm)
                        RollingFigure(Double(n), order: part.rawValue) { "\(Int($0.rounded()))" }
                            .monospacedDigit()
                    }
                    .dsFont(.caption)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.06))
                            // Coral at full strength: 3.31:1 or more on every background in the
                            // contrast table, as a graphic needs. The count beside it is text.
                            Capsule()
                                .fill(GlucoseRange.low.tint)
                                .frame(width: n == 0 ? 0 : max(6, geo.size.width * Double(n) / Double(top)))
                                .dsAnimation(.emphasized, value: counts)
                                .scaleEffect(x: grown ? 1 : 0.001, anchor: .leading)
                                .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.82)
                                    .delay(0.15 + Double(part.rawValue) * 0.045), value: grown)
                        }
                    }
                    .frame(height: 6)
                }
            }
        }
        .accessibilityHidden(true)
        .onAppear {
            guard !grown else { return }
            if reduceMotion { grown = true } else {
                // Next frame, so the bars are laid out empty first.
                DispatchQueue.main.async { grown = true }
            }
        }
    }
}
