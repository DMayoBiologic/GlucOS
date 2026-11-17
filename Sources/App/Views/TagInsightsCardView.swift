import SwiftUI

/// The Insights "Tags" card on the Mac and iPhone, after Best and toughest days: for each tag used
/// over the last 7, 14 or 30 days, time in range and the average in the 4 hours after the entries
/// carrying it, beside every reading over the same days (`TagInsights`). Worked out off the main
/// thread once per data change (`TagInsightsCache`). The screens leave it out entirely until
/// something in the Logbook carries a tag (`TagInsightsCardView.shows`).
///
/// Motion is the other Insights cards': the figures count up where `figuresCountUp` is on and roll
/// to new values when the period changes; the rest cross-fades. Nothing loops, and Reduce Motion
/// shows the new values at once. Callers give it their own card surface.
///
/// With `openLogbook`, each tag is a button that opens the Logbook on that tag's chip over the same
/// days (`LogbookLink.tag`). The iPhone zooms the card into it; the Mac cross-fades to its Logbook
/// section (docs/LogbookSearch.md, "From the Insights cards").
struct TagInsightsCardView: View {
    let readings: [GlucoseReading]
    let entries: [LogEntry]
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    var openLogbook: ((LogbookLink) -> Void)? = nil
    /// Opens the log sheet, for the empty state's Log Something (docs/EmptyStates.md).
    var log: (() -> Void)? = nil

    @AppStorage("insights.tagsDays") private var periodDays = TagInsights.Period.fortnight.rawValue
    @State private var value: TagInsights?
    @State private var shownKey: TagInsightsCache.Key?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.insightsShareSnapshot) private var shareSnapshot

    /// Whether the card belongs on the screen at all: once any entry carries a tag.
    static func shows(_ entries: [LogEntry]) -> Bool {
        entries.contains { !$0.filterTags.isEmpty }
    }

    private var period: TagInsights.Period { TagInsights.Period(rawValue: periodDays) ?? .fortnight }

    var body: some View {
        let key = TagInsightsCache.key(readings: readings, entries: entries, low: lowMgdl, high: highMgdl, period: period)
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Eyebrow(title: TagInsightsText.title, systemImage: "tag")
            // A shared picture names the period in its footer instead (docs/InsightsShare.md).
            if !shareSnapshot {
                Picker("Period", selection: $periodDays) {
                    ForEach(TagInsights.Period.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Period")
            }

            // While another period is worked out the last one stays up, so its figures roll to the
            // new ones rather than blanking.
            if let value, !value.rows.isEmpty {
                content(value)
            } else if value != nil || shownKey == key {
                emptyNote(key)
            } else {
                // Working it out: hold the space without a spinner.
                Color.clear.frame(height: 120)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: key) {
            let new: TagInsights?
            if let hit = TagInsightsCache.shared.cached(key) {
                new = hit
            } else {
                new = await TagInsightsCache.shared.value(for: key, readings: readings, entries: entries)
            }
            // A newer period or data change took over while this one was worked out: drop it.
            guard !Task.isCancelled else { return }
            if value == nil || new == nil {
                value = new
            } else {
                DS.animate(.standard, reduceMotion: reduceMotion) { value = new }
            }
            shownKey = key
        }
    }

    @ViewBuilder
    private func content(_ t: TagInsights) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(TagInsightsText.overall(t.overall, unit: unit))
                .dsFont(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: DS.Space.md, alignment: .top)],
                      alignment: .leading, spacing: DS.Space.md) {
                ForEach(Array(t.rows.enumerated()), id: \.element.id) { i, row in
                    tagButton(row, in: t, order: i)
                }
            }
            .monospacedDigit()
            Text(TagInsightsText.footnote)
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One tag: time in range after it large, its entries and average under it, how it sits against
    /// every reading, and a chevron when it opens the Logbook. The whole tile is the button.
    private func tagButton(_ row: TagInsights.Row, in t: TagInsights, order: Int) -> some View {
        let after = row.after
        let direction = t.direction(row)
        let tile = StatTile(row.tag, value: after.map { TagInsightsText.percent($0.timeInRange) } ?? "–",
                            caption: TagInsightsText.detail(row, unit: unit),
                            tone: after == nil ? .neutral : .glucose(.inRange), boxed: true,
                            rolling: after.map { a in StatRolling(a.timeInRange, order: order) { TagInsightsText.percent($0) } }) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: LogbookTags.symbol(row.tag))
                    .foregroundStyle(.secondary)
                if let gap = TagInsightsText.gap(row, in: t) {
                    Text(gap)
                        .foregroundStyle(direction == -1 ? AnyShapeStyle(Tone.glucose(.low).textColor)
                                         : direction == 1 ? AnyShapeStyle(Tone.glucose(.inRange).textColor)
                                         : AnyShapeStyle(Color.secondary))
                }
                Spacer(minLength: DS.Space.xs)
                if openLogbook != nil {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .dsFont(.caption)
            .padding(.top, DS.Space.xxs)
        }
        return Button { open(row, t) } label: { tile.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .disabled(openLogbook == nil)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.tag)
            .accessibilityValue(TagInsightsText.spoken(row, in: t, unit: unit))
            .accessibilityHint(openLogbook == nil ? "" : TagInsightsText.logbookHint(row.tag))
    }

    /// That tag's chip over the days the card counted, up to its newest reading.
    private func open(_ row: TagInsights.Row, _ t: TagInsights) {
        guard let openLogbook else { return }
        openLogbook(.tag(row.tag, t.period, newestReading: t.end, now: Date()))
    }
}

extension TagInsightsCardView {
    /// Nothing tagged in this period: a longer period with a tag when there is one, otherwise
    /// Log Something (`InsightsEmptyState.tags`, docs/EmptyStates.md). No readings at all says so
    /// instead. Worked out off the main thread, only while empty.
    fileprivate func emptyNote(_ key: TagInsightsCache.Key) -> some View {
        let readings = readings, entries = entries, low = lowMgdl, high = highMgdl, period = period
        let canLog = log != nil
        return InsightsEmptyNote(id: AnyHashable(key), waiting: TagInsightsText.emptyLine(period), decide: {
            let days = InsightsEmptyState.readingDays(readings)
            guard days > 0 else {
                return InsightsEmptyState.readings(daysSoFar: 0, needed: 1, waiting: TagInsightsText.emptyLine(period),
                                                   currentDays: period.days, longerWithData: nil)
            }
            let longer = InsightsEmptyState.firstWithData(
                InsightsEmptyState.longer(than: period.days, in: TagInsights.Period.allCases.map(\.days))) { days in
                    guard let p = TagInsights.Period(rawValue: days) else { return false }
                    return TagInsights.compute(readings: readings, entries: entries, low: low, high: high,
                                               period: p)?.rows.isEmpty == false
                }
            return InsightsEmptyState.tags(currentDays: period.days, longerWithTags: longer, canLog: canLog)
        }, act: { action in
            switch action {
            case .showPeriod(let days): periodDays = days
            case .log: log?()
            }
        })
    }
}
