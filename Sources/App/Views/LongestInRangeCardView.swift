import SwiftUI

/// The Insights "Longest in range" card on the Mac and iPhone: the longest unbroken stretch in
/// range over the last 7, 14 or 30 days, how long it lasted and when (`LongestInRange`,
/// docs/LongestInRange.md). The screen leaves it out while under half the period has readings
/// (`LongestInRangeCache.shows`).
///
/// Motion: the figures count up where `figuresCountUp` is on and roll to new values when the period
/// changes; the timeline's stretch grows from its start as the card rises in (`onEntrance`) and
/// glides to a new place when the period changes. Nothing loops. Under Reduce Motion the stretch
/// fades in and new values cross-fade. The card is one VoiceOver stop that says it all in words.
///
/// With `openLogbook`, tapping the card (or its "See this stretch in the Logbook" row) opens the
/// Logbook over the stretch itself (`LogbookFilter.inRangeStretch`). The iPhone zooms the card into
/// it; the Mac cross-fades.
struct LongestInRangeCardView: View {
    let readings: [GlucoseReading]
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    var openLogbook: ((LogbookLink) -> Void)? = nil

    /// Insights stepped back to an earlier period (docs/InsightsPeriodStep.md).
    @Environment(\.insightsStep) private var step
    @AppStorage(InsightsShare.Key.longestInRange) private var periodDays = LongestInRange.Period.fortnight.rawValue
    @State private var value: LongestInRange?
    @State private var shownKey: LongestInRangeCache.Key?
    /// The timeline's stretch has grown in (once per appearance).
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.insightsShareSnapshot) private var shareSnapshot

    private var period: LongestInRange.Period { LongestInRange.Period(rawValue: periodDays) ?? .fortnight }
    /// "3.9–10.0 mmol/L".
    private var rangeLine: String { "\(unit.format(mgdl: lowMgdl))–\(unit.format(mgdl: highMgdl)) \(unit.label)" }

    var body: some View {
        let key = LongestInRangeCache.key(readings: readings, low: lowMgdl, high: highMgdl,
                                          period: period, back: step.back)
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Eyebrow(title: LongestInRangeText.title, systemImage: LongestInRangeText.systemImage)
            // A shared picture names the period in its footer instead (docs/InsightsShare.md).
            if !shareSnapshot {
                Picker("Period", selection: $periodDays) {
                    ForEach(LongestInRange.Period.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .keyStop("insights.longestInRange.period", radius: DS.Radius.control)
                .keyCycle($periodDays, through: LongestInRange.Period.allCases.map(\.rawValue))
                .accessibilityLabel("Period")
            }
            InsightsStepCaption(days: period.days, latest: readings.last?.timestamp)

            // While another period is worked out the last one stays up, so its figures roll.
            if let value {
                content(value)
            } else if shownKey == key {
                Text("Your longest time in range shows here once half of \(period.spoken) has readings.")
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Working it out: hold the space without a spinner.
                Color.clear.frame(height: 120)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: key) {
            let new: LongestInRange?
            if let hit = LongestInRangeCache.shared.cached(key) {
                new = hit
            } else {
                new = await LongestInRangeCache.shared.value(for: key, readings: readings)
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
    private func content(_ r: LongestInRange) -> some View {
        let now = Date()
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(LongestInRangeText.headline(r))
                .dsFont(.headline)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            DSAccessibleStack(verticalAlignment: .top, spacing: DS.Space.md) {
                StatTile("Longest", value: LongestInRangeText.length(r.longest),
                         tone: .glucose(.inRange),
                         rolling: .init(r.longest.minutes) { LowsSummaryText.duration($0) })
                StatTile("4 h or more", value: LongestInRangeText.longCountValue(r.longCount),
                         caption: r.longCount == 1 ? "stretch" : "stretches",
                         rolling: .init(Double(r.longCount), order: 1) { LongestInRangeText.longCountValue(Int($0.rounded())) })
            }
            .monospacedDigit()
            StretchTimeline(stretch: r.longest, end: r.end, days: r.period.days,
                            grown: grown || shareSnapshot, reduceMotion: reduceMotion)
            Text(LongestInRangeText.whenLine(r, now: now))
                .dsFont(.callout)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Text(LongestInRangeText.footnote(r, rangeLine: rangeLine))
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onEntrance {
            guard !grown else { return }
            // A frame later, so the timeline is laid out empty first.
            DispatchQueue.main.async { grown = true }
        }
        // One stop for VoiceOver: the stretch in a few sentences.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LongestInRangeText.title)
        .accessibilityValue(LongestInRangeText.spoken(r, rangeLine: rangeLine, now: now))
        .accessibilityHint(openLogbook == nil ? "" : LongestInRangeText.logbookHint)
        .accessibilityAddTraits(openLogbook == nil ? [] : .isButton)
        .accessibilityAction { open(r) }
        .contentShape(Rectangle())
        .onTapGesture { open(r) }
        if openLogbook != nil {
            Button { open(r) } label: {
                HStack(spacing: DS.Space.xs) {
                    Text(LongestInRangeText.logbookLine)
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
            .keyStop("insights.longestInRange.open", kind: .control, radius: DS.Radius.control) { open(r) }
            // The card's own stop already opens it; this row would say the same again.
            .accessibilityHidden(true)
        }
    }

    private func open(_ r: LongestInRange) {
        guard let openLogbook else { return }
        openLogbook(LongestInRange.link(r.longest, now: Date()))
    }
}

/// The period as a thin track, oldest on the left, with the stretch drawn where it fell. It grows
/// from its start once the card is in view; under Reduce Motion it fades in. A new period glides it.
private struct StretchTimeline: View {
    let stretch: LongestInRange.Stretch
    let end: Date
    let days: Int
    let grown: Bool
    let reduceMotion: Bool

    var body: some View {
        let span = Double(days) * 86_400
        let start = end.addingTimeInterval(-span)
        let from = max(0, min(1, stretch.start.timeIntervalSince(start) / span))
        let to = max(from, min(1, stretch.end.timeIntervalSince(start) / span))
        GeometryReader { geo in
            let w = geo.size.width
            // A short stretch on a 30-day track still shows.
            let width = max(4, (to - from) * w)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06))
                Capsule()
                    .fill(GlucoseRange.inRange.tint)
                    .frame(width: reduceMotion || grown ? width : 0)
                    .opacity(reduceMotion && !grown ? 0 : 1)
                    .offset(x: min(from * w, w - width))
            }
            // Under Reduce Motion the stretch only fades in: a colour fade, not a movement.
            .animation(reduceMotion ? .easeInOut(duration: 0.25) : DSMotion.emphasized.animation, value: grown)
            .animation(DSMotion.standard.animation(reduceMotion: reduceMotion), value: from)
            .animation(DSMotion.standard.animation(reduceMotion: reduceMotion), value: to)
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
