import SwiftUI

/// The Insights "Best and toughest days" card on the Mac and iPhone: over the last 7, 14 or 30 days,
/// the day with the most time in range and the day with the least, each with its share in range
/// and a small chart of the day (`BestToughestDays`, `DayMiniChart`). Worked out off the main thread
/// once per data change (`BestToughestDaysCache`).
///
/// Motion: the two figures count up where `figuresCountUp` is on (iPhone and Mac Insights) and roll
/// to new values when the period changes. Each chart draws in from the left the first time it
/// shows and again when a new day takes its place; under Reduce Motion it cross-fades instead.
/// Nothing loops. Callers give it their own card surface.
///
/// With `openLogbook`, each day is a button that opens the Logbook on the Best day or Toughest day
/// chip over that day, midnight to midnight (`LogbookLink.bestDay`). The iPhone zooms the card into
/// it; the Mac cross-fades to its Logbook section (docs/LogbookSearch.md, "From the Insights cards").
struct BestToughestDaysCardView: View {
    let readings: [GlucoseReading]
    /// Insights stepped back to an earlier period (docs/InsightsPeriodStep.md).
    @Environment(\.insightsStep) private var step
    /// What was logged, marked along the bottom of each day's chart.
    var entries: [LogEntry] = []
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    var openLogbook: ((LogbookLink) -> Void)? = nil

