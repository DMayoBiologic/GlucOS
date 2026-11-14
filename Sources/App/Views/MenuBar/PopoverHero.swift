import SwiftUI

/// The current reading: range, value, trend and how fresh it is. Everything else in the popover
/// is secondary to this card.
///
/// A stale reading is drawn grey, crossed through, with "Trend unavailable" and an amber age,
/// so an old number can never pass for a live one.
struct PopoverHero: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var onCopy: () -> Void
    var onRefresh: () -> Void
    var onOpenDashboard: () -> Void

    /// The hero number follows the Text Size setting at half rate, so it stays inside the card.
    private let textScale = DSScaledValue()

    /// Bumped on each new reading to play a single soft ripple around the card.
    @State private var ripple = 0

    private var s: GlucoseSnapshot { store.snapshot }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PopoverLayout.heroRadius, style: .continuous)
    }

    var body: some View {
        let stale = s.isStale()
        let tone = s.displayTone()
        let tint = tone.color
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    statusRow(stale: stale)
                    if let cur = s.current {
                        valueRow(cur, stale: stale, tint: tint)
                        trendRow(cur, stale: stale)
                    }
                }
                Spacer(minLength: 4)
                if let cur = s.current {
                    TrendDial(trend: stale ? .unknown : cur.trend, tint: tint, size: 62)
                        .opacity(stale ? 0.6 : 1)
                        .accessibilityHidden(true)
                }
            }
            if let cur = s.current {
                RangeRail(mgdl: cur.mgdl, lowMgdl: s.lowMgdl, highMgdl: s.highMgdl, stale: stale,
                          forecastMgdl: stale || !settings.showForecast ? nil : s.currentOutlook().flatMap(OutlookFormat.headlineSample)?.sample.mgdl,
                          thickness: 5, unit: s.unit)
                FreshnessRow(reading: cur)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // One element for VoiceOver: the whole reading in a sentence, with the card's actions.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits([.isHeader, .updatesFrequently])
        .accessibilityAction(named: "Copy reading", onCopy)
        .accessibilityAction(named: "Refresh", onRefresh)
        .accessibilityAction(named: "Open Dashboard", onOpenDashboard)
        // Stale is `Tone.stale`: a grey surface, so an old reading never sits on a reassuring colour.
        .background {
            // The range field behind the reading. Still here (the popover is open for seconds), so
            // it only sweeps to a new colour when the range changes.
            ZStack {
                DSSurface(style: .hero(tone), radius: PopoverLayout.heroRadius)
                RangeField(tone: tone, intensity: 0.8, range: stale ? nil : s.range)
                    .clipShape(shape)
            }
        }
        .readingRipple(trigger: ripple, in: shape, tint: tint)
        .dsShadow(.medium, tint: stale ? nil : tint)
        .contentShape(shape)
        .contextMenu {
            Button("Copy Reading", systemImage: "doc.on.doc", action: onCopy)
                .disabled(s.current == nil)
            Button("Refresh Now", systemImage: "arrow.clockwise", action: onRefresh)
                .disabled(store.isRefreshing)
            Divider()
            Button("Open Dashboard", systemImage: "macwindow", action: onOpenDashboard)
        }
        .onChange(of: s.current?.timestamp) { old, new in
            guard old != nil, new != nil, old != new, !reduceMotion else { return }
            ripple += 1
        }
    }

    // MARK: Rows

    private func statusRow(stale: Bool) -> some View {
        HStack(spacing: 6) {
            if let range = s.range { RangeBadgeSwap(range: range, stale: stale) }
            if let streak = s.rangeStreak(), streak.duration >= 5 * 60 {
                Text("for \(streak.isOpenEnded ? "over " : "")\(PopoverFormat.streak(streak.duration))")
                    .dsFont(.label)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .help("Time since the reading last left this range")
            }
            if store.isRefreshing {
                ProgressView().controlSize(.mini)
                    .transition(.opacity)
            }
        }
        .frame(height: 22)
    }

    private func valueRow(_ cur: GlucoseReading, stale: Bool, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(s.unit.format(mgdl: cur.mgdl))
                .font(.system(size: (54 * (1 + (textScale.scale - 1) * 0.5)).rounded(), weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(stale ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(numberStyle(tint)))
                // A stale value is crossed through lightly, so it can't be read as current even in
                // a quick glance or a screenshot. The line draws across as the data goes stale.
                .staleStrike(stale)
                .contentTransition(.numericText(value: cur.mgdl))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(s.unit.label)
                .fontWeight(.semibold).dsFont(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func trendRow(_ cur: GlucoseReading, stale: Bool) -> some View {
        if stale {
            Label("Trend unavailable", systemImage: "questionmark.circle")
                .fontWeight(.semibold).dsFont(.callout)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                Text(cur.trend.description)
                    .fontWeight(.semibold).dsFont(.callout)
                if let d = s.deltaMgdl {
                    Text(s.unit.formatDelta(mgdl: d))
                        .fontWeight(.medium).dsFont(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: d))
                        .help("Change since the previous reading")
                }
            }
        }
    }

    private func numberStyle(_ tint: Color) -> LinearGradient {
        // In range reads as calm text; out of range takes the range colour.
        let base: Color = s.range == .inRange ? .primary : tint
        return LinearGradient(colors: [base, base.opacity(0.8)], startPoint: .top, endPoint: .bottom)
    }

    private var accessibilityLabel: String {
        var label = s.accessibilitySummary()
        if let streak = s.rangeStreak(), streak.duration >= 5 * 60 {
            label += ", \(streak.range.label) for \(streak.isOpenEnded ? "over " : "")\(PopoverFormat.spokenStreak(streak.duration))"
        }
        return label
    }
}

/// "Updated 32s ago · 3:41 pm" over a hairline meter that fills as the reading ages toward stale.
/// Ticks every second on its own, so the rest of the popover doesn't re-render with it.
private struct FreshnessRow: View {
    let reading: GlucoseReading

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let age = reading.age(at: context.date)
            let progress = min(1, max(0.02, age / GlucoseSnapshot.staleAfter))
            let stale = age > GlucoseSnapshot.staleAfter
            let nearlyStale = !stale && age > GlucoseSnapshot.staleAfter * 0.66
            let warning = Tone.warning
            let color: Color = stale || nearlyStale ? warning.textColor : .secondary
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    if stale {
                        Image(systemName: "exclamationmark.triangle.fill").imageScale(.small)
                    } else {
                        LiveDot(live: true, size: 6).padding(.trailing, 2)
                    }
                    Text(stale ? "Last reading \(PopoverFormat.ageAgo(age))" : "Updated \(PopoverFormat.ageAgo(age))")
                        .monospacedDigit()
                    Spacer(minLength: 4)
                    Text(reading.timestamp.formatted(date: .omitted, time: .shortened))
                        .foregroundStyle(.tertiary)
                }
                .dsFont(.label)
                .foregroundStyle(color)

                GeometryReader { geo in
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(stale ? warning.color : (nearlyStale ? warning.color.opacity(0.8) : Color.secondary.opacity(0.55)))
                                .frame(width: geo.size.width * progress)
                        }
                }
                .frame(height: 3)
                .help("Readings older than \(Int(GlucoseSnapshot.staleAfter / 60)) minutes are treated as stale")
            }
        }
    }
}
