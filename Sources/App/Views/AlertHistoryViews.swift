import SwiftUI

// Settings › Alerts › History on the iPhone and the Mac (docs/AlertHistory.md): the last 7 days of
// low and high alerts, grouped by day, each one a button into the Logbook around it. The rules and
// words are in `AlertHistory` / `AlertHistoryText` (Sources/Engine/AlertHistory.swift).

extension AlertHistory.Item {
    /// The range the alert was about, for its bell's colour (as the Logbook's alert rows).
    var range: GlucoseRange {
        switch kind {
        case .urgentLow, .predictedUrgentLow: return .urgentLow
        case .low, .predictedLow: return .low
        case .veryHigh, .predictedVeryHigh: return .veryHigh
        default: return .high
        }
    }
}

extension AlertHistory.Outcome {
    /// The status chip's colour: a tap on "Log treatment" reads as done, a snooze as noted, the
    /// rest as plain.
    var tone: Tone {
        switch self {
        case .treating: return .success
        case .snoozed: return .info
        case .dismissed, .noResponse: return .neutral
        }
    }
}

/// The days and their alerts, worked out from the logbook's alert records and the stored readings.
/// Recomputed as records arrive (a new alert, a tap synced from the other device), so the list
/// keeps up while it's open: a new alert slides in at the top and a row's status chip morphs to
/// its new outcome (docs/AlertHistory.md, "Live while open"). Instant under Reduce Motion.
///
/// VoiceOver hears each change once through `alertHistoryAnnouncements`, which the screen around
/// the list applies (a `List`'s sections come and go, so they can't watch for it themselves).
struct AlertHistoryContent: View {
    let records: [AlertRecord]
    let readings: [GlucoseReading]
    let unit: GlucoseUnit
    let alertsOn: Bool
    /// A row was picked: the Logbook around it.
    let open: (LogbookLink) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let now = Date()
        let items = AlertHistory.items(records: records, readings: readings, now: now)
        let days = AlertHistory.days(items)
        Group {
            if days.isEmpty {
                Section {
                    EmptyStateView(systemImage: alertsOn ? "bell" : "bell.slash",
                                   title: AlertHistoryText.emptyTitle,
                                   message: AlertHistoryText.emptyMessage(alertsOn: alertsOn))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Space.lg)
                        .accessibilityElement(children: .combine)
                }
            } else {
                ForEach(days) { day in
                    Section {
                        ForEach(day.items) { item in
                            AlertHistoryRow(item: item, unit: unit) {
                                open(AlertHistory.link(for: item, records: records, now: Date()))
                            }
                            .transition(DS.Transition.banner(reduceMotion: reduceMotion))
                        }
                    } header: {
                        HStack {
                            Text(ClockLabel.dayTitle(ClockLabel.day(of: day.start, now: now)))
                            Spacer()
                            Text(AlertHistoryText.count(day.items.count))
                                .monospacedDigit()
                                .contentTransition(reduceMotion ? .identity : .numericText())
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                    }
                }
            }
        }
        // A new alert slides in at the top; instant under Reduce Motion.
        .dsAnimation(.standard, value: items.map(\.id))
    }
}

/// Speaks what changes in the alert history while it's open, once per change: a new alert, or an
/// alert's outcome moving on (`AlertHistory.changes`, `AlertHistoryText.announcement`). A short
/// pause gathers a burst, so the Mac's and the iPhone's copies of one alert syncing in a moment
/// apart are spoken once. Nothing is said for what was already listed when it opened.
private struct AlertHistoryAnnouncements: ViewModifier {
    let records: [AlertRecord]
    let readings: [GlucoseReading]
    let unit: GlucoseUnit

    /// How long a burst of changes is gathered before its one announcement.
    static let delay: Duration = .milliseconds(600)

