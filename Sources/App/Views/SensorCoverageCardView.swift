import SwiftUI

/// The Insights "Sensor coverage" card on the Mac and iPhone: how much of the last 7, 14 or 30 days
/// has readings, and the longest gaps with the chart's reasons for them (`SensorCoverage`,
/// docs/SensorCoverage.md). The screen leaves it out while coverage is 99% or more
/// (`SensorCoverageCache.shows`).
///
/// Motion (`SensorCoverageCardMotion`, docs/SensorCoverage.md "Motion"): the figures count up as
/// the card rises in and roll to new values when the period changes; the coverage meter fills, then
/// each gap's row slides up and its bar grows from the leading edge a step behind the one above
/// (`onEntrance`). New periods glide the bars to their new lengths. With Compare on, the period
/// before's marks fade in on the meter and the bars, sharing their scale. Nothing loops. Under
/// Reduce Motion the rows are there at once, the bars and marks fade in, and new values cross-fade.
/// The bars are drawn inside the card's one VoiceOver stop, which says the same in words. Callers
/// give it their own card surface.
///
/// With `openLogbook`, tapping the card (or its "See the longest gap in the Logbook" row) opens the
/// Logbook around the longest gap, an hour either side (`LogbookFilter.aroundGap`); a gap's own row
/// opens the Logbook around that gap. The iPhone zooms the card into it; the Mac cross-fades.
struct SensorCoverageCardView: View {
    let readings: [GlucoseReading]
    let context: ReadingGaps.Context
    var openLogbook: ((LogbookLink) -> Void)? = nil

