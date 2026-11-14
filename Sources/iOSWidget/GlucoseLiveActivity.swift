import ActivityKit
import SwiftUI
import WidgetKit

// The Live Activity: GlucOS's most important surface (docs/Redesign.md §6). Lock Screen and banner,
// StandBy, the Dynamic Island's compact, minimal and expanded views, and the small family that the
// Apple Watch Smart Stack and CarPlay show. Same rules as every other GlucOS surface: the reading
// takes its range's hue, a stale reading goes grey, is crossed through and says so, and the
// forecast is grey, dashed and marked "≈".
//
// Motion here is what ActivityKit allows: between two states the system animates for up to two
// seconds, so the value rolls, the trend needle springs to its new angle and the range rail's
// marker glides. Between updates only the system's live views move: the freshness meter filling and
// the reading's age ticking. Under Reduce Motion both the system and `dsAnimation` keep it still.

struct GlucoseLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GlucoseActivityAttributes.self) { context in
            ActivityPresentation(context: context)
                .activityBackgroundTint(ActivityLook.backgroundTint(context.state, stale: context.isStaleCard))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "glucos://open"))
        } dynamicIsland: { context in
            let state = context.state
            let stale = context.isStaleCard
            let tint = state.tone(stale: stale).color
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandValue(state: state, stale: stale)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 4) {
                        TrendDial(trend: stale ? .unknown : state.glucoseTrend, tint: tint, size: 44)
                        if let delta = state.deltaText, !stale {
                            Text(delta)
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .contentTransition(.numericText(value: state.deltaMgdl ?? 0))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    ActivityStatusLabel(state: state, stale: stale, person: context.person)
                        .font(.caption.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        ActivitySparkline(state: state, stale: stale)
                            .frame(height: 52)
                        RangeRail(mgdl: state.mgdl, lowMgdl: state.lowMgdl, highMgdl: state.highMgdl, stale: stale,
                                  forecastMgdl: stale ? nil : state.forecastHeadline?.mgdl, thickness: 3,
                                  unit: state.glucoseUnit)
                        HStack(spacing: 8) {
                            ActivityFooter(state: state, stale: stale, compact: true)
                            if context.isOwner { LogLink() }
                        }
                    }
                }
            } compactLeading: {
                Text(state.valueText)
                    .font(.system(.body, design: .rounded).weight(.heavy))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: state.mgdl))
                    .foregroundStyle(tint)
                    .strikethrough(stale, color: .secondary)
                    .accessibilityLabel(state.accessibilitySummary(stale: stale, person: context.person))
            } compactTrailing: {
                HStack(spacing: 2) {
                    Image(systemName: stale ? "clock.badge.exclamationmark" : state.glucoseTrend.systemImage)
                        .font(.body.weight(.bold))
                        .contentTransition(.symbolEffect(.replace))
                    if !stale, let delta = state.deltaText {
                        Text(delta)
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            } minimal: {
                Text(state.valueText)
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: state.mgdl))
                    .foregroundStyle(tint)
                    .strikethrough(stale, color: .secondary)
                    .minimumScaleFactor(0.6)
                    .accessibilityLabel(state.accessibilitySummary(stale: stale, person: context.person))
            }
            .keylineTint(tint)
            .widgetURL(URL(string: "glucos://open"))
        }
        // The Apple Watch Smart Stack and CarPlay get their own small layout rather than the
        // island's compact views.
        .supplementalActivityFamilies([.small])
    }
}

// MARK: - Context helpers

extension ActivityViewContext where Attributes == GlucoseActivityAttributes {
    /// Stale by ActivityKit's stale date or by the reading's own age, whichever comes first.
    var isStaleCard: Bool { isStale || state.isStale() }
    /// The owner's own card (logging is only for your own readings).
    var isOwner: Bool { attributes.followID == nil }
    /// Whose reading, on a card following someone else's share.
    var person: String? { attributes.followID == nil ? nil : attributes.name }
}

extension GlucoseActivityState {
    func tone(stale: Bool) -> Tone { stale ? .stale : .glucose(range) }

