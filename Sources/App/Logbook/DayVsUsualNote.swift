import SwiftUI

/// "↗ +12 vs your usual": a quiet note on a Logbook day whose time in range was 10 or more points
/// from its usual (`DayVsUsual`), under the day's name on iPhone and in the Mac Day cell. Tapping
/// or clicking it opens a short explanation of how the usual was worked out, in a popover on both.
///
/// Neutral on purpose: secondary text and an arrow, never the low or high colours, since a day
/// below its usual isn't an alarm. A picture of text for VoiceOver: whoever shows it says
/// `DayVsUsualText.spoken` once in the day's own element and offers `DayVsUsualText.actionName`,
/// which opens the same explanation. It fades in and out with the day, nothing loops.
struct DayVsUsualNote: View {
    let comparison: DayVsUsual
    /// The day said in full, for the explanation ("Tuesday 12 November").
    let spokenDay: String
    @Binding var explaining: Bool

    var body: some View {
        Button { explaining = true } label: {
            HStack(spacing: 3) {
                Image(systemName: DayVsUsualText.symbol(comparison))
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                Text(DayVsUsualText.short(comparison))
                    .dsFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .help(DayVsUsualText.help(comparison))
        #endif
        .accessibilityHidden(true)
        .popover(isPresented: $explaining, arrowEdge: .top) {
            DayVsUsualExplanation(comparison: comparison, spokenDay: spokenDay)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// What the note's popover says: the usual, the day against it, and when a note shows.
struct DayVsUsualExplanation: View {
    let comparison: DayVsUsual
    let spokenDay: String

    var body: some View {
        let lines = DayVsUsualText.explanation(comparison, spokenDay: spokenDay)
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(DayVsUsualText.title).dsFont(.headline)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .dsFont(.caption)
                    .foregroundStyle(line == lines.last ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.lg)
        .frame(width: 300, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