    /// Insights stepped back to an earlier period (docs/InsightsPeriodStep.md).
    @Environment(\.insightsStep) private var step
    @AppStorage(InsightsShare.Key.coverage) private var periodDays = SensorCoverage.Period.fortnight.rawValue
    @State private var value: SensorCoverage?
    @State private var shownKey: SensorCoverageCache.Key?
    /// The meter has filled and the gap rows and bars have grown in (once per appearance).
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.insightsShareSnapshot) private var shareSnapshot
    /// "Compare to previous period" (docs/InsightsCompare.md) and the period before, while it's on.
    @AppStorage(InsightsCompare.storageKey) private var compare = false
    @State private var previous: SensorCoverage?

    private var period: SensorCoverage.Period { SensorCoverage.Period(rawValue: periodDays) ?? .fortnight }

    var body: some View {
        let key = SensorCoverageCache.key(readings: readings, context: context, period: period, back: step.back)
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Eyebrow(title: SensorCoverageText.title, systemImage: SensorCoverageText.systemImage)
            // A shared picture names the period in its footer instead (docs/InsightsShare.md).
            if !shareSnapshot {
                Picker("Period", selection: $periodDays) {
                    ForEach(SensorCoverage.Period.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .keyStop("insights.sensorCoverage.period", radius: DS.Radius.control)
                .keyCycle($periodDays, through: SensorCoverage.Period.allCases.map(\.rawValue))
                .accessibilityLabel("Period")
            }
            InsightsStepCaption(days: period.days, latest: readings.last?.timestamp)

            if let value {
                content(value)
            } else if shownKey == key {
                Text(SensorCoverageText.emptyLine(period))
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Working it out: hold the space without a spinner.
                Color.clear.frame(height: 120)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: key) { await load(key) }
        // The period before, only while the switch is on: off the main thread once per new figure.
        .task(id: compare ? value : nil) {
            guard compare, let current = value else { previous = nil; return }
            let readings = InsightsPeriodStep.readings(self.readings, days: period.days, back: step.back)
            let context = self.context
            let new = await Task.detached(priority: .utility) {
                InsightsCompare.previousCoverage(readings: readings, context: context, current: current)
            }.value
            DS.animate(.standard, reduceMotion: reduceMotion) { previous = new }
        }
    }

    private func load(_ key: SensorCoverageCache.Key) async {
        let new: SensorCoverage?
        if let hit = SensorCoverageCache.shared.cached(key) {
            new = hit
        } else {
            new = await SensorCoverageCache.shared.value(for: key, readings: readings, context: context)
        }
        // The figures roll by themselves; the sentences and rows cross-fade alongside.
        if value == nil || new == nil {
            value = new
        } else {
            DS.animate(.standard, reduceMotion: reduceMotion) { value = new }
        }
        shownKey = key
    }

    /// The period before, when the switch is on and it had enough readings stored.
    private func before(_ s: SensorCoverage) -> SensorCoverage? {
        guard compare, let previous, previous.period == s.period else { return nil }
        return previous
    }

    private var previousPhrase: String { InsightsCompare.previousPhrase(days: period.days) }

    @ViewBuilder
    private func content(_ s: SensorCoverage) -> some View {
        let now = Date()
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(SensorCoverageText.headline(s))
                .dsFont(.headline)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            tiles(s)
            CoverageMeter(coverage: s.coverage, previous: before(s)?.coverage, grown: grown || shareSnapshot)
            if s.gaps.isEmpty {
                Text(SensorCoverageText.noGapsLine)
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
            } else {
                gapRows(s, now: now)
            }
            if let line = SensorCoverageText.reasonLine(s) {
                Text(line)
                    .dsFont(.callout)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(SensorCoverageText.footnote(s))
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onEntrance {
            guard !grown else { return }
            // A frame later, so the meter and bars are laid out empty first.
            DispatchQueue.main.async { grown = true }
        }
        // One stop for VoiceOver: the period's coverage in a few sentences.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SensorCoverageText.title)
        .accessibilityValue(spoken(s, now: now))
        .contentShape(Rectangle())
        .onTapGesture { open(s.longest.first) }
        if openLogbook != nil, let longest = s.longest.first {
            Button { open(longest) } label: {
                HStack(spacing: DS.Space.xs) {
                    Text(SensorCoverageText.logbookLine)
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
            .keyStop("insights.sensorCoverage.open", kind: .control, radius: DS.Radius.control) { open(longest) }
            .accessibilityHint(SensorCoverageText.logbookHint)
        }
    }

    private func tiles(_ s: SensorCoverage) -> some View {
        DSAccessibleStack(verticalAlignment: .top, spacing: DS.Space.md) {
            StatTile("Covered", value: SensorCoverageText.percent(s.coverage),
                     tone: s.shows ? .neutral : .glucose(.inRange),
                     rolling: .init(s.coverage) { SensorCoverageText.percent($0) }) {
                InsightsDeltaBadge(delta: InsightsCompare.coverage(s, before(s)), previous: previousPhrase)
            }
            StatTile("Gaps", value: "\(s.gaps.count)",
                     caption: s.gaps.isEmpty ? nil : SensorCoverageText.missingValue(s) + " missing",
                     rolling: .init(Double(s.gaps.count), order: 1) { "\(Int($0.rounded()))" }) {
                InsightsDeltaBadge(delta: InsightsCompare.coverageGaps(s, before(s)), previous: previousPhrase)
            }
        }
        .monospacedDigit()
    }

    /// The longest gaps, longest first, each with its reason. They slide up into place one after
    /// another as the card rises in; at once under Reduce Motion.
    private func gapRows(_ s: SensorCoverage, now: Date) -> some View {
        let lengths = SensorCoverageCardMotion.lengths(s)
        let previous = SensorCoverageCardMotion.previousLengths(before(s))
        let scale = SensorCoverageCardMotion.scale(lengths: lengths, previous: previous)
        let shown = grown || reduceMotion || shareSnapshot
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text("Longest gaps")
                .dsFont(.label)
                .foregroundStyle(.secondary)
            // Keyed by rank, so a new period's longest gaps glide their bars from the old lengths
            // rather than swapping whole rows; each row's words and tap follow its current gap.
            ForEach(Array(s.longest.enumerated()), id: \.offset) { i, gap in
                Button { open(gap) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                        Image(systemName: gap.reason.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            Text(SensorCoverageText.row(gap, in: s, now: now))
                                .dsFont(.callout)
                                .monospacedDigit()
                            Text(gap.reason.title)
                                .dsFont(.caption)
                                .foregroundStyle(.secondary)
                            GapBar(fraction: SensorCoverageCardMotion.fraction(i < lengths.count ? lengths[i] : 0, scale: scale),
                                   previous: SensorCoverageCardMotion.previousLength(at: i, in: previous)
                                       .map { SensorCoverageCardMotion.fraction($0, scale: scale) },
                                   grown: grown || shareSnapshot,
                                   delay: SensorCoverageCardMotion.growDelay(order: i))
                                .padding(.top, DS.Space.xxs)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(openLogbook == nil)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 6)
                .animation(reduceMotion ? nil : DSMotion.standard.animation.delay(SensorCoverageCardMotion.growDelay(order: i)),
                           value: grown)
                .transition(.opacity)
            }
        }
    }

    private func spoken(_ s: SensorCoverage, now: Date) -> String {
        [SensorCoverageText.spoken(s, now: now),
         InsightsCompare.spoken([("Coverage", InsightsCompare.coverage(s, before(s))),
                                 ("Gaps", InsightsCompare.coverageGaps(s, before(s)))],
                                previous: previousPhrase)]
            .compactMap { $0 }.joined(separator: " ")
    }

    private func open(_ gap: SensorCoverage.Gap?) {
        guard let openLogbook, let gap else { return }
        openLogbook(SensorCoverage.link(for: gap, now: Date()))
    }
}

// MARK: - Bars

/// A bar's first appearance: it grows from the leading edge after `delay`, as the card rises in.
/// Under Reduce Motion it fades in where it is instead. Once per appearance.
private struct CoverageBarEntrance: ViewModifier {
    let grown: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
                .opacity(grown ? 1 : 0)
                .animation(.easeInOut(duration: SensorCoverageCardMotion.reducedFade), value: grown)
        } else {
            content
                .scaleEffect(x: grown ? 1 : 0.001, anchor: .leading)
                .animation(.spring(response: 0.6, dampingFraction: 0.82).delay(delay), value: grown)
        }
    }
}

/// New lengths: the bar and its mark glide there, or cross-fade under Reduce Motion (nothing slides).
private struct CoverageBarChange<Key: Hashable>: ViewModifier {
    let key: Key
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            ZStack(alignment: .leading) {
                content.id(key).transition(.opacity)
            }
            .animation(.easeInOut(duration: SensorCoverageCardMotion.reducedFade), value: key)
        } else {
            content.dsAnimation(.emphasized, value: key)
        }
    }
}

