#if os(iOS)
import SwiftUI
import WidgetKit

/// The small Glucose widget as StandBy shows it: iPhone charging on its side, the widget drawn
/// large across half the screen with no container background. A bedside view, readable from across
/// the room: the reading as big as it fits, the trend arrow beside it, a thin range band and one
/// line of words (`StandByGlance`).
///
/// At night StandBy renders in the vibrant mode and tints everything red. The night style keeps to
/// one ink, a lighter weight and lower brightness, so it stays dim in a dark room, and it never
/// relies on hue: freshness is in the words, the strike and the withdrawn arrow.
///
/// No flicker between timeline entries: every element keeps its place in every freshness state
/// (an empty slot is transparent, not removed), the figure rolls to the next value, the arrow
/// swings round to a new trend, and the caption's age is in whole minutes from the entry date
/// rather than a ticking timer.
struct StandByGlucoseView: View {
    let entry: GlucoseEntry
    /// VoiceOver's sentence for the reading, the same as the other sizes.
    let spoken: String

    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var s: GlucoseSnapshot { entry.snapshot }
    private var style: StandByGlance.Style { StandByGlance.style(vibrant: mode == .vibrant) }
    private var fresh: Bool { entry.freshness == .fresh }
    private var trend: Trend { s.current?.trend ?? .unknown }

    var body: some View {
        let primary = StandByGlance.primaryOpacity(style)
        let secondary = StandByGlance.secondaryOpacity(style)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                figure
                    .opacity(primary)
                Spacer(minLength: 0)
                arrow
                    .opacity(StandByGlance.showsTrend(s, at: entry.date) ? primary : 0)
            }
            .frame(maxHeight: .infinity)

            band
                .opacity(secondary)
                .padding(.bottom, 8)

            Text(StandByGlance.caption(s, at: entry.date))
                .font(.system(size: 15, weight: style == .night ? .medium : .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .opacity(secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .smooth(duration: 0.5), value: entry.freshness)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    // MARK: Figure

    private var valueStyle: AnyShapeStyle {
        guard fresh else { return AnyShapeStyle(HierarchicalShapeStyle.secondary) }
        if mode.isFullColor, let range = s.range { return AnyShapeStyle(range.valueColor) }
        return AnyShapeStyle(HierarchicalShapeStyle.primary)
    }

    private var figure: some View {
        Text(StandByGlance.value(s, at: entry.date))
            .font(.system(size: 76, weight: style == .night ? .semibold : .bold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.45)
            .foregroundStyle(valueStyle)
            .contentTransition(.numericText(value: s.current?.mgdl ?? 0))
            .staleStrike(entry.freshness == .stale, thickness: 4)
            .widgetAccentable()
            .invalidatableContent()
    }

    // MARK: Trend

    /// One arrow turned to the trend's angle, so a new trend swings it round (a cross-fade under
    /// Reduce Motion). It stays in the layout when hidden so the figure never shifts.
    private var arrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 34, weight: style == .night ? .bold : .heavy))
            .foregroundStyle(fresh && mode.isFullColor ? AnyShapeStyle(entry.tint) : AnyShapeStyle(HierarchicalShapeStyle.primary))
            .rotationEffect(.degrees(trend.needleAngle))
            .id(reduceMotion ? AnyHashable(trend) : AnyHashable(0))
            .transition(.opacity)
            .animation(reduceMotion ? .easeInOut(duration: TrendTurn.crossFadeDuration)
                                    : .spring(response: TrendTurn.response, dampingFraction: TrendTurn.dampingFraction),
                       value: trend)
            .frame(width: 40, height: 40)
            .widgetAccentable()
            .accessibilityHidden(true)
    }

    // MARK: Band

    /// Where the reading sits from urgent low to very high. Grey while stale; an empty track once
    /// the value is withdrawn, so the space doesn't collapse.
    @ViewBuilder private var band: some View {
        ZStack {
            if let cur = s.current, StandByGlance.showsBand(s, at: entry.date) {
                RangeRail(mgdl: cur.mgdl, lowMgdl: s.lowMgdl, highMgdl: s.highMgdl, stale: !fresh,
                          thickness: 5, monochrome: !mode.isFullColor, unit: s.unit)
            } else {
                Capsule()
                    .fill(Color.primary.opacity(0.15))
                    .frame(height: 5)
            }
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }
}

#endif
