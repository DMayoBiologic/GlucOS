import SwiftUI

/// The last 7 days card behind the time-in-range figure (docs/RecentDays.md): each of the last
/// seven days' time in range as a mini bar, today last. A long-press on iPhone Today's Insights row
/// or a click on the Mac popover's time-in-range bar opens it; picking a bar closes it and opens
/// the Logbook on that day (`LogbookLink.recentDay`).
///
/// The bars grow up from the baseline one after another as the card opens, oldest first, on the
/// `.emphasized` spring; under Reduce Motion they fade in at full height. Once per opening, nothing
/// loops. VoiceOver reads one line per day ("Yesterday, 78% in range, 4% below").
struct RecentDaysCard: View {
    let days: RecentDays
    let now: Date
    let open: (LogbookLink) -> Void

    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let barHeight: CGFloat = 64
    static let barWidth: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(RecentDaysText.title)
                    .dsFont(.eyebrow)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Text(RecentDaysText.caption)
                    .dsFont(.caption)
                    .foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if days.hasFigures {
                HStack(alignment: .bottom, spacing: DS.Space.xs) {
                    ForEach(Array(days.days.enumerated()), id: \.element.id) { i, day in bar(day, index: i) }
                }
            } else {
                Text(RecentDaysText.empty)
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.lg)
        .frame(minWidth: 280, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            guard !grown else { return }
            // Next frame, so the bars are laid out at the baseline (or clear) first.
            DispatchQueue.main.async { grown = true }
        }
    }

    private func bar(_ day: RecentDays.Day, index: Int) -> some View {
        let isToday = Calendar.autoupdatingCurrent.isDate(day.start, inSameDayAs: now)
        return Button {
            open(.recentDay(day.start, now: now))
        } label: {
            VStack(spacing: DS.Space.xxs) {
                Text(RecentDaysText.barFigure(day))
                    .dsFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .opacity(grown ? 1 : 0)
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                    if let f = day.figures {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(GlucoseRange.inRange.tint)
                            .frame(height: max(2, Self.barHeight * f.inRange))
                            .scaleEffect(y: grown || reduceMotion ? 1 : 0.001, anchor: .bottom)
                            .opacity(grown || !reduceMotion ? 1 : 0)
                    }
                }
                .frame(width: Self.barWidth, height: Self.barHeight)
                Text(RecentDaysText.barLabel(day, now: now))
                    .fontWeight(isToday ? .semibold : .regular)
                    .dsFont(.caption)
                    .foregroundStyle(isToday ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(minWidth: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? .easeOut(duration: 0.2)
                                : DSMotion.emphasized.animation.delay(RecentDays.growDelay(index)),
                   value: grown)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RecentDaysText.spoken(day, now: now))
        .accessibilityHint(RecentDaysText.barHint)
        .accessibilityAddTraits(.isButton)
        #if os(macOS)
        .help(RecentDaysText.spoken(day, now: now))
        #endif
    }
}

/// Puts `RecentDaysCard` in a popover off the view it's attached to (kept a popover on iPhone
/// too, rather than a sheet). The days are worked out when it opens. Picking a bar closes the
/// card, then hands its link on, so the Logbook opens once the popover has gone.
struct RecentDaysPopover: ViewModifier {
    @Binding var isPresented: Bool
    let readings: [GlucoseReading]
    let lowMgdl: Double
    let highMgdl: Double
    let open: (LogbookLink) -> Void

    func body(content: Content) -> some View {
        content
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                let now = Date()
                RecentDaysCard(days: RecentDays.compute(readings: readings, low: lowMgdl, high: highMgdl, now: now),
                               now: now) { link in
                    isPresented = false
                    DispatchQueue.main.async { open(link) }
                }
                .presentationCompactAdaptation(.popover)
            }
    }
}

extension View {
    func recentDaysPopover(isPresented: Binding<Bool>, readings: [GlucoseReading], lowMgdl: Double,
                           highMgdl: Double, open: @escaping (LogbookLink) -> Void) -> some View {
        modifier(RecentDaysPopover(isPresented: isPresented, readings: readings, lowMgdl: lowMgdl,
                                   highMgdl: highMgdl, open: open))
    }
}
