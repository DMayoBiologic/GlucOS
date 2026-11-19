import SwiftUI

/// The Insights "Time in range by hour" card on the Mac and iPhone, after Your usual day: a strip of
/// 24 cells, one per hour of the clock, each coloured by its time in range over the last 7, 14 or 30
/// days (`HourlyInRange`, docs/HourlyInRange.md). Worked out off the main thread once per data
/// change (`HourlyInRangeCache`).
///
/// The strip is one row of 24 where the card is wide enough (the Mac) and two rows of 12, midnight
/// to noon over noon to midnight, where it isn't (the iPhone), so every cell stays big enough to
/// tap. With `openLogbook`, tapping a cell opens the Logbook on that hour across the same days
/// (`LogbookLink.hour`). The iPhone zooms the card into it; the Mac cross-fades to its Logbook
/// section (docs/LogbookSearch.md, "From the Insights cards").
///
/// Motion is the other cards': the overall figure counts up where `figuresCountUp` is on and rolls
/// when the period changes. Where `figuresCountUp` is on the cells also fill in a left-to-right wave
/// the first time the card rises in (`onEntrance`), and on a period change each cell cross-fades to
/// its new colour a short step after the one to its left (`HourlyCellMotion`). Nothing loops. With
/// Reduce Motion on, nothing moves: the cells fade in together on the first reveal and every cell
/// cross-fades to its new colour at the same moment on a period change. VoiceOver reads the summary, then each hour as its own
/// button ("7 am to 8 am, 54 percent in range, ..."). Callers give it their own card surface.
struct HourlyInRangeCardView: View {
    let readings: [GlucoseReading]
    /// Insights stepped back to an earlier period (docs/InsightsPeriodStep.md).
    @Environment(\.insightsStep) private var step
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    var openLogbook: ((LogbookLink) -> Void)? = nil