    /// What VoiceOver was last told about: the list as it opened, then after each announcement.
    @State private var announced: [AlertHistory.Item]?
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        let items = AlertHistory.items(records: records, readings: readings, now: Date())
        content
            .onAppear { if announced == nil { announced = items } }
            .onChange(of: items) { _, latest in announceSoon(latest) }
            .onDisappear {
                pending?.cancel()
                pending = nil
            }
    }

    private func announceSoon(_ latest: [AlertHistory.Item]) {
        guard announced != nil else {
            announced = latest
            return
        }
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled, let base = announced else { return }
            announced = latest
            let changes = AlertHistory.changes(from: base, to: latest, now: Date())
            if let text = AlertHistoryText.announcement(changes, unit: unit) {
                LoggedElsewhere.announce(text)
            }
        }
    }
}

extension View {
    /// One VoiceOver announcement per change to the alert history shown inside (a `List` of
    /// `AlertHistoryContent`), while it's open.
    func alertHistoryAnnouncements(records: [AlertRecord], readings: [GlucoseReading], unit: GlucoseUnit) -> some View {
        modifier(AlertHistoryAnnouncements(records: records, readings: readings, unit: unit))
    }
}

/// One alert: a bell in the range's colour, what it was and what happened to it, and when, with the
/// reading. One VoiceOver element that reads it all and opens the Logbook.
struct AlertHistoryRow: View {
    let item: AlertHistory.Item
    let unit: GlucoseUnit
    let open: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Image(systemName: "bell.fill")
                    .imageScale(.small)
                    .foregroundStyle(item.range.color)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .dsFont(.body)
                        .foregroundStyle(.primary)
                    AlertOutcomeChip(item: item)
                    if typeSize.dsLargeText { trailing(alignment: .leading) }
                }
                Spacer(minLength: DS.Space.sm)
                if !typeSize.dsLargeText { trailing(alignment: .trailing) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AlertHistoryText.spoken(item, unit: unit))
        .accessibilityHint(AlertHistoryText.hint)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
    }

    private func trailing(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(ClockLabel.time(item.firedAt))
                .dsFont(.callout)
                .monospacedDigit()
            Text(AlertHistoryText.reading(item.readingMgdl, unit: unit))
                .dsFont(.caption)
                .monospacedDigit()
                .foregroundStyle(item.readingMgdl == nil ? HierarchicalShapeStyle.tertiary : HierarchicalShapeStyle.secondary)
        }
    }
}

/// What happened to an alert, as a small status chip. When the outcome moves on while the list is
/// open (snoozed, "Log treatment" tapped, dismissed, on either device) the chip morphs: the symbol
/// replaces itself, the words blend, the tint glides, on the `.emphasized` spring. Instant under
/// Reduce Motion. The row speaks for it, so the chip is hidden from VoiceOver.
struct AlertOutcomeChip: View {
    let item: AlertHistory.Item

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let tone = item.outcome.tone
        HStack(spacing: DS.Space.xs) {
            Image(systemName: item.outcome.symbol)
                .imageScale(.small)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            Text(AlertHistoryText.outcome(item))
                .contentTransition(reduceMotion ? .identity : .interpolate)
        }
        .dsFont(.caption)
        .fontWeight(.medium)
        .lineLimit(1)
        .foregroundStyle(tone.textColor)
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, 2)
        .background(tone.color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(tone.color.opacity(contrast == .increased ? 0.9 : 0.28),
                                        lineWidth: contrast == .increased ? DS.Stroke.increased : 0.5))
        .dsAnimation(.emphasized, value: item.outcome)
        .accessibilityHidden(true)
    }
}

/// A row picked in the iPhone's alert history, for the home stack: Settings closes and the Logbook
/// opens around that alert. Cleared by the screen that opened it.
@MainActor
final class AlertHistoryRoute: ObservableObject {
    static let shared = AlertHistoryRoute()
    @Published var request: LogbookLink?

    func open(_ link: LogbookLink) { request = link }

    func take() -> LogbookLink? {
        guard let link = request else { return nil }
        request = nil
        return link
    }
}
