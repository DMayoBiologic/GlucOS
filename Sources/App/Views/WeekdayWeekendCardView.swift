import SwiftUI

/// The Insights "Weekdays and weekends" card on the Mac and iPhone, after Overnight: time in range,
/// the average and lows on weekdays beside the same on weekend days over the last 7, 14 or 30 days
/// (`WeekdayWeekend`). Worked out off the main thread once per data change (`WeekdayWeekendCache`).
///
/// Motion is the Lows, Highs and Overnight cards': the figures count up where `figuresCountUp` is
/// on (iPhone and Mac Insights) and roll to new values when the period changes; the sentences
/// cross-fade. Nothing loops, and Reduce Motion shows the new values at once. Callers give it their
/// own card surface.
///
/// With `openLogbook`, each side is a button that opens the Logbook on the Weekdays or Weekends chip
/// over the same days (`LogbookLink.weekPart`). The iPhone zooms the card into it; the Mac
/// cross-fades to its Logbook section (docs/LogbookSearch.md, "From the Insights cards").
struct WeekdayWeekendCardView: View {
    let readings: [GlucoseReading]
    /// Insights stepped back to an earlier period (docs/InsightsPeriodStep.md).
    @Environment(\.insightsStep) private var step
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    var openLogbook: ((LogbookLink) -> Void)? = nil

