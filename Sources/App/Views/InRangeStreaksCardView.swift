import SwiftUI

/// The Insights "In-range streaks" card on the Mac and iPhone: the run of days in a row at 70% or
/// more in range going now, the longest run in the readings kept, and the last 14 days as a row of
/// dots (`InRangeStreaks`). Worked out off the main thread once per data change
/// (`InRangeStreaksCache`).
///
/// Motion: the two figures count up where `figuresCountUp` is on (iPhone and Mac Insights) and roll
/// to new values later; the dots fill in left to right with a short stagger the first time the card
/// shows there. Nothing loops, and Reduce Motion shows everything at once. Callers give it their
/// own card surface.
///
/// With `openLogbook`, the card is a button that opens the Logbook on the Longest streak chip over
/// the longest run's days (`LogbookLink.bestStreak`). The iPhone zooms the card into it; the Mac
/// cross-fades to its Logbook section (docs/LogbookSearch.md, "From the Insights cards").
struct InRangeStreaksCardView: View {
    let readings: [GlucoseReading]
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    var openLogbook: ((LogbookLink) -> Void)? = nil

    @State private var value: InRangeStreaks?
    @State private var shownKey: InRangeStreaksCache.Key?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// "3.9–10.0 mmol/L".
    private var rangeLine: String {
        "\(unit.format(mgdl: lowMgdl))–\(unit.format(mgdl: highMgdl)) \(unit.label)"
    }

    var body: some View {
        let key = InRangeStreaksCache.key(readings: readings, low: lowMgdl, high: highMgdl)
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Eyebrow(title: InRangeStreaksText.title, systemImage: "flame",
                    trailing: "\(InRangeStreaksText.goalPercent)+ in range")
            if let value {
                content(value)
            } else if shownKey == key {
                emptyNote(key)
            } else {
                // Working it out: hold the space without a spinner.
                Color.clear.frame(height: 120)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: key) {
            let new: InRangeStreaks?
            if let hit = InRangeStreaksCache.shared.cached(key) {
                new = hit
            } else {
                new = await InRangeStreaksCache.shared.value(for: key, readings: readings)
            }
            if value == nil || new == nil {
                value = new
            } else {
                DS.animate(.standard, reduceMotion: reduceMotion) { value = new }
            }
            shownKey = key
        }
    }

    @ViewBuilder
    private func content(_ s: InRangeStreaks) -> some View {
        let now = Date()
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Button { open(s) } label: {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    DSAccessibleStack(verticalAlignment: .top, spacing: DS.Space.md) {
                        StatTile("Current", value: InRangeStreaksText.days(s.currentDays),
                                 caption: InRangeStreaksText.currentCaption(s, now: now),
                                 tone: s.currentDays > 0 ? .glucose(.inRange) : .neutral, boxed: true,
                                 rolling: .init(Double(s.currentDays), order: 0, text: InRangeStreaksText.figure))
                        StatTile("Longest", value: InRangeStreaksText.days(s.best.days),
                                 caption: InRangeStreaksText.bestCaption(s, now: now),
                                 tone: s.best.days > 0 ? .glucose(.inRange) : .neutral, boxed: true,
                                 rolling: .init(Double(s.best.days), order: 1, text: InRangeStreaksText.figure)) {
                            if openLogbook != nil && s.best.days > 0 {
                                HStack {
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    .monospacedDigit()
                    StreakDots(days: s.recent, best: s.best)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyStop("insights.streaks.open", kind: .control, radius: DS.Radius.tile) { open(s) }
            .disabled(openLogbook == nil || s.best.days == 0)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(InRangeStreaksText.title)
            .accessibilityValue(InRangeStreaksText.spoken(s, now: now) + " " + InRangeStreaksText.dotsLine(s))
            .accessibilityHint(openLogbook == nil || s.best.days == 0 ? "" : InRangeStreaksText.logbookHint)

            Text(InRangeStreaksText.line(s))
                .dsFont(.callout)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Text(InRangeStreaksText.dotsLine(s))
                .dsFont(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(InRangeStreaksText.footnote(rangeLine: rangeLine))
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The longest run's days, up to its last.
    private func open(_ s: InRangeStreaks) {
        guard let openLogbook, s.best.days > 0 else { return }
        openLogbook(.bestStreak(s.best, now: Date()))
    }
}

/// The last 14 days, oldest on the left: filled at 70% or more in range, a ring under it, a faint
/// dot without enough readings, and a dashed ring for today while it's under way. Days in the
/// longest run sit on a faint band, so it's clear which ones the Logbook opens on.
///
/// The dots fill in left to right with a short stagger the first time they show where
/// `figuresCountUp` is on. Under Reduce Motion, and everywhere else, they're simply there.
private struct StreakDots: View {
    let days: [InRangeStreaks.Day]
    let best: InRangeStreaks.Run

    @Environment(\.figuresCountUp) private var countsUp
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filled = false

    private var animates: Bool { countsUp && !reduceMotion }
    private let size: CGFloat = 12

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(days.enumerated()), id: \.element.id) { i, day in
                dot(day)
                    .scaleEffect(filled || !animates ? 1 : 0.3)
                    .opacity(filled || !animates ? 1 : 0)
                    .animation(animates ? DSMotion.arrival.animation.delay(0.15 + Double(i) * 0.035) : nil,
                               value: filled)
                    .frame(maxWidth: .infinity, minHeight: size + 8)
                    .background {
                        if best.days > 0 && best.interval.contains(day.start) && day.start < best.end {
                            Rectangle().fill(Tone.glucose(.inRange).color.opacity(0.12))
                        }
                    }
            }
        }
        .clipShape(Capsule())
        .accessibilityHidden(true)
        .onEntrance {
            guard !filled else { return }
            if animates {
                // Next frame, so the empty row is drawn before it fills.
                DispatchQueue.main.async { filled = true }
            } else {
                filled = true
            }
        }
    }

    @ViewBuilder
    private func dot(_ day: InRangeStreaks.Day) -> some View {
        let tint = Tone.glucose(.inRange).color
        switch day.mark {
        case .met:
            Circle().fill(tint).frame(width: size, height: size)
        case .missed:
            Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.5).frame(width: size, height: size)
        case .noData:
            Circle().fill(Color.secondary.opacity(0.2)).frame(width: size * 0.5, height: size * 0.5)
                .frame(width: size, height: size)
        case .underWay:
            Circle().strokeBorder(tint, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                .frame(width: size, height: size)
        }
    }
}

extension InRangeStreaksCardView {
    /// Nothing to show: no readings yet, or how many days so far (`InsightsEmptyState`,
    /// docs/EmptyStates.md). The card has no period to widen, so there's no button.
    fileprivate func emptyNote(_ key: InRangeStreaksCache.Key) -> some View {
        let readings = readings
        return InsightsEmptyNote(id: AnyHashable(key), waiting: InRangeStreaksText.emptyLine, decide: {
            InsightsEmptyState.readings(daysSoFar: InsightsEmptyState.readingDays(readings), needed: InRangeStreaks.minimumDays,
                                        waiting: InRangeStreaksText.emptyLine, currentDays: nil, longerWithData: nil)
        })
    }
}
