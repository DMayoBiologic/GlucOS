import SwiftUI

/// The current reading: range, value, trend and how fresh it is. Everything else in the popover
/// is secondary to this card.
struct PopoverHero: View {
    @EnvironmentObject var store: GlucoseStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var onCopy: () -> Void
    var onRefresh: () -> Void
    var onOpenDashboard: () -> Void

    /// Bumped on each new reading to play a single soft ripple around the card.
    @State private var ripple = 0

    private var s: GlucoseSnapshot { store.snapshot }

    var body: some View {
        let stale = s.isStale()
        let tint = s.displayTint()
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                statusRow(stale: stale)
                if let cur = s.current {
                    valueRow(cur, stale: stale, tint: tint)
                    trendRow(cur, stale: stale)
                    FreshnessRow(reading: cur)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityAction(named: "Copy reading", onCopy)
            .accessibilityAction(named: "Refresh", onRefresh)
            .accessibilityAction(named: "Open Dashboard", onOpenDashboard)

            Spacer(minLength: 4)

            if let cur = s.current {
                TrendDial(trend: stale ? .unknown : cur.trend, tint: tint, size: 72)
                    .opacity(stale ? 0.55 : 1)
                    .accessibilityHidden(true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial)
                AmbientGlow(tint: tint, intensity: stale ? 0.5 : 1)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.1)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing),
                              lineWidth: 1)
        }
        .overlay {
            // New-reading ripple: one expanding, fading outline.
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(tint, lineWidth: 2)
                .keyframeAnimator(initialValue: Ripple(), trigger: ripple) { content, value in
                    content.scaleEffect(value.scale).opacity(value.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        LinearKeyframe(1, duration: 0.01)
                        CubicKeyframe(1.04, duration: 0.9)
                    }
                    KeyframeTrack(\.opacity) {
                        LinearKeyframe(0.7, duration: 0.01)
                        CubicKeyframe(0, duration: 0.9)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .shadow(color: tint.opacity(0.18), radius: 14, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
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

    private struct Ripple {
        var scale: CGFloat = 1
        var opacity: Double = 0
    }

    // MARK: Rows

    @ViewBuilder
    private func statusRow(stale: Bool) -> some View {
        HStack(spacing: 6) {
            if let range = s.range { RangeBadge(range: range, stale: stale) }
            if let streak = s.rangeStreak(), streak.duration >= 5 * 60 {
                Text("for \(streak.isOpenEnded ? "over " : "")\(PopoverFormat.streak(streak.duration))")
                    .font(.caption.weight(.medium))
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
    }

    private func valueRow(_ cur: GlucoseReading, stale: Bool, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(s.unit.format(mgdl: cur.mgdl))
                .font(.system(size: 60, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(stale ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(numberStyle(tint)))
                // A stale value is crossed through lightly, so it can't be read as current even in
                // a quick glance or a screenshot.
                .overlay(alignment: .center) {
                    if stale {
                        Capsule()
                            .fill(Color.secondary.opacity(0.7))
                            .frame(height: 3)
                            .rotationEffect(.degrees(-8))
                            .padding(.horizontal, -2)
                            .accessibilityHidden(true)
                    }
                }
                .contentTransition(.numericText(value: cur.mgdl))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(s.unit.label)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func trendRow(_ cur: GlucoseReading, stale: Bool) -> some View {
        if stale {
            Label("Trend unavailable", systemImage: "questionmark.circle")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                Text(cur.trend.description)
                    .font(.callout.weight(.semibold))
                if let d = s.deltaMgdl {
                    Text(s.unit.formatDelta(mgdl: d))
                        .font(.callout.weight(.medium))
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
        return LinearGradient(colors: [base, base.opacity(0.78)], startPoint: .top, endPoint: .bottom)
    }

    private var accessibilityLabel: String {
        var label = s.accessibilitySummary()
        if let streak = s.rangeStreak(), streak.duration >= 5 * 60 {
            label += ", \(streak.range.label) for \(streak.isOpenEnded ? "over " : "")\(PopoverFormat.spokenStreak(streak.duration))"
        }
        return label
    }
}

/// "Updated 32s ago · 3:41 pm" with a slim meter that fills as the reading ages toward stale.
/// Ticks every second on its own, so the rest of the popover doesn't re-render with it.
private struct FreshnessRow: View {
    let reading: GlucoseReading

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let age = reading.age(at: context.date)
            let stale = age > GlucoseSnapshot.staleAfter
            let nearlyStale = !stale && age > GlucoseSnapshot.staleAfter * 0.66
            let color: Color = stale ? .orange : (nearlyStale ? .orange.opacity(0.8) : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if stale { Image(systemName: "exclamationmark.triangle.fill") }
                    Text(stale ? "Last reading \(PopoverFormat.ageAgo(age))" : "Updated \(PopoverFormat.ageAgo(age))")
                        .monospacedDigit()
                    Text("·").foregroundStyle(.tertiary)
                    Text(reading.timestamp.formatted(date: .omitted, time: .shortened))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(color)

                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 120, height: 3)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(stale ? Color.orange : (nearlyStale ? Color.orange.opacity(0.8) : Color.secondary.opacity(0.6)))
                            .frame(width: 120 * min(1, max(0.03, age / GlucoseSnapshot.staleAfter)), height: 3)
                    }
                    .help("Readings older than \(Int(GlucoseSnapshot.staleAfter / 60)) minutes are treated as stale")
                    .accessibilityHidden(true)
            }
        }
    }
}