    @AppStorage("insights.bestDaysDays") private var periodDays = BestToughestDays.Period.fortnight.rawValue
    @State private var value: BestToughestDays?
    @State private var shownKey: BestToughestDaysCache.Key?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.insightsShareSnapshot) private var shareSnapshot

    private var period: BestToughestDays.Period { BestToughestDays.Period(rawValue: periodDays) ?? .fortnight }
    /// The readings up to where the period ends once Insights is stepped back; all of them on
    /// the latest.
    private var shown: [GlucoseReading] {
        InsightsPeriodStep.readings(readings, days: period.days, back: step.back)
    }
    /// "3.9–10.0 mmol/L".
    private var rangeLine: String { "\(unit.format(mgdl: lowMgdl))–\(unit.format(mgdl: highMgdl)) \(unit.label)" }

    var body: some View {
        let key = BestToughestDaysCache.key(readings: shown, low: lowMgdl, high: highMgdl, period: period)
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Eyebrow(title: BestToughestDaysText.title, systemImage: "rosette")
            // A shared picture names the period in its footer instead (docs/InsightsShare.md).
            if !shareSnapshot {
                Picker("Period", selection: $periodDays) {
                    ForEach(BestToughestDays.Period.allCases) { Text($0.label).tag($0.rawValue) }
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
                Color.clear.frame(height: 220)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: key) {
            let new: BestToughestDays?
            if let hit = BestToughestDaysCache.shared.cached(key) {
                new = hit
            } else {
                new = await BestToughestDaysCache.shared.value(for: key, readings: shown)
            }
            if value == nil || new == nil {
                value = new
            } else {
                DS.animate(.standard, reduceMotion: reduceMotion) { value = new }
            }
            shownKey = key
        }
    }

    @ViewBuilder
    private func content(_ s: BestToughestDays) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            ForEach(BestToughestDays.Which.allCases) { which in
                dayButton(which, s)
            }
            Text(BestToughestDaysText.line(s))
                .dsFont(.callout)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            if let line = BestToughestDaysText.toughLine(s, lowLine: "\(unit.format(mgdl: lowMgdl)) \(unit.label)",
                                                         highLine: "\(unit.format(mgdl: highMgdl)) \(unit.label)") {
                Text(line)
                    .dsFont(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let line = BestToughestDaysText.countedLine(s) {
                Text(line)
                    .dsFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(BestToughestDaysText.footnote(rangeLine: rangeLine))
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One day: its share in range large, the day and its time out of range under it, then the
    /// day's chart. The whole tile is the button.
    private func dayButton(_ which: BestToughestDays.Which, _ s: BestToughestDays) -> some View {
        let now = Date()
        let d = s.day(which)
        let markers = ChartLogMarker.day(entries, start: d.start)
        let logged = entries.filter { d.interval.contains($0.timestamp) && $0.timestamp < d.end }.count
        let tone: Tone = which == .best || s.muchAlike ? .glucose(.inRange) : .neutral
        let tile = StatTile(which.title, value: BestToughestDaysText.percent(d.figures.inRange),
                            caption: "\(BestToughestDaysText.dayTitle(d, now: now)) · \(BestToughestDaysText.caption(d))",
                            tone: tone, boxed: true,
                            rolling: .init(d.figures.inRange, order: which == .best ? 0 : 1) { BestToughestDaysText.percent($0) }) {
            HStack(alignment: .bottom, spacing: DS.Space.xs) {
                DayMiniChart(start: d.start, segments: d.segments, markers: markers, unit: unit,
                             lowMgdl: lowMgdl, highMgdl: highMgdl, height: 84)
                    .dayChartDrawIn(d.start)
                if openLogbook != nil {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, DS.Space.lg)
                }
            }
            .padding(.top, DS.Space.xs)
        }
        return Button { open(which, s) } label: { tile.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .disabled(openLogbook == nil)
            .keyStop("insights.bestDays.\(which)", kind: .control, radius: DS.Radius.tile) { open(which, s) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(which.title)
            .accessibilityValue(BestToughestDaysText.spoken(which, s, unit: unit, low: lowMgdl, high: highMgdl,
                                                            logged: logged, now: now))
            .accessibilityHint(openLogbook == nil ? "" : BestToughestDaysText.logbookHint(which))
    }

    /// That day, midnight to midnight, on its chip.
    private func open(_ which: BestToughestDays.Which, _ s: BestToughestDays) {
        guard let openLogbook else { return }
        openLogbook(.bestDay(which, s, now: Date()))
    }
}

private extension View {
    /// Draws the chart in from the left the first time it shows, and again whenever `day` changes
    /// (a new period picked a different day). Under Reduce Motion the new chart cross-fades in.
    func dayChartDrawIn(_ day: Date) -> some View {
        modifier(DayChartDrawIn(day: day))
    }
}

private struct DayChartDrawIn: ViewModifier {
    let day: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The day that has finished drawing in; anything else is drawn empty, then revealed.
    @State private var drawn: Date?

    func body(content: Content) -> some View {
        let shown = drawn == day
        content
            .mask(alignment: .leading) {
                GeometryReader { geo in
                    Rectangle()
                        .frame(width: reduceMotion || shown ? geo.size.width : 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
            .opacity(reduceMotion && !shown ? 0 : 1)
            .onEntrance { reveal() }
            .onChange(of: day) { reveal() }
    }

    private func reveal() {
        guard drawn != day else { return }
        // Next turn of the run loop, so the empty chart is committed before it draws in.
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .smooth(duration: 0.7)) { drawn = day }
        }
    }
}

extension BestToughestDaysCardView {
    /// Nothing to show: why, and the shortest longer period that has enough, when one does
    /// (`InsightsEmptyState`, docs/EmptyStates.md). Worked out off the main thread, only while empty.
    fileprivate func emptyNote(_ key: BestToughestDaysCache.Key) -> some View {
        let shown = self.shown, low = lowMgdl, high = highMgdl, period = period
        return InsightsEmptyNote(id: AnyHashable(key), waiting: BestToughestDaysText.emptyLine(period), decide: {
            let longer = InsightsEmptyState.firstWithData(
                InsightsEmptyState.longer(than: period.days, in: BestToughestDays.Period.allCases.map(\.days))) { days in
                    guard let p = BestToughestDays.Period(rawValue: days) else { return false }
                    return BestToughestDays.compute(readings: shown, low: low, high: high, period: p) != nil
                }
            return InsightsEmptyState.readings(daysSoFar: InsightsEmptyState.readingDays(shown), needed: BestToughestDays.minimumDays,
                                               waiting: BestToughestDaysText.emptyLine(period), currentDays: period.days,
                                               longerWithData: longer)
        }, act: { action in
            if case .showPeriod(let days) = action { periodDays = days }
        })
    }
}