    /// The whole card in one sentence, for VoiceOver.
    func accessibilitySummary(stale: Bool, person: String?) -> String {
        let who = person.map { "\($0), " } ?? ""
        let value = glucoseUnit.format(mgdl: mgdl)
        if stale {
            return who + "Glucose reading is out of date. Last reading \(value) \(glucoseUnit.spokenLabel)."
        }
        var parts = ["Glucose \(value) \(glucoseUnit.spokenLabel)", range.label]
        if glucoseTrend != .unknown { parts.append(glucoseTrend.description) }
        if let deltaText { parts.append("change \(deltaText.replacingOccurrences(of: "−", with: "minus "))") }
        var s = who + parts.joined(separator: ", ") + "."
        if let low = lowExpectedDate {
            s += " Low expected in about \(ForecastNote.roundedMinutes(low.timeIntervalSince(readingDate))) minutes."
        } else if let f = forecastHeadline {
            s += " Forecast about \(glucoseUnit.format(mgdl: f.mgdl)) in \(f.minutes) minutes."
        }
        return s
    }
}

/// Colours behind the card. The Lock Screen card is always drawn dark (on a dark, range-tinted
/// backdrop), so it reads the same on a light or dark wallpaper and in StandBy.
enum ActivityLook {
    static func backgroundTint(_ state: GlucoseActivityState, stale: Bool) -> Color {
        if stale { return Color(white: 0.16).opacity(0.9) }
        switch state.range {
        case .inRange: return Color(red: 0.05, green: 0.08, blue: 0.08).opacity(0.88)
        case .urgentLow: return Palette.crimson.mix(with: .black, by: 0.45).opacity(0.92)
        case .low, .high, .veryHigh: return state.range.tint.mix(with: .black, by: 0.6).opacity(0.9)
        }
    }
}

// MARK: - Presentations

/// The Lock Screen / banner / StandBy card, or the small Watch and CarPlay layout.
private struct ActivityPresentation: View {
    let context: ActivityViewContext<GlucoseActivityAttributes>
    @Environment(\.activityFamily) private var family

    var body: some View {
        switch family {
        case .small:
            SmallGlucoseCard(state: context.state, stale: context.isStaleCard, person: context.person)
        default:
            LockScreenGlucoseCard(state: context.state, stale: context.isStaleCard, person: context.person,
                                  showsLog: context.isOwner)
        }
    }
}

/// The Lock Screen card (docs/Redesign.md §6.2): status and freshness along the top, the value and
/// needle beside the last three hours, the range rail, and the forecast with one action along the
/// bottom. Fits Apple's 160 pt limit.
struct LockScreenGlucoseCard: View {
    let state: GlucoseActivityState
    let stale: Bool
    /// Whose reading, on a card following someone else's share. nil on the owner's own card.
    var person: String? = nil
    var showsLog: Bool = true

    var body: some View {
        let tone = state.tone(stale: stale)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                ActivityStatusLabel(state: state, stale: stale, person: person)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                ReadingAge(readingDate: state.readingDate, stale: stale)
                    .font(.caption.weight(.medium))
                FreshnessMeter(readingDate: state.readingDate, stale: stale, tint: .white.opacity(0.7), width: 34)
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 8) {
                        ActivityValueText(state: state, stale: stale, size: 48)
                        TrendDial(trend: stale ? .unknown : state.glucoseTrend, tint: tone.color, size: 34)
                            .opacity(stale ? 0.6 : 1)
                    }
                    HStack(spacing: 4) {
                        Text(state.glucoseUnit.label)
                        if let delta = state.deltaText, !stale {
                            Text("· \(delta)")
                                .monospacedDigit()
                                .contentTransition(.numericText(value: state.deltaMgdl ?? 0))
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: true, vertical: false)
                ActivitySparkline(state: state, stale: stale)
                    .frame(maxWidth: .infinity)
                    .frame(height: 62)
            }
            RangeRail(mgdl: state.mgdl, lowMgdl: state.lowMgdl, highMgdl: state.highMgdl, stale: stale,
                      forecastMgdl: stale ? nil : state.forecastHeadline?.mgdl, thickness: 3, unit: state.glucoseUnit)
            HStack(spacing: 8) {
                ActivityFooter(state: state, stale: stale, compact: false)
                if showsLog { LogLink() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            // The card's own colour, so StandBy (which drops the background tint) still has it.
            RangeField(tone: tone, intensity: stale ? 0.6 : 0.9)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilitySummary(stale: stale, person: person))
    }
}

/// The Apple Watch Smart Stack and CarPlay layout: value, arrow and delta, the rail, and status
/// with age. Dims on the watch's Always On display.
struct SmallGlucoseCard: View {
    let state: GlucoseActivityState
    let stale: Bool
    var person: String? = nil
    @Environment(\.isLuminanceReduced) private var luminanceReduced

