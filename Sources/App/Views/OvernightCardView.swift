import SwiftUI

/// The Insights "Overnight" card on the Mac and iPhone, after Lows and Highs: time in range from
/// midnight to 6 am over the last 7, 14 or 30 days, the lows that started overnight, and how far
/// glucose usually moved across the night (`OvernightSummary`). Worked out off the main thread once
/// per data change (`OvernightSummaryCache`).
///
/// Motion is the Lows and Highs cards': the figures count up where `figuresCountUp` is on (iPhone
/// and Mac Insights) and roll to new values when the period changes; the sentences cross-fade.
/// Nothing loops, and Reduce Motion shows the new values at once. Callers give it their own card
/// surface.
///
/// With `openLogbook`, tapping the card (or its "See these nights in the Logbook" row) opens the
/// Logbook on the Overnight chip over the same days (`LogbookLink.overnight`): everything logged
/// between midnight and 6 am. The iPhone zooms the card into it; the Mac cross-fades to its
/// Logbook section (docs/LogbookSearch.md, "From the Insights cards").
struct OvernightCardView: View {
    let readings: [GlucoseReading]
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    var openLogbook: ((LogbookLink) -> Void)? = nil

    @AppStorage("insights.overnightDays") private var periodDays = OvernightSummary.Period.fortnight.rawValue
    @State private var value: OvernightSummary?
    @State private var shownKey: OvernightSummaryCache.Key?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.insightsShareSnapshot) private var shareSnapshot
    /// "Compare to previous period" (docs/InsightsCompare.md) and the period before, while it's on.
    @AppStorage(InsightsCompare.storageKey) private var compare = false
    @State private var previous: OvernightSummary?

    private var period: OvernightSummary.Period { OvernightSummary.Period(rawValue: periodDays) ?? .fortnight }
    /// "3.9 mmol/L".
    private var lowLine: String { "\(unit.format(mgdl: lowMgdl)) \(unit.label)" }

    var body: some View {
        let key = OvernightSummaryCache.key(readings: readings, low: lowMgdl, high: highMgdl, period: period)
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Eyebrow(title: OvernightSummaryText.title, systemImage: "moon", trailing: OvernightSummaryText.hours)
            // A shared picture names the period in its footer instead (docs/InsightsShare.md).
            if !shareSnapshot {
                Picker("Period", selection: $periodDays) {
                    ForEach(OvernightSummary.Period.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Period")
            }

            // While another period is worked out the last one stays up, so its figures roll to the
            // new ones rather than blanking.
            if let value {
                content(value)
            } else if shownKey == key {
                emptyNote(key)
            } else {
                // Working it out: hold the space without a spinner.
                Color.clear.frame(height: 120)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: key) {
            let new: OvernightSummary?
            if let hit = OvernightSummaryCache.shared.cached(key) {
                new = hit
            } else {
                new = await OvernightSummaryCache.shared.value(for: key, readings: readings)
            }
            // The figures roll by themselves; the sentences and tile colours cross-fade alongside.
            if value == nil || new == nil {
                value = new
            } else {
                DS.animate(.standard, reduceMotion: reduceMotion) { value = new }
            }
            shownKey = key
        }
        // The period before, only while the switch is on: worked out off the main thread once per
        // new figure, and nothing extra shows when it lacks nights.
        .task(id: compare ? value : nil) {
            guard compare, let current = value else { previous = nil; return }
            let readings = readings, low = lowMgdl, high = highMgdl
            let new = await Task.detached(priority: .utility) {
                InsightsCompare.previousOvernight(readings: readings, low: low, high: high, current: current)
            }.value
            DS.animate(.standard, reduceMotion: reduceMotion) { previous = new }
        }
    }

    /// The period before, when the switch is on and it had enough nights.
    private func before(_ s: OvernightSummary) -> OvernightSummary? {
        guard compare, let previous, previous.period == s.period else { return nil }
        return previous
    }

    @ViewBuilder
    private func content(_ s: OvernightSummary) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(OvernightSummaryText.headline(s))
                .dsFont(.headline)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            DSAccessibleStack(verticalAlignment: .top, spacing: DS.Space.md) {
                StatTile("In range", value: OvernightSummaryText.percent(s.timeInRange),
                         caption: OvernightSummaryText.rangeCaption(s),
                         tone: .glucose(.inRange),
                         rolling: .init(s.timeInRange) { OvernightSummaryText.percent($0) }) {
                    InsightsDeltaBadge(delta: InsightsCompare.overnightRange(s, before(s)),
                                       previous: InsightsCompare.previousPhrase(days: s.period.days))
                }
                StatTile("Lows", value: LowsSummaryText.countValue(s.lows),
                         caption: OvernightSummaryText.lowsCaption(s),
                         tone: s.lows > 0 ? .glucose(.low) : .neutral,
                         rolling: .init(Double(s.lows), order: 1) { LowsSummaryText.countValue(Int($0.rounded())) }) {
                    InsightsDeltaBadge(delta: InsightsCompare.overnightLows(s, before(s)),
                                       previous: InsightsCompare.previousPhrase(days: s.period.days))
                }
                if let change = s.averageChangeMgdl {
                    StatTile("Average change", value: OvernightSummaryText.changeValue(change, unit: unit),
                             caption: unit.label,
                             rolling: .init(change, order: 2) { OvernightSummaryText.changeValue($0, unit: unit) })
                }
            }
            .monospacedDigit()
            InsightsSparklineView(series: InsightsSparkline.overnight(s), tint: GlucoseRange.inRange.tint,
                                  label: OvernightSummaryText.sparklineLabel)
            if let line = OvernightSummaryText.movementLine(s, unit: unit) {
                Text(line)
                    .dsFont(.callout)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(OvernightSummaryText.footnote(s, lowLine: lowLine))
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // One stop for VoiceOver: the period's nights in a few sentences.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(OvernightSummaryText.title)
        .accessibilityValue([OvernightSummaryText.spoken(s, lowLine: lowLine, unit: unit),
                             InsightsSparkline.overnight(s).spokenLine(label: OvernightSummaryText.sparklineLabel),
                             InsightsCompare.spoken([("Overnight time in range", InsightsCompare.overnightRange(s, before(s))),
                                                     ("Overnight lows", InsightsCompare.overnightLows(s, before(s)))],
                                                    previous: InsightsCompare.previousPhrase(days: s.period.days))]
            .compactMap { $0 }.joined(separator: " "))
        // The figures open the Logbook too, not just the row under them. The period picker stays
        // its own control.
        .contentShape(Rectangle())
        .onTapGesture { open(s) }
        if openLogbook != nil {
            Button { open(s) } label: {
                HStack(spacing: DS.Space.xs) {
                    Text(OvernightSummaryText.logbookLine)
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
            .accessibilityHint(OvernightSummaryText.logbookHint)
        }
    }

    /// The Overnight chip over the days the card counted, up to its newest reading.
    private func open(_ s: OvernightSummary) {
        guard let openLogbook else { return }
        openLogbook(.overnight(s.period, newestReading: s.end, now: Date()))
    }
}

extension OvernightCardView {
    /// Nothing to show: why, and the shortest longer period that has enough, when one does
    /// (`InsightsEmptyState`, docs/EmptyStates.md). Worked out off the main thread, only while empty.
    fileprivate func emptyNote(_ key: OvernightSummaryCache.Key) -> some View {
        let readings = readings, low = lowMgdl, high = highMgdl, period = period
        return InsightsEmptyNote(id: AnyHashable(key), waiting: OvernightSummaryText.emptyLine(period), decide: {
            let longer = InsightsEmptyState.firstWithData(
                InsightsEmptyState.longer(than: period.days, in: OvernightSummary.Period.allCases.map(\.days))) { days in
                    guard let p = OvernightSummary.Period(rawValue: days) else { return false }
                    return OvernightSummary.compute(readings: readings, low: low, high: high, period: p) != nil
                }
            return InsightsEmptyState.readings(daysSoFar: InsightsEmptyState.readingDays(readings), needed: OvernightSummary.minimumNights,
                                               waiting: OvernightSummaryText.emptyLine(period), currentDays: period.days,
                                               longerWithData: longer)
        }, act: { action in
            if case .showPeriod(let days) = action { periodDays = days }
        })
    }
}