/// The period before, on a track: a thin upright mark where its bar would end. It fades in and out
/// as Compare turns on and off.
private struct CompareMark: View {
    let fraction: Double?
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear.frame(height: 1)
            if let fraction {
                Capsule()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 2, height: 10)
                    .offset(x: max(0, width * fraction - 2))
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: SensorCoverageCardMotion.reducedFade), value: fraction == nil)
    }
}

/// The share of the period with readings, as a filled track under the figures. Hidden from
/// VoiceOver with the rest of the card's drawing: the card's value says it.
private struct CoverageMeter: View {
    let coverage: Double
    var previous: Double? = nil
    let grown: Bool

    private struct Key: Hashable { var coverage: Double; var previous: Double? }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06))
                Capsule()
                    .fill(Palette.brand)
                    .frame(width: geo.size.width * max(0, min(1, coverage)))
                    .modifier(CoverageBarEntrance(grown: grown, delay: SensorCoverageCardMotion.meterStart))
                CompareMark(fraction: previous.map { max(0, min(1, $0)) }, width: geo.size.width)
            }
            .modifier(CoverageBarChange(key: Key(coverage: coverage, previous: previous)))
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// One gap's length against the longest shown (or the period before's, while Compare is on).
private struct GapBar: View {
    let fraction: Double
    var previous: Double? = nil
    let grown: Bool
    let delay: Double

    private struct Key: Hashable { var fraction: Double; var previous: Double? }

    var body: some View {
        GeometryReader { geo in
            // A 10-minute gap beside a day-long one still shows.
            let minimum = 4 / max(1, geo.size.width)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06))
                Capsule()
                    .fill(Color.secondary)
                    .frame(width: geo.size.width * (fraction > 0 ? max(minimum, fraction) : 0))
                    .modifier(CoverageBarEntrance(grown: grown, delay: delay))
                CompareMark(fraction: previous, width: geo.size.width)
            }
            .modifier(CoverageBarChange(key: Key(fraction: fraction, previous: previous)))
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
