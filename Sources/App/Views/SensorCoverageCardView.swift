import SwiftUI

/// The Insights "Sensor coverage" card on the Mac and iPhone: how much of the last 7, 14 or 30 days
/// has readings, and the longest gaps with the chart's reasons for them (`SensorCoverage`,
/// docs/SensorCoverage.md). The screen leaves it out while coverage is 99% or more
/// (`SensorCoverageCache.shows`).
///
/// Motion is the other period cards': the figures count up as the card rises in and roll to new
/// values when the period changes; the gap rows slide up into place one after another as the card
/// rises (`onEntrance`). Nothing loops, and Reduce Motion shows it all at once. Callers give it their
/// own card surface.
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
    /// The gap rows have slid in (once per appearance).
    @State private var rowsIn = false
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
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text("Longest gaps")
                .dsFont(.label)
                .foregroundStyle(.secondary)
            ForEach(Array(s.longest.enumerated()), id: \.element.id) { i, gap in
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
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(openLogbook == nil)
                .opacity(rowsIn || reduceMotion || shareSnapshot ? 1 : 0)
                .offset(y: rowsIn || reduceMotion || shareSnapshot ? 0 : 6)
                .animation(reduceMotion ? nil : DSMotion.standard.animation.delay(0.06 * Double(i)), value: rowsIn)
                .transition(.opacity)
            }
        }
        .onEntrance {
            guard !rowsIn else { return }
            rowsIn = true
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
