import SwiftUI

/// An opened Logbook day's time in range, broken down: below, in range and above, each with a
/// colour key, its share and how long it lasted ("4% · 1 h"). Shown under the day's chart on the
/// iPhone Logbook and in the Mac Day popover, so the bar's split can be read in numbers. The
/// colours match the bar (`GlucoseRange.low/inRange/high.tint`) and always sit beside the words.
/// A picture of text only: hidden from VoiceOver, whoever shows it says
/// `DayInRangeBreakdownText.spoken` in its one element. Nothing moves; the figures change at once.
/// On a day readings only partly cover, the hours are estimates ("78% · ≈18 h 40 min") with one
/// quiet line saying so; under half covered only the percents show (`DayInRange.times`).
struct DayRangeBreakdown: View {
    let figures: DayInRange

    private func tint(_ band: DayInRangePart.Band) -> Color {
        switch band {
        case .below: return GlucoseRange.low.tint
        case .inRange: return GlucoseRange.inRange.tint
        case .above: return GlucoseRange.high.tint
        }
    }

    var body: some View {
        let times = figures.times
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            // Wide enough for three across on every iPhone; stacks at the largest text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: DS.Space.md) { cells(times) }
                VStack(alignment: .leading, spacing: DS.Space.xs) { cells(times) }
            }
            if let note = DayInRangeBreakdownText.estimateNote(figures) {
                Text(note)
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func cells(_ times: DayInRange.Times) -> some View {
        ForEach(figures.parts, id: \.band) { part in
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                Circle()
                    .fill(tint(part.band))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 0) {
                    Text(DayInRangeBreakdownText.label(part.band))
                        .dsFont(.caption)
                        .foregroundStyle(.secondary)
                    Text(DayInRangeBreakdownText.figure(part, times: times))
                        .dsFont(.caption)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
            .fixedSize()
        }
    }
}
