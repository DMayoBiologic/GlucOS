import SwiftUI

/// The Insights "Alerts" card on the Mac and iPhone (docs/InsightsAlerts.md): how many low and high
/// alerts went off over the last 7, 14 or 30 days, by kind, and how each one ended (`AlertsSummary`).
/// Built from the same records as Settings › Alerts › Alert History.
///
/// Motion (`AlertsCardMotion`, docs/InsightsAlerts.md): the figures count up once as the card
/// rises in (`onEntrance`, docs/InsightsLayout.md) and roll to new values when the period changes.
/// The kind bars grow in from the leading edge one after another, then the outcome bar, and all of
/// them glide to new counts between periods and when Compare to previous period adds or removes
/// the period before's marks. Nothing loops. Under Reduce Motion the bars fade in and cross-fade
/// to new values instead of moving. Callers give it their own card surface.
///
/// The screen leaves the card out until an alert has been recorded (`AlertsSummary.shows`); a
/// period with none shows the empty note instead (docs/EmptyStates.md). With `openHistory`,
/// tapping the card, or its "Open Alert History" row, opens Settings › Alerts › Alert History.
struct AlertsCardView: View {
    let records: [AlertRecord]
    let readings: [GlucoseReading]
    var openHistory: (() -> Void)? = nil