    @AppStorage(InsightsShare.Key.hourly) private var periodDays = HourlyInRange.Period.fortnight.rawValue
    @State private var value: HourlyInRange?
    @State private var shownKey: HourlyInRangeCache.Key?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.insightsShareSnapshot) private var shareSnapshot
    @Environment(\.figuresCountUp) private var countsUp
    /// The cells have filled in (first reveal). Only waited for where `fills` is on.
    @State private var filled = false
    /// "Compare to previous period" (docs/InsightsCompare.md) and the period before, while it's on.
    @AppStorage(InsightsCompare.storageKey) private var compare = false
    @State private var previous: HourlyInRange?

    /// The cells fill in on Insights screens only, never in a shared picture: a wave normally, one
    /// fade together under Reduce Motion.
    private var fills: Bool { countsUp && !shareSnapshot }
    /// The moving left-to-right wave, not under Reduce Motion.
    private var waves: Bool { fills && !reduceMotion }

    private var period: HourlyInRange.Period { HourlyInRange.Period(rawValue: periodDays) ?? .fortnight }
    /// The readings up to where the period ends once Insights is stepped back; all of them on
    /// the latest.
    private var shown: [GlucoseReading] {
        InsightsPeriodStep.readings(readings, days: period.days, back: step.back)
    }

    /// Cells narrower than this go to two rows.
    private static let minimumCellWidth: CGFloat = 22
    private static let cellHeight: CGFloat = 36
    private static let cellSpacing: CGFloat = 2

    var body: some View {
        let key = HourlyInRangeCache.key(readings: shown, low: lowMgdl, high: highMgdl, period: period)
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Eyebrow(title: HourlyInRangeText.title, systemImage: "clock")
            // A shared picture names the period in its footer instead (docs/InsightsShare.md).
            if !shareSnapshot {
                Picker("Period", selection: $periodDays) {
                    ForEach(HourlyInRange.Period.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Period")
            }
            // Which dates the card shows once Insights is stepped back (docs/InsightsPeriodStep.md).
            InsightsStepCaption(days: period.days, latest: readings.last?.timestamp)

            // While another period is worked out the last one stays up, so its cells cross-fade
            // to the new ones rather than blanking.
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
            let new: HourlyInRange?
            if let hit = HourlyInRangeCache.shared.cached(key) {
                new = hit
            } else {
                new = await HourlyInRangeCache.shared.value(for: key, readings: shown)
            }
            if value == nil || new == nil {
                value = new
            } else {
                DS.animate(.standard, reduceMotion: reduceMotion) { value = new }
            }
            shownKey = key
        }
        // The period before, only while the switch is on: worked out off the main thread once per
        // new figure, and nothing extra shows when it lacks days.
        .task(id: compare ? value : nil) {
            guard compare, let current = value else { previous = nil; return }
            let shown = self.shown, low = lowMgdl, high = highMgdl
            let new = await Task.detached(priority: .utility) {
                InsightsCompare.previousHourly(readings: shown, low: low, high: high, current: current)
            }.value
            DS.animate(.standard, reduceMotion: reduceMotion) { previous = new }
        }
    }

    /// The period before, when the switch is on and it had enough days.
    private func before(_ s: HourlyInRange) -> HourlyInRange? {
        guard compare, let previous, previous.period == s.period else { return nil }
        return previous
    }

    private func previousPhrase(_ s: HourlyInRange) -> String {
        InsightsCompare.previousPhrase(days: s.period.days)
    }

    @ViewBuilder
    private func content(_ s: HourlyInRange) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            // The summary: one stop for VoiceOver ahead of the hours.
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text(HourlyInRangeText.headline(s))
                    .dsFont(.headline)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                StatTile("In range overall", value: HourlyInRangeText.percent(s.timeInRange),
                         caption: HourlyInRangeText.targetLine(s),
                         tone: .glucose(.inRange),
                         rolling: .init(s.timeInRange) { HourlyInRangeText.percent($0) }) {
                    InsightsDeltaBadge(delta: InsightsCompare.hourlyRange(s, before(s)),
                                       previous: previousPhrase(s))
                }
                .monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(HourlyInRangeText.title)
            .accessibilityValue([HourlyInRangeText.spoken(s),
                                 InsightsCompare.spoken([("Time in range", InsightsCompare.hourlyRange(s, before(s)))],
                                                        previous: previousPhrase(s))]
                .compactMap { $0 }.joined(separator: " "))

            strip(s)

            legend
            if let change = InsightsCompare.biggestHourChange(s, before(s)) {
                Text(HourlyInRangeText.changeLine(hour: change.hour, delta: change.delta, previous: previousPhrase(s)))
                    .dsFont(.callout)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            Text(HourlyInRangeText.footnote(s))
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Strip

    /// One row of 24 when it fits at a tappable size, otherwise two rows of 12.
    private func strip(_ s: HourlyInRange) -> some View {
        ViewThatFits(in: .horizontal) {
            row(s, hours: Array(0..<24), tickEvery: 6)
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                row(s, hours: Array(0..<12), tickEvery: 3)
                row(s, hours: Array(12..<24), tickEvery: 3)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hours")
        .onEntrance {
            guard !filled else { return }
            if fills {
                // Next frame, so the empty strip is drawn before it fills.
                DispatchQueue.main.async { filled = true }
            } else {
                filled = true
            }
        }
    }

    private func row(_ s: HourlyInRange, hours: [Int], tickEvery: Int) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            HStack(spacing: Self.cellSpacing) {
                ForEach(Array(hours.enumerated()), id: \.element) { i, h in
                    cell(h, s, position: i, of: hours.count)
                }
            }
            // Ticks sit in overlays so a label wider than its cell doesn't push the cells apart.
            HStack(spacing: Self.cellSpacing) {
                ForEach(hours, id: \.self) { h in
                    Color.clear
                        .frame(minWidth: Self.minimumCellWidth, idealWidth: Self.minimumCellWidth,
                               maxWidth: .infinity, minHeight: 12, maxHeight: 12)
                        .overlay(alignment: .leading) {
                            if h % tickEvery == 0 {
                                Text(HourlyInRangeText.tick(h))
                                    .dsFont(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                            }
                        }
                }
            }
            .accessibilityHidden(true)
        }
    }

    /// `position` is the cell's column in its row of `count`, which sets when it fills and recolours.
    private func cell(_ h: Int, _ s: HourlyInRange, position: Int, of count: Int) -> some View {
        let hour = s.hour(h)
        let delta = InsightsCompare.hourRange(h, s, before(s))
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return Button { open(h, s) } label: {
            shape
                .fill(cellColor(hour))
                .overlay {
                    if hour == nil {
                        shape.strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    }
                }
                // A new period: this cell cross-fades a step after the one to its left, or with
                // all the others at once under Reduce Motion.
                .animation(.easeInOut(duration: HourlyCellMotion.recolourLength(reduceMotion: reduceMotion))
                    .delay(HourlyCellMotion.recolourDelay(position: position, count: count, reduceMotion: reduceMotion)),
                           value: hour?.shade)
                // First reveal: rises from the baseline and fades in, left to right; under Reduce
                // Motion every cell fades in together without moving. Only the drawing changes; the
                // button, its frame and its VoiceOver element are there throughout.
                .opacity(filled || !fills ? 1 : 0)
                .scaleEffect(x: 1, y: filled || !waves ? 1 : 0.35, anchor: .bottom)
                .animation(fillAnimation(position: position, count: count), value: filled)
                .frame(minWidth: Self.minimumCellWidth, idealWidth: Self.minimumCellWidth, maxWidth: .infinity,
                       minHeight: Self.cellHeight, maxHeight: Self.cellHeight)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(openLogbook == nil)
        // The 24 hours are one row for the arrow keys: ← → step through them.
        .keyStop("insights.hourly.\(h)", row: "insights.hourly.cells", kind: .control, radius: 4) { open(h, s) }
        .help(HourlyInRangeText.help(h, hour))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(HourlyInRangeText.spokenSpan(h))
        .accessibilityValue([HourlyInRangeText.spokenCell(hour),
                             delta?.spoken(label: "Time in range", previous: previousPhrase(s))]
            .compactMap { $0 }.joined(separator: " "))
        .accessibilityHint(openLogbook == nil ? "" : HourlyInRangeText.logbookHint(h, s.period))
    }

    /// The arrival spring a column's step after the left edge, a plain fade under Reduce Motion,
    /// nothing where the cells don't fill.
    private func fillAnimation(position: Int, count: Int) -> Animation? {
        guard fills else { return nil }
        if reduceMotion {
            return .easeInOut(duration: HourlyCellMotion.reducedFade)
                .delay(HourlyCellMotion.fillDelay(position: position, count: count, reduceMotion: true))
        }
        return DSMotion.arrival.animation.delay(HourlyCellMotion.fillDelay(position: position, count: count))
    }

    private func cellColor(_ hour: HourlyInRange.Hour?) -> Color {
        guard let hour else { return Color.secondary.opacity(0.08) }
        return Self.color(hour.shade)
    }

    static func color(_ shade: HourlyInRange.Shade) -> Color {
        switch shade {
        case .inRange: return GlucoseRange.inRange.tint
        case .high(let strong): return GlucoseRange.high.tint.opacity(strong ? 1 : 0.45)
        case .low(let strong): return GlucoseRange.low.tint.opacity(strong ? 1 : 0.45)
        }
    }

    /// The colour key: in range, mostly high, mostly low. Faint cells are 50–70% in range.
    private var legend: some View {
        HStack(spacing: DS.Space.md) {
            ForEach(Array(HourlyInRangeText.legend.enumerated()), id: \.offset) { _, item in
                HStack(spacing: DS.Space.xs) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Self.color(item.shade))
                        .frame(width: 10, height: 10)
                    Text(item.label)
                        .dsFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// The Logbook on that hour over the days the card counted, up to its newest reading.
    private func open(_ hour: Int, _ s: HourlyInRange) {
        guard let openLogbook else { return }
        openLogbook(.hour(hour, s.period, newestReading: s.end, now: Date()))
    }
}

extension HourlyInRangeCardView {
    /// Nothing to show: why, and the shortest longer period that has enough, when one does
    /// (`InsightsEmptyState`, docs/EmptyStates.md). Worked out off the main thread, only while empty.
    fileprivate func emptyNote(_ key: HourlyInRangeCache.Key) -> some View {
        let shown = self.shown, low = lowMgdl, high = highMgdl, period = period
        return InsightsEmptyNote(id: AnyHashable(key), waiting: HourlyInRangeText.emptyLine(period), decide: {
            let longer = InsightsEmptyState.firstWithData(
                InsightsEmptyState.longer(than: period.days, in: HourlyInRange.Period.allCases.map(\.days))) { days in
                    guard let p = HourlyInRange.Period(rawValue: days) else { return false }
                    return HourlyInRange.compute(readings: shown, low: low, high: high, period: p) != nil
                }
            return InsightsEmptyState.readings(daysSoFar: InsightsEmptyState.readingDays(shown), needed: HourlyInRange.minimumDays,
                                               waiting: HourlyInRangeText.emptyLine(period), currentDays: period.days,
                                               longerWithData: longer)
        }, act: { action in
            if case .showPeriod(let days) = action { periodDays = days }
        })
    }
}
