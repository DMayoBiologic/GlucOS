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

/// The days and their alerts, worked out from the logbook's alert records and the stored readings.
/// Recomputed as records arrive (a new alert, a tap synced from the other device), so the list
/// keeps up while it's open.
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
                        }
                    } header: {
                        HStack {
                            Text(ClockLabel.dayTitle(ClockLabel.day(of: day.start, now: now)))
                            Spacer()
                            Text(AlertHistoryText.count(day.items.count))
                                .monospacedDigit()
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
                    Label(AlertHistoryText.outcome(item), systemImage: item.outcome.symbol)
                        .labelStyle(.titleAndIcon)
                        .dsFont(.caption)
                        .foregroundStyle(.secondary)
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
