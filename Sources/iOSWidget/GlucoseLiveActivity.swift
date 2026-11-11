import ActivityKit
import SwiftUI
import WidgetKit

// The Lock Screen card and Dynamic Island. Same rules as every other GlucOS surface: the reading
// takes its range's hue, a stale reading goes grey and says so, and the forecast is grey, dashed
// and marked "≈".

struct GlucoseLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GlucoseActivityAttributes.self) { context in
            LockScreenGlucoseCard(state: context.state, stale: context.isStale || context.state.isStale())
                .activityBackgroundTint(Color.black.opacity(0.25))
                .activitySystemActionForegroundColor(.primary)
                .widgetURL(URL(string: "glucos://open"))
        } dynamicIsland: { context in
            let state = context.state
            let stale = context.isStale || state.isStale()
            let tint = state.tone(stale: stale).color
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(state.valueText)
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(tint)
                            .strikethrough(stale, color: .secondary)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        Text(state.glucoseUnit.label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 4) {
                        TrendDial(trend: stale ? .unknown : state.glucoseTrend, tint: tint, size: 40)
                        if let delta = state.deltaText, !stale {
                            Text(delta).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(stale ? "No recent reading" : state.range.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(stale ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(state.range.textTint))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        ActivitySparkline(state: state, stale: stale)
                            .frame(height: 54)
                        ActivityFooter(state: state, stale: stale)
                    }
                }
            } compactLeading: {
                Text(state.valueText)
                    .font(.system(.body, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .strikethrough(stale, color: .secondary)
            } compactTrailing: {
                Image(systemName: stale ? "clock.badge.exclamationmark" : state.glucoseTrend.systemImage)
                    .font(.body.weight(.bold))
                    .foregroundStyle(tint)
            } minimal: {
                Text(state.valueText)
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .minimumScaleFactor(0.6)
            }
            .keylineTint(tint)
            .widgetURL(URL(string: "glucos://open"))
        }
    }
}

extension GlucoseActivityState {
    func tone(stale: Bool) -> Tone { stale ? .stale : .glucose(range) }
}

/// The Lock Screen card: the reading on the left, the last three hours and the forecast on the
/// right, and what's next along the bottom.
struct LockScreenGlucoseCard: View {
    let state: GlucoseActivityState
    let stale: Bool

    var body: some View {
        let tone = state.tone(stale: stale)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    TonePill(text: stale ? "Stale" : state.range.label,
                             systemImage: stale ? "exclamationmark.triangle.fill" : state.range.systemImage,
                             tone: tone)
                        .environment(\.dsTextScale, 1.1)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(state.valueText)
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(stale ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(tone.color))
                            .strikethrough(stale, color: .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        if !stale {
                            Image(systemName: state.glucoseTrend.systemImage)
                                .font(.system(size: 22, weight: .heavy))
                                .foregroundStyle(tone.color)
                        }
                    }
                    HStack(spacing: 4) {
                        Text(state.glucoseUnit.label)
                        if let delta = state.deltaText, !stale {
                            Text("· \(delta)").monospacedDigit()
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: true, vertical: false)
                ActivitySparkline(state: state, stale: stale)
                    .frame(maxWidth: .infinity)
                    .frame(height: 78)
            }
            ActivityFooter(state: state, stale: stale)
        }
        .padding(14)
        .background {
            LinearGradient(colors: [tone.color.opacity(0.30), tone.color.opacity(0.06)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stale
            ? "Glucose \(state.glucoseUnit.format(mgdl: state.mgdl, withUnit: true)), stale"
            : "Glucose \(state.glucoseUnit.format(mgdl: state.mgdl, withUnit: true)), \(state.range.label), \(state.glucoseTrend.description)")
    }
}

/// The last three hours, coloured by range, with the forecast dashed and grey.
struct ActivitySparkline: View {
    let state: GlucoseActivityState
    let stale: Bool

    private var forecast: [ForecastSample] {
        let points = state.forecastPoints
        guard !points.isEmpty else { return [] }
        let lowerEnd = Double(state.forecastLower ?? Int(points.last!.mgdl))
        let upperEnd = Double(state.forecastUpper ?? Int(points.last!.mgdl))
        let last = points.last!.mgdl
        return points.enumerated().map { i, p in
            // The likely range widens from nothing at the reading to its width at the end.
            let f = Double(i + 1) / Double(points.count)
            return ForecastSample(date: p.date, mgdl: p.mgdl,
                                  lowerMgdl: p.mgdl - (last - lowerEnd) * f, upperMgdl: p.mgdl + (upperEnd - last) * f)
        }
    }

    var body: some View {
        GlucoseChart(readings: state.historyReadings, unit: state.glucoseUnit, lowMgdl: state.lowMgdl,
                     highMgdl: state.highMgdl, hours: GlucoseActivityState.historyHours, showAxes: false,
                     latestIsStale: stale, forecast: stale ? [] : forecast)
    }
}

/// "≈ 6.2 in 30 min · 1.2 u · 2 min ago".
struct ActivityFooter: View {
    let state: GlucoseActivityState
    let stale: Bool

    var body: some View {
        HStack(spacing: 10) {
            if !stale, let f = state.forecastHeadline {
                Label {
                    Text("\(OutlookFormat.approx(f.mgdl, unit: state.glucoseUnit)) in \(f.minutes) min")
                } icon: {
                    Image(systemName: state.lowExpectedAt != nil ? "exclamationmark.triangle.fill" : "chart.line.uptrend.xyaxis")
                        .foregroundStyle(state.lowExpectedAt != nil ? Tone.warning.color : Palette.stale)
                }
                .lineLimit(1)
            }
            if !stale, let iob = state.insulinOnBoard, iob >= 0.05 {
                Label(OutlookFormat.units(iob), systemImage: "syringe")
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 3) {
                Image(systemName: stale ? "clock.badge.exclamationmark" : "clock")
                Text(state.readingDate, style: .relative)
                Text("ago")
            }
            .foregroundStyle(stale ? AnyShapeStyle(Tone.warning.color) : AnyShapeStyle(Color.secondary))
            .monospacedDigit()
            .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }
}