    /// Insights stepped back to an earlier period (docs/InsightsPeriodStep.md).
    @Environment(\.insightsStep) private var step
    @AppStorage(InsightsShare.Key.alerts) private var periodDays = AlertsSummary.Period.fortnight.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.insightsShareSnapshot) private var shareSnapshot
    /// "Compare to previous period" (docs/InsightsCompare.md) and the period before, while it's on.
    @AppStorage(InsightsCompare.storageKey) private var compare = false
    @State private var previous: AlertsSummary?

    private var period: AlertsSummary.Period { AlertsSummary.Period(rawValue: periodDays) ?? .fortnight }

    /// Now on the latest; where the other cards' period ends once Insights is stepped back.
    private func end(now: Date) -> Date {
        guard step.back > 0, let latest = readings.last?.timestamp else { return now }
        return InsightsPeriodStep.end(latest: latest, days: period.days, back: step.back)
    }

    /// What the period before is worked out again for.
    private struct PreviousKey: Hashable {
        var period: AlertsSummary.Period
        var start: Date
        var records: Int
        var readings15: Int
    }

    var body: some View {
        let s = AlertsSummary.compute(records: records, period: period, end: end(now: Date()))
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Eyebrow(title: AlertsSummaryText.title, systemImage: "bell.badge", trailing: "Low and high")
            // A shared picture names the period in its footer instead (docs/InsightsShare.md).
            if !shareSnapshot {
                Picker("Period", selection: $periodDays) {
                    ForEach(AlertsSummary.Period.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // One stop on the Mac: ← → pick the period beside it.
                .keyStop("insights.alerts.period", radius: DS.Radius.control)
                .keyCycle($periodDays, through: AlertsSummary.Period.allCases.map(\.rawValue))
                .accessibilityLabel("Period")
            }
            // Which dates the card shows once Insights is stepped back (docs/InsightsPeriodStep.md).
            InsightsStepCaption(days: period.days, latest: readings.last?.timestamp)

            if s.count > 0 {
                content(s)
            } else {
                emptyNote(s)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The period before, only while the switch is on: worked out off the main thread once per
        // change, and nothing extra shows when it can't be compared fairly.
        .task(id: compare ? PreviousKey(period: s.period, start: s.start.roundedDownToMinute,
                                        records: records.count, readings15: readings.count / 15) : nil) {
            guard compare else { previous = nil; return }
            let records = records, readings = readings
            let new = await Task.detached(priority: .utility) {
                AlertsSummary.previous(records: records, readings: readings, current: s)
            }.value
            DS.animate(.standard, reduceMotion: reduceMotion) { previous = new }
        }
    }

    /// The period before, when the switch is on and it could be compared.
    private func before(_ s: AlertsSummary) -> AlertsSummary? {
        guard compare, let previous, previous.period == s.period else { return nil }
        return previous
    }

    @ViewBuilder
    private func content(_ s: AlertsSummary) -> some View {
        let phrase = InsightsCompare.previousPhrase(days: s.period.days)
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(AlertsSummaryText.headline(s))
                .dsFont(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            DSAccessibleStack(verticalAlignment: .top, spacing: DS.Space.md) {
                StatTile("Alerts", value: AlertsSummaryText.countValue(s.count),
                         rolling: .init(Double(s.count)) { AlertsSummaryText.countValue(Int($0.rounded())) }) {
                    InsightsDeltaBadge(delta: InsightsCompare.alerts(s, before(s)), previous: phrase)
                }
                StatTile("Low", value: AlertsSummaryText.countValue(s.lows),
                         tone: s.lows > 0 ? .glucose(.low) : .neutral,
                         rolling: .init(Double(s.lows), order: 1) { AlertsSummaryText.countValue(Int($0.rounded())) }) {
                    InsightsDeltaBadge(delta: InsightsCompare.lowAlerts(s, before(s)), previous: phrase)
                }
                StatTile("High", value: AlertsSummaryText.countValue(s.highs),
                         tone: s.highs > 0 ? .glucose(.high) : .neutral,
                         rolling: .init(Double(s.highs), order: 2) { AlertsSummaryText.countValue(Int($0.rounded())) }) {
                    InsightsDeltaBadge(delta: InsightsCompare.highAlerts(s, before(s)), previous: phrase)
                }
            }
            .monospacedDigit()

            AlertsKindBars(counts: AlertsSummary.Group.allCases.map { s.count($0) },
                           previous: AlertsCardMotion.previousKinds(before(s)))

            AlertsEndingBar(counts: AlertsSummary.Ending.allCases.map { s.count($0) },
                            previous: AlertsCardMotion.previousEndings(before(s)))

            if let line = AlertsSummaryText.answeredLine(s) {
                Text(line)
                    .dsFont(.callout)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            Text(AlertsSummaryText.footnote(s))
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // One stop for VoiceOver: the period's alerts in a few sentences.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AlertsSummaryText.title)
        .accessibilityValue([AlertsSummaryText.spoken(s),
                             InsightsCompare.spoken([("Alerts", InsightsCompare.alerts(s, before(s))),
                                                     ("Low alerts", InsightsCompare.lowAlerts(s, before(s))),
                                                     ("High alerts", InsightsCompare.highAlerts(s, before(s)))],
                                                    previous: phrase)]
            .compactMap { $0 }.joined(separator: " "))
        // Opens Alert History for VoiceOver too, from the same one stop; the summary stays one
        // element and never speaks again on its own as the bars move.
        .accessibilityAddTraits(openHistory != nil && !shareSnapshot ? .isButton : [])
        .accessibilityHint(openHistory != nil && !shareSnapshot ? AlertsSummaryText.historyHint : "")
        .accessibilityAction { openHistory?() }
        // The figures open Alert History too, not just the row under them. The period picker stays
        // its own control.
        .contentShape(Rectangle())
        .onTapGesture { openHistory?() }
        if let openHistory, !shareSnapshot {
            Button { openHistory() } label: {
                HStack(spacing: DS.Space.xs) {
                    Text(AlertsSummaryText.historyLine)
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
            .keyStop("insights.alerts.open", kind: .control, radius: DS.Radius.control) { openHistory() }
            .accessibilityHint(AlertsSummaryText.historyHint)
        }
    }

    /// No alerts in this period: why, and the shortest longer period that had some, when one did
    /// (`InsightsEmptyState.alerts`, docs/EmptyStates.md).
    private func emptyNote(_ s: AlertsSummary) -> some View {
        let records = records, period = period, end = s.end
        return InsightsEmptyNote(id: AnyHashable([AnyHashable(period), AnyHashable(s.start.roundedDownToMinute),
                                                  AnyHashable(records.count)]),
                                 waiting: "No alerts in \(period.spoken).", decide: {
            let longer = AlertsSummary.longerWithAlerts(records: records, than: period, end: end)
            return InsightsEmptyState.alerts(currentDays: period.days, longerWithAlerts: longer?.days)
        }, act: { action in
            if case .showPeriod(let days) = action { periodDays = days }
        })
    }
}

private extension Date {
    /// So a key built from "now" doesn't change on every redraw.
    var roundedDownToMinute: Date {
        Date(timeIntervalSinceReferenceDate: (timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }
}

/// A bar's first appearance: it grows from the leading edge after `delay`, as the card rises in
/// (`onEntrance`). Under Reduce Motion it fades in where it is instead. Once per appearance.
private struct BarEntrance: ViewModifier {
    let grown: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
                .opacity(grown ? 1 : 0)
                .animation(.easeInOut(duration: AlertsCardMotion.reducedFade), value: grown)
        } else {
            content
                .scaleEffect(x: grown ? 1 : 0.001, anchor: .leading)
                .animation(.spring(response: 0.6, dampingFraction: 0.82).delay(delay), value: grown)
        }
    }
}

/// New counts: the bars glide to their new lengths, or cross-fade to them under Reduce Motion
/// (the old picture fades out as the new one fades in, nothing slides).
private struct BarChange<Key: Hashable>: ViewModifier {
    let key: Key
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            ZStack(alignment: .leading) {
                content.id(key).transition(.opacity)
            }
            .animation(.easeInOut(duration: AlertsCardMotion.reducedFade), value: key)
        } else {
            content.dsAnimation(.emphasized, value: key)
        }
    }
}

/// Sets `grown` on the card's entrance, a frame later so the bars are laid out empty first.
private struct GrowOnEntrance: ViewModifier {
    @Binding var grown: Bool

    func body(content: Content) -> some View {
        content.onEntrance {
            guard !grown else { return }
            DispatchQueue.main.async { grown = true }
        }
    }
}

/// The alerts by kind, as four bars (low, predicted low, high, predicted high), each with its
/// count. The bars grow in from the leading edge one after another as the card rises in, then
/// glide to new counts when the period changes. With Compare on, a thin mark on each track shows
/// the period before, sharing the bars' scale, so turning Compare on or off glides the bars to the
/// new scale and the marks slide in or out with them. Hidden from VoiceOver: the card's summary
/// says the same in words.
private struct AlertsKindBars: View {
    let counts: [Int]
    /// The period before's counts, while Compare shows them.
    var previous: [Int]? = nil

    @State private var grown = false

    private struct Key: Hashable { var counts: [Int]; var previous: [Int]? }

    var body: some View {
        let scale = AlertsCardMotion.scale(counts: counts, previous: previous)
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(AlertsSummaryText.byKind)
                .dsFont(.label)
                .foregroundStyle(.secondary)
            ForEach(AlertsSummary.Group.allCases) { group in
                let i = group.rawValue
                let n = i < counts.count ? counts[i] : 0
                let before = previous.flatMap { i < $0.count ? $0[i] : nil }
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(AlertsSummaryText.group(group))
                            .foregroundStyle(n > 0 ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.secondary))
                        Spacer(minLength: DS.Space.sm)
                        RollingFigure(Double(n), order: i) { "\(Int($0.rounded()))" }
                            .monospacedDigit()
                    }
                    .dsFont(.caption)
                    GeometryReader { geo in
                        let minimum = 6 / max(1, geo.size.width)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.06))
                            // The range's hue at full strength, as a graphic needs; the count beside
                            // it is the text.
                            Capsule()
                                .fill(group.isLow ? GlucoseRange.low.tint : GlucoseRange.high.tint)
                                .frame(width: geo.size.width * AlertsCardMotion.fraction(n, scale: scale, minimum: minimum))
                                .modifier(BarEntrance(grown: grown, delay: AlertsCardMotion.growDelay(order: i)))
                            // The period before: a thin upright mark where its bar would end.
                            if let before, before > 0 {
                                Capsule()
                                    .fill(Color.primary.opacity(0.55))
                                    .frame(width: 2, height: 10)
                                    .offset(x: max(0, geo.size.width * AlertsCardMotion.fraction(before, scale: scale,
                                                                                               minimum: minimum) - 2))
                                    .transition(.opacity)
                            }
                        }
                        .modifier(BarChange(key: Key(counts: counts, previous: previous)))
                    }
                    .frame(height: 6)
                }
            }
            if previous != nil {
                HStack(spacing: DS.Space.xs) {
                    Capsule().fill(Color.primary.opacity(0.55)).frame(width: 2, height: 10)
                    Text(AlertsSummaryText.previousMarkKey)
                }
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .transition(.opacity)
            }
        }
        .dsAnimation(.standard, value: previous != nil)
        .accessibilityHidden(true)
        .modifier(GrowOnEntrance(grown: $grown))
    }
}