    @AppStorage("insights.weekPartDays") private var periodDays = WeekdayWeekend.Period.fortnight.rawValue
    @State private var value: WeekdayWeekend?
    @State private var shownKey: WeekdayWeekendCache.Key?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.insightsShareSnapshot) private var shareSnapshot
    /// "Compare to previous period" (docs/InsightsCompare.md) and the period before, while it's on.
    @AppStorage(InsightsCompare.storageKey) private var compare = false
    @State private var previous: WeekdayWeekend?

    private var period: WeekdayWeekend.Period { WeekdayWeekend.Period(rawValue: periodDays) ?? .fortnight }
    /// The readings up to where the period ends once Insights is stepped back; all of them on
    /// the latest.
    private var shown: [GlucoseReading] {
        InsightsPeriodStep.readings(readings, days: period.days, back: step.back)
    }
    /// "3.9 mmol/L".
    private var lowLine: String { "\(unit.format(mgdl: lowMgdl)) \(unit.label)" }

    var body: some View {
        let key = WeekdayWeekendCache.key(readings: shown, low: lowMgdl, high: highMgdl, period: period)
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Eyebrow(title: WeekdayWeekendText.title, systemImage: "calendar")
            // A shared picture names the period in its footer instead (docs/InsightsShare.md).
            if !shareSnapshot {
                Picker("Period", selection: $periodDays) {
                    ForEach(WeekdayWeekend.Period.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Period")
            }
            // Which dates the card shows once Insights is stepped back (docs/InsightsPeriodStep.md).
            InsightsStepCaption(days: period.days, latest: readings.last?.timestamp)

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
            let new: WeekdayWeekend?
            if let hit = WeekdayWeekendCache.shared.cached(key) {
                new = hit
            } else {
                new = await WeekdayWeekendCache.shared.value(for: key, readings: shown)
            }
            if value == nil || new == nil {
                value = new
            } else {
                DS.animate(.standard, reduceMotion: reduceMotion) { value = new }
            }
            shownKey = key
        }
        // The period before, only while the switch is on: worked out off the main thread once per
        // new figure. A side shows nothing extra when it lacked days before.
        .task(id: compare ? value : nil) {
            guard compare, let current = value else { previous = nil; return }
            let shown = self.shown, low = lowMgdl, high = highMgdl
            let new = await Task.detached(priority: .utility) {
                InsightsCompare.previousWeekPart(readings: shown, low: low, high: high, current: current)
            }.value
            DS.animate(.standard, reduceMotion: reduceMotion) { previous = new }
        }
    }

    /// A side's time in range against the period before, when the switch is on and that side had
    /// enough days.
    private func rangeDelta(_ side: WeekdayWeekend.Side, _ w: WeekdayWeekend) -> InsightsDelta? {
        guard compare, let previous, previous.period == w.period else { return nil }
        return InsightsCompare.weekPartRange(side, w, previous)
    }

    @ViewBuilder
    private func content(_ w: WeekdayWeekend) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSAccessibleStack(verticalAlignment: .top, spacing: DS.Space.md) {
                ForEach(WeekdayWeekend.Side.allCases) { side in
                    sideButton(side, w)
                }
            }
            .monospacedDigit()
            Text(WeekdayWeekendText.rangeLine(w))
                .dsFont(.callout)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            if let line = WeekdayWeekendText.lowsLine(w) {
                Text(line)
                    .dsFont(.callout)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(WeekdayWeekendText.footnote(lowLine: lowLine))
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One side: its time in range large, the average and lows under it, and a chevron when it
    /// opens the Logbook. The whole tile is the button.
    private func sideButton(_ side: WeekdayWeekend.Side, _ w: WeekdayWeekend) -> some View {
        let s = w.stats(side)
        let tile = StatTile(side.title, value: WeekdayWeekendText.percent(s.timeInRange),
                            caption: WeekdayWeekendText.caption(s), tone: .glucose(.inRange), boxed: true,
                            rolling: .init(s.timeInRange, order: side == .weekdays ? 0 : 1) { WeekdayWeekendText.percent($0) }) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                InsightsDeltaBadge(delta: rangeDelta(side, w),
                                   previous: InsightsCompare.previousPhrase(days: w.period.days))
                Text("Average \(WeekdayWeekendText.average(s, unit: unit))")
                HStack(spacing: DS.Space.xs) {
                    Text(WeekdayWeekendText.lows(s))
                        .foregroundStyle(s.lows > 0 ? AnyShapeStyle(Tone.glucose(.low).textColor) : AnyShapeStyle(Color.secondary))
                    Spacer(minLength: DS.Space.xs)
                    if openLogbook != nil {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .dsFont(.caption)
            .padding(.top, DS.Space.xxs)
        }
        return Button { open(side, w) } label: { tile.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .disabled(openLogbook == nil)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(side.title)
            .accessibilityValue([WeekdayWeekendText.spoken(side, w, lowLine: lowLine, unit: unit),
                                 InsightsCompare.spoken([("Time in range", rangeDelta(side, w))],
                                                        previous: InsightsCompare.previousPhrase(days: w.period.days))]
                .compactMap { $0 }.joined(separator: " "))
            .accessibilityHint(openLogbook == nil ? "" : WeekdayWeekendText.logbookHint(side))
    }

    /// That side's chip over the days the card counted, up to its newest reading.
    private func open(_ side: WeekdayWeekend.Side, _ w: WeekdayWeekend) {
        guard let openLogbook else { return }
        openLogbook(.weekPart(side, w.period, newestReading: w.end, now: Date()))
    }
}

extension WeekdayWeekendCardView {
    /// Nothing to show: why, and the shortest longer period that has enough, when one does
    /// (`InsightsEmptyState`, docs/EmptyStates.md). Worked out off the main thread, only while empty.
    fileprivate func emptyNote(_ key: WeekdayWeekendCache.Key) -> some View {
        let shown = self.shown, low = lowMgdl, high = highMgdl, period = period
        return InsightsEmptyNote(id: AnyHashable(key), waiting: WeekdayWeekendText.emptyLine(period), decide: {
            let longer = InsightsEmptyState.firstWithData(
                InsightsEmptyState.longer(than: period.days, in: WeekdayWeekend.Period.allCases.map(\.days))) { days in
                    guard let p = WeekdayWeekend.Period(rawValue: days) else { return false }
                    return WeekdayWeekend.compute(readings: shown, low: low, high: high, period: p) != nil
                }
            return InsightsEmptyState.readings(daysSoFar: InsightsEmptyState.readingDays(shown), needed: WeekdayWeekend.minimumDays * 2,
                                               waiting: WeekdayWeekendText.emptyLine(period), currentDays: period.days,
                                               longerWithData: longer)
        }, act: { action in
            if case .showPeriod(let days) = action { periodDays = days }
        })
    }
}