    var body: some View {
        let tone = state.tone(stale: stale)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                ActivityValueText(state: state, stale: stale, size: 30)
                if !stale {
                    Image(systemName: state.glucoseTrend.systemImage)
                        .font(.system(size: 18, weight: .heavy))
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(tone.color)
                }
                Spacer(minLength: 2)
                if let delta = state.deltaText, !stale {
                    Text(delta)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            RangeRail(mgdl: state.mgdl, lowMgdl: state.lowMgdl, highMgdl: state.highMgdl, stale: stale,
                      thickness: 3, unit: state.glucoseUnit)
                .opacity(luminanceReduced ? 0.5 : 1)
            HStack(spacing: 4) {
                ActivityStatusLabel(state: state, stale: stale, person: person)
                Spacer(minLength: 2)
                ReadingAge(readingDate: state.readingDate, stale: stale, timerWidth: 34)
            }
            .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilitySummary(stale: stale, person: person))
    }
}

// MARK: - Pieces

/// The big number: range hue (calm primary in range), grey and crossed through when stale.
private struct ActivityValueText: View {
    let state: GlucoseActivityState
    let stale: Bool
    let size: CGFloat

    var body: some View {
        let tone = state.tone(stale: stale)
        Text(state.valueText)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText(value: state.mgdl))
            .foregroundStyle(stale ? AnyShapeStyle(Color.secondary)
                             : state.range == .inRange ? AnyShapeStyle(Color.primary) : AnyShapeStyle(tone.color))
            .overlay {
                if stale {
                    Capsule().fill(Color.secondary.opacity(0.8)).frame(height: max(2, size / 18)).rotationEffect(.degrees(-8))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

/// The Dynamic Island's expanded value with its unit.
private struct IslandValue: View {
    let state: GlucoseActivityState
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(state.valueText)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: state.mgdl))
                .foregroundStyle(state.tone(stale: stale).color)
                .strikethrough(stale, color: .secondary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(state.glucoseUnit.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

/// "In range", "Low", "No recent reading", with the person on a follower's card. The range word
/// pushes in from the direction of travel when it changes.
private struct ActivityStatusLabel: View {
    let state: GlucoseActivityState
    let stale: Bool
    let person: String?

    var body: some View {
        let tone = state.tone(stale: stale)
        HStack(spacing: 4) {
            if let person {
                Label(person, systemImage: "person.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("·").foregroundStyle(.tertiary)
            }
            Label(stale ? "No recent reading" : state.range.label,
                  systemImage: stale ? "exclamationmark.triangle.fill" : state.range.systemImage)
                .foregroundStyle(stale ? AnyShapeStyle(Tone.warning.color) : AnyShapeStyle(tone.color))
                .lineLimit(1)
                .id(stale ? "stale" : state.range.label)
                .transition(.push(from: state.glucoseTrend.isFalling ? .top : .bottom))
        }
    }
}

/// The last three hours, coloured by range, with the forecast dashed and grey.
struct ActivitySparkline: View {
    let state: GlucoseActivityState
    let stale: Bool

    private var forecast: [ForecastSample] {
        let points = state.forecastPoints
        guard let lastPoint = points.last else { return [] }
        let last = lastPoint.mgdl
        let lowerEnd = Double(state.forecastLower ?? Int(last))
        let upperEnd = Double(state.forecastUpper ?? Int(last))
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

/// The forecast note and insulin on board, or what to do when the reading is old.
struct ActivityFooter: View {
    let state: GlucoseActivityState
    let stale: Bool
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            if stale {
                Label("Check your sensor app", systemImage: "sensor.tag.radiowaves.forward")
                    .lineLimit(1)
            } else {
                ForecastNote(unit: state.glucoseUnit, headline: state.forecastHeadline,
                             lowExpectedAt: state.lowExpectedDate, readingDate: state.readingDate, compact: compact)
                if let iob = state.insulinOnBoard, iob >= 0.05 {
                    Label(OutlookFormat.units(iob), systemImage: "syringe")
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }
}

/// The one action: log insulin, food or an event (owner's card only).
private struct LogLink: View {
    var body: some View {
        Link(destination: URL(string: "glucos://log")!) {
            Label("Log", systemImage: "plus")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.16), in: Capsule())
        }
        .accessibilityLabel("Log insulin, food or an event")
    }
}
