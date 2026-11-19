import SwiftUI

/// The Insights "Tags" card on the Mac and iPhone, after Best and toughest days: for each tag used
/// over the last 7, 14 or 30 days, time in range and the average in the 4 hours after the entries
/// carrying it, beside every reading over the same days (`TagInsights`). Worked out off the main
/// thread once per data change (`TagInsightsCache`). The screens leave it out entirely until
/// something in the Logbook carries a tag (`TagInsightsCardView.shows`).
///
/// Motion (`TagsCardMotion`, docs/LogbookTags.md "Motion"): as the card rises in, each tag's
/// in-range bar grows from the leading edge, one after another, while the figures count up. When
/// the period or the data changes, the tiles spring to their new places, the figures roll, the
/// bars glide, and a tag that's newly listed slides in. Under Reduce Motion the old picture
/// cross-fades to the new one and nothing slides. VoiceOver hears one line per change
/// (`TagsCardMotion.announcement`), never for new readings that only nudge the figures. Nothing
/// loops. Callers give it their own card surface.
///
/// With `openLogbook`, each tag is a button that opens the Logbook on that tag's chip over the same
/// days (`LogbookLink.tag`). The iPhone zooms the card into it; the Mac cross-fades to its Logbook
/// section (docs/LogbookSearch.md, "From the Insights cards").
struct TagInsightsCardView: View {
    let readings: [GlucoseReading]
    /// Insights stepped back to an earlier period (docs/InsightsPeriodStep.md).
    @Environment(\.insightsStep) private var step
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
    /// The bars have grown in (once, as the card rises in).
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.insightsShareSnapshot) private var shareSnapshot

    /// Whether the card belongs on the screen at all: once any entry carries a tag.
    static func shows(_ entries: [LogEntry]) -> Bool {
        entries.contains { !$0.filterTags.isEmpty }
    }

    private var period: TagInsights.Period { TagInsights.Period(rawValue: periodDays) ?? .fortnight }
    /// The readings up to where the period ends once Insights is stepped back; all of them on
    /// the latest.
    private var shown: [GlucoseReading] {
        InsightsPeriodStep.readings(readings, days: period.days, back: step.back)
    }

    var body: some View {
        let key = TagInsightsCache.key(readings: shown, entries: entries, low: lowMgdl, high: highMgdl, period: period)
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
            // Which dates the card shows once Insights is stepped back (docs/InsightsPeriodStep.md).
            InsightsStepCaption(days: period.days, latest: readings.last?.timestamp)

            // While another period is worked out the last one stays up, so its figures roll to the
            // new ones rather than blanking.
            if let value, !value.rows.isEmpty {
                // Under Reduce Motion a new picture replaces the old one with a cross-fade.
                content(value)
                    .id(reduceMotion ? AnyHashable(value) : AnyHashable("tags"))
                    .transition(.opacity)
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
                new = await TagInsightsCache.shared.value(for: key, readings: shown, entries: entries)
            }
            // A newer period or data change took over while this one was worked out: drop it.
            guard !Task.isCancelled else { return }
            let old = value
            if old == nil || new == nil {
                value = new
            } else {
                // Tiles spring to their new places and figures roll; a cross-fade under Reduce Motion.
                withAnimation(reduceMotion ? .easeInOut(duration: TagsCardMotion.reducedFade)
                                           : DSMotion.emphasized.animation) { value = new }
            }
            shownKey = key
            announce(from: old, to: new)
        }
    }

    /// A newly listed tag slides in from the trailing side; one that's gone fades. Fades only under
    /// Reduce Motion, where the whole card cross-fades anyway.
    private var tileTransition: AnyTransition {
        reduceMotion ? .opacity
            : .asymmetric(insertion: .offset(x: TagsCardMotion.slideDistance).combined(with: .opacity),
                          removal: .opacity.combined(with: .scale(scale: 0.96)))
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
                        .transition(tileTransition)
                }
            }
            .monospacedDigit()
            .onEntrance {
                guard !grown else { return }
                // A frame later, so the bars are laid out empty first.
                DispatchQueue.main.async { grown = true }
            }
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
            if let after {
                TagRangeBar(share: after.timeInRange, overall: t.overall.timeInRange,
                            grown: grown || shareSnapshot, delay: TagsCardMotion.growDelay(order: order))
                    .padding(.top, DS.Space.xxs)
            }
        }
        return Button { open(row, t) } label: { tile.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .disabled(openLogbook == nil)
            .keyStop("insights.tags.\(row.tag)", kind: .control, radius: DS.Radius.tile) { open(row, t) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.tag)
            .accessibilityValue(TagInsightsText.spoken(row, in: t, unit: unit))
            .accessibilityHint(openLogbook == nil ? "" : TagInsightsText.logbookHint(row.tag))
    }

    /// One line for VoiceOver when the listed tags or the period changed; quiet on first load, in a
    /// shared picture, and when new readings only nudge the figures.
    private func announce(from old: TagInsights?, to new: TagInsights?) {
        guard let old, let new, !shareSnapshot else { return }
        guard let line = TagsCardMotion.announcement(oldNames: old.rows.map(\.tag), newNames: new.rows.map(\.tag),
                                                     periodChanged: old.period != new.period,
                                                     periodSpoken: new.period.spoken) else { return }
        var spoken = AttributedString(line)
        spoken.accessibilitySpeechAnnouncementPriority = .low
        AccessibilityNotification.Announcement(spoken).post()
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
        let shown = self.shown, entries = entries, low = lowMgdl, high = highMgdl, period = period
        let canLog = log != nil
        return InsightsEmptyNote(id: AnyHashable(key), waiting: TagInsightsText.emptyLine(period), decide: {
            let days = InsightsEmptyState.readingDays(shown)
            guard days > 0 else {
                return InsightsEmptyState.readings(daysSoFar: 0, needed: 1, waiting: TagInsightsText.emptyLine(period),
                                                   currentDays: period.days, longerWithData: nil)
            }
            let longer = InsightsEmptyState.firstWithData(
                InsightsEmptyState.longer(than: period.days, in: TagInsights.Period.allCases.map(\.days))) { days in
                    guard let p = TagInsights.Period(rawValue: days) else { return false }
                    return TagInsights.compute(readings: shown, entries: entries, low: low, high: high,
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

/// Time in range in the 4 hours after a tag as a thin bar, with an upright mark where every
/// reading's time in range sits, so the gap reads at a glance. Grows in from the leading edge
/// after `delay` as the card rises in, then glides to new shares (the card's spring). Fades in
/// where it is under Reduce Motion. Hidden from VoiceOver: the tile says the same in words.
private struct TagRangeBar: View {
    let share: Double
    let overall: Double
    let grown: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06))
                // The in-range hue at full strength, as a graphic needs; the figure above is the text.
                Capsule()
                    .fill(GlucoseRange.inRange.tint)
                    .frame(width: w * TagsCardMotion.fraction(share))
                    .modifier(TagBarEntrance(grown: grown, delay: delay, reduceMotion: reduceMotion))
                Capsule()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 2, height: 10)
                    .offset(x: max(0, w * TagsCardMotion.fraction(overall) - 1))
                    .opacity(grown ? 1 : 0)
                    .animation(.easeInOut(duration: TagsCardMotion.reducedFade).delay(reduceMotion ? 0 : delay),
                               value: grown)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// A tag bar's first appearance: grows from the leading edge, or fades in under Reduce Motion.
private struct TagBarEntrance: ViewModifier {
    let grown: Bool
    let delay: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if reduceMotion {
            content
                .opacity(grown ? 1 : 0)
                .animation(.easeInOut(duration: TagsCardMotion.reducedFade), value: grown)
        } else {
            content
                .scaleEffect(x: grown ? 1 : 0.001, anchor: .leading)
                .animation(.spring(response: 0.6, dampingFraction: 0.82).delay(delay), value: grown)
        }
    }
}
