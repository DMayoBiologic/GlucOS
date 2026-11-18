import SwiftUI

/// The Insights "Alerts" card on the Mac and iPhone (docs/InsightsAlerts.md): how many low and high
/// alerts went off over the last 7, 14 or 30 days, by kind, and how each one ended (`AlertsSummary`).
/// Built from the same records as Settings › Alerts › Alert History.
///
/// Motion is the Lows and Highs cards': the figures count up where `figuresCountUp` is on and roll
/// to new values when the period changes, the bars grow in once as the card rises in
/// (`onEntrance`, docs/InsightsLayout.md) and glide to new counts. Nothing loops, and Reduce Motion
/// shows the new values at once. Callers give it their own card surface.
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

            AlertsKindBars(counts: AlertsSummary.Group.allCases.map { s.count($0) })

            AlertsEndingBar(counts: AlertsSummary.Ending.allCases.map { s.count($0) })

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

/// The alerts by kind, as four bars (low, predicted low, high, predicted high), each with its
/// count. The bars grow in from the leading edge once, then glide to new counts. Hidden from
/// VoiceOver: the card's summary says the same in words.
private struct AlertsKindBars: View {
    let counts: [Int]

    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let top = max(1, counts.max() ?? 1)
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(AlertsSummaryText.byKind)
                .dsFont(.label)
                .foregroundStyle(.secondary)
            ForEach(AlertsSummary.Group.allCases) { group in
                let n = group.rawValue < counts.count ? counts[group.rawValue] : 0
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(AlertsSummaryText.group(group))
                            .foregroundStyle(n > 0 ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.secondary))
                        Spacer(minLength: DS.Space.sm)
                        RollingFigure(Double(n), order: group.rawValue) { "\(Int($0.rounded()))" }
                            .monospacedDigit()
                    }
                    .dsFont(.caption)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.06))
                            // The range's hue at full strength, as a graphic needs; the count beside
                            // it is the text.
                            Capsule()
                                .fill(group.isLow ? GlucoseRange.low.tint : GlucoseRange.high.tint)
                                .frame(width: n == 0 ? 0 : max(6, geo.size.width * Double(n) / Double(top)))
                                .dsAnimation(.emphasized, value: counts)
                                .scaleEffect(x: grown ? 1 : 0.001, anchor: .leading)
                                .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.82)
                                    .delay(0.15 + Double(group.rawValue) * 0.045), value: grown)
                        }
                    }
                    .frame(height: 6)
                }
            }
        }
        .accessibilityHidden(true)
        .onEntrance {
            guard !grown else { return }
            if reduceMotion { grown = true } else {
                // Next frame, so the bars are laid out empty first.
                DispatchQueue.main.async { grown = true }
            }
        }
    }
}

/// How the alerts ended, as one bar split by outcome with a key under it: each part's symbol,
/// name and count, so the colour is never the only cue. The bar grows in once and its parts glide
/// to new shares. Hidden from VoiceOver: the card's summary says the same in words.
private struct AlertsEndingBar: View {
    let counts: [Int]

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

    var body: some View {
        let total = max(1, counts.reduce(0, +))
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(AlertsSummaryText.howTheyEnded)
                .dsFont(.label)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(AlertsSummary.Ending.allCases) { e in
                        let n = e.rawValue < counts.count ? counts[e.rawValue] : 0
                        if n > 0 {
                            Capsule()
                                .fill(color(e))
                                .frame(width: max(4, (geo.size.width - 6) * Double(n) / Double(total)))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .dsAnimation(.emphasized, value: counts)
                .scaleEffect(x: grown ? 1 : 0.001, anchor: .leading)
                .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.82).delay(0.3), value: grown)
            }
            .frame(height: 8)
            .clipShape(Capsule())
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
        .accessibilityHidden(true)
        .onEntrance {
            guard !grown else { return }
            if reduceMotion { grown = true } else {
                DispatchQueue.main.async { grown = true }
            }
        }
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
