import SwiftUI

/// The Insights "Week in review" card on the Mac and iPhone: this week beside last week for time in
/// range, the average and lows, and the best and hardest part of the day this week. Worked out off
/// the main thread once per data change (`WeekInReviewCache`). Nothing here runs a timer or loops
/// (docs/Redesign.md power rules): each figure rolls once to a new value, and counts up when the
/// card appears where `figuresCountUp` is on (iPhone and Mac Insights); the sentences cross-fade
/// alongside. Instant under Reduce Motion. Callers give it their own card surface.
///
/// With `openLogbook`, each week is a button that opens the Logbook on that week's 7 days
/// (`LogbookLink.week`). The iPhone zooms the card into it; the Mac cross-fades to its Logbook
/// section (docs/LogbookSearch.md, "From the Insights cards").
struct WeekInReviewView: View {
    let readings: [GlucoseReading]
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    var openLogbook: ((LogbookLink) -> Void)? = nil

    @State private var value: WeekInReview?
    @State private var shownKey: WeekInReviewCache.Key?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let key = WeekInReviewCache.key(readings: readings, low: lowMgdl, high: highMgdl)
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Eyebrow(title: WeekInReviewText.title, systemImage: "calendar", trailing: WeekInReviewText.period)
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
            let new: WeekInReview?
            if let hit = WeekInReviewCache.shared.cached(key) {
                new = hit
            } else {
                new = await WeekInReviewCache.shared.value(for: key, readings: readings)
            }
            // A week that moves on (new readings, a new day) cross-fades its sentences and colours
            // while the figures roll, instead of the card jumping. The first fill-in comes in with
            // the card's own entrance. Once per change; instant under Reduce Motion.
            if value == nil || new == nil {
                value = new
            } else {
                DS.animate(.standard, reduceMotion: reduceMotion) { value = new }
            }
            shownKey = key
        }
    }

    @ViewBuilder
    private func content(_ w: WeekInReview) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(WeekInReviewText.headline(w))
                .dsFont(.headline)
                .fixedSize(horizontal: false, vertical: true)
            DSAccessibleStack(verticalAlignment: .top, spacing: DS.Space.md) {
                ForEach(w.sides) { side in
                    if let week = w.week(side) { sideButton(side, week, w) }
                }
            }
            .monospacedDigit()
            let lines = WeekInReviewText.lines(w)
            let spoken = WeekInReviewText.spokenLines(w)
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    ForEach(lines.indices, id: \.self) { i in
                        Text(lines[i])
                            .dsFont(.callout)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(i < spoken.count ? spoken[i] : lines[i])
                    }
                }
            }
            Text(WeekInReviewText.footnote(w))
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One week: its time in range large, the average and lows rolling under it, and a chevron when
    /// it opens the Logbook. The whole tile is the button. This week settles first, then last week.
    private func sideButton(_ side: WeekInReview.Side, _ week: WeekInReview.Week, _ w: WeekInReview) -> some View {
        let order = side.rawValue * 3
        let tile = StatTile(side.title, value: WeekInReviewText.percent(week.timeInRange),
                            tone: .glucose(.inRange), boxed: true,
                            rolling: .init(week.timeInRange, order: order) { WeekInReviewText.percent($0) }) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: 0) {
                    Text("Average ")
                    RollingFigure(week.meanMgdl, order: order + 1) { unit.format(mgdl: $0) }
                    Text(" \(unit.label)")
                }
                HStack(spacing: DS.Space.xs) {
                    RollingFigure(Double(week.lows), order: order + 2) { WeekInReviewText.lows(Int($0.rounded())) }
                        .foregroundStyle(week.lows > 0 ? AnyShapeStyle(Tone.glucose(.low).textColor) : AnyShapeStyle(Color.secondary))
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
            .accessibilityValue(WeekInReviewText.spoken(side, w, unit: unit) ?? "")
            .accessibilityHint(openLogbook == nil ? "" : WeekInReviewText.logbookHint(side))
    }

    /// That week's 7 days in the Logbook, on its This week or Last week chip.
    private func open(_ side: WeekInReview.Side, _ w: WeekInReview) {
        guard let openLogbook else { return }
        openLogbook(.week(side, newestReading: w.end, now: Date()))
    }
}

extension WeekInReviewView {
    /// Nothing to show: no readings yet, or how many days so far (`InsightsEmptyState`,
    /// docs/EmptyStates.md). The card has no period to widen, so there's no button.
    fileprivate func emptyNote(_ key: WeekInReviewCache.Key) -> some View {
        let readings = readings
        return InsightsEmptyNote(id: AnyHashable(key), waiting: WeekInReviewText.emptyLine, decide: {
            InsightsEmptyState.readings(daysSoFar: InsightsEmptyState.readingDays(readings), needed: WeekInReview.minimumDays,
                                        waiting: WeekInReviewText.emptyLine, currentDays: nil, longerWithData: nil)
        })
    }
}
