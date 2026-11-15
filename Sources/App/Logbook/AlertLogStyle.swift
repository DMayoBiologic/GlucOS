import SwiftUI

// How an alert row looks in the Logbook, on the iPhone and the Mac (docs/AlertLog.md). Quiet on
// purpose: a small bell in the range's colour and secondary text, so the entries the user logged
// stay what the eye goes to.

extension AlertLogRow {
    /// The range the alert was about, for its colour.
    var range: GlucoseRange {
        switch kind {
        case .urgentLow, .predictedUrgentLow: return .urgentLow
        case .low, .predictedLow: return .low
        case .veryHigh, .predictedVeryHigh: return .veryHigh
        default: return .high
        }
    }

    var tint: Color { range.color }

    var systemImage: String { "bell" }

    /// "Snoozed 30 min at 10:06 · Went off 3 times, last at 10:35".
    var detail: String {
        var parts: [String] = []
        if response != nil && response != .other, let at = respondedAt {
            parts.append("\(responseText) at \(ClockLabel.time(at))")
        } else {
            parts.append(responseText)
        }
        if let repeatText { parts.append("\(repeatText), last at \(ClockLabel.time(last))") }
        return parts.joined(separator: " · ")
    }

    /// The setting that hides alert rows, shared by the iPhone and Mac Logbooks (each device keeps
    /// its own choice).
    static let showsKey = "logbookShowsAlerts"
}

/// One alert row, for lists (the iPhone Logbook).
struct AlertLogRowView: View {
    let row: AlertLogRow
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
            Image(systemName: row.systemImage)
                .imageScale(.small)
                .foregroundStyle(row.tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.title).dsFont(.caption).foregroundStyle(.secondary)
                Text(row.detail).dsFont(.caption).foregroundStyle(.tertiary)
                if typeSize.dsLargeText { time }
            }
            Spacer(minLength: DS.Space.sm)
            if !typeSize.dsLargeText { time }
        }
        .accessibilityElement(children: .combine)
    }

    private var time: some View {
        Text(ClockLabel.time(row.timestamp))
            .dsFont(.caption)
            .monospacedDigit()
            .foregroundStyle(.tertiary)
    }
}