/// How the alerts ended, as one bar split by outcome with a key under it: each part's symbol,
/// name and count, so the colour is never the only cue. The bar grows in once, after the kind
/// bars, and its parts glide to new shares. With Compare on, a thinner bar under it shows how the
/// period before ended and grows in beside it. Cross-fades under Reduce Motion. Hidden from
/// VoiceOver: the card's summary says the same in words.
private struct AlertsEndingBar: View {
    let counts: [Int]
    /// The period before's counts, while Compare shows them.
    var previous: [Int]? = nil

    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func color(_ e: AlertsSummary.Ending) -> Color {
        switch e {
        // As the Alert History's outcome chips: treating in green, snoozed in the accent.
        case .treating: return Tone.success.color
        case .snoozed: return Tone.info.color
        case .dismissed: return Palette.neutral
        case .noResponse: return Color.primary.opacity(0.22)
        }
    }

    /// One split bar. Every outcome keeps its place, a missing one just has no width, so a new
    /// outcome widens into place instead of the colours shifting along.
    private func split(_ counts: [Int], height: CGFloat, faded: Bool) -> some View {
        let shares = AlertsCardMotion.shares(counts)
        return GeometryReader { geo in
            let parts = shares.filter { $0 > 0 }.count
            let room = max(0, geo.size.width - 2 * CGFloat(max(0, parts - 1)))
            HStack(spacing: 0) {
                ForEach(AlertsSummary.Ending.allCases) { e in
                    let share = e.rawValue < shares.count ? shares[e.rawValue] : 0
                    Capsule()
                        .fill(color(e).opacity(faded ? 0.55 : 1))
                        .frame(width: share > 0 ? max(4, room * share) : 0)
                        .padding(.trailing, share > 0 && e.rawValue < shares.count - 1 ? 2 : 0)
                }
                Spacer(minLength: 0)
            }
            .modifier(BarChange(key: counts))
        }
        .frame(height: height)
        .clipShape(Capsule())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(AlertsSummaryText.howTheyEnded)
                .dsFont(.label)
                .foregroundStyle(.secondary)
            split(counts, height: 8, faded: false)
                .modifier(BarEntrance(grown: grown, delay: AlertsCardMotion.endingStart))
            if let previous {
                HStack(spacing: DS.Space.xs) {
                    Text(AlertsSummaryText.previousShort)
                        .dsFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    split(previous, height: 4, faded: true)
                }
                .transition(reduceMotion ? AnyTransition.opacity
                            : AnyTransition.scale(scale: 0.001, anchor: .leading).combined(with: .opacity))
            }
            // The key: every outcome with any alerts, two to a row so they fit a phone.
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: DS.Space.xs) {
                ForEach(AlertsSummary.Ending.allCases) { e in
                    let n = e.rawValue < counts.count ? counts[e.rawValue] : 0
                    if n > 0 {
                        HStack(spacing: DS.Space.xs) {
                            Image(systemName: e.symbol)
                                .imageScale(.small)
                                .foregroundStyle(symbolStyle(e))
                            Text(AlertsSummaryText.ending(e))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            RollingFigure(Double(n), order: e.rawValue) { "\(Int($0.rounded()))" }
                                .monospacedDigit()
                        }
                        .dsFont(.caption)
                    }
                }
            }
        }
        .dsAnimation(.emphasized, value: previous != nil)
        .accessibilityHidden(true)
        .modifier(GrowOnEntrance(grown: $grown))
    }

    /// The key's symbol: the part's own colour, or secondary for the faint "no response" part.
    private func symbolStyle(_ e: AlertsSummary.Ending) -> AnyShapeStyle {
        e == .noResponse ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(color(e))
    }
}

// MARK: - Opening Alert History from Insights

/// A tap on the Insights Alerts card, for whichever screen opens Settings: the iPhone's home stack
/// opens its Settings sheet on Alert History, the Mac's Alerts settings tab opens its Alert History
/// sheet. A request left unanswered for more than a few seconds is dropped, so it never opens the
/// sheet by surprise later.
@MainActor
final class AlertHistoryOpenRequest: ObservableObject {
    static let shared = AlertHistoryOpenRequest()
    static let lifetime: TimeInterval = 10

    @Published private(set) var requestedAt: Date?

    func open(now: Date = Date()) { requestedAt = now }

    /// True once, for a request still fresh.
    func take(now: Date = Date()) -> Bool {
        guard let at = requestedAt else { return false }
        requestedAt = nil
        return now.timeIntervalSince(at) <= Self.lifetime
    }
}
