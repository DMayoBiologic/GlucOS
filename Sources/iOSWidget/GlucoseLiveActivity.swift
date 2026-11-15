import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// The Live Activity: GlucOS's most important surface (docs/Redesign.md §6). Lock Screen and banner,
// StandBy, the Dynamic Island's compact, minimal and expanded views, and the small family that the
// Apple Watch Smart Stack and CarPlay show. Same rules as every other GlucOS surface: the reading
// takes its range's hue, a stale reading goes grey, is crossed through and says so, and the
// forecast is grey, dashed and marked "≈".
//
// Motion here is what ActivityKit allows: between two states the system animates for up to two
// seconds, so every figure counts over to the new reading and cross-fades to its range colour
// (`readingChange`), the trend needle and the small arrows swing round to the new direction
// (`TrendDial`, `TrendArrow`) and the range rail's marker glides. Each is one animation on a
// changed value, under a second, never a loop. Between updates only the system's live views move:
// the freshness meter filling and the reading's age ticking. Under Reduce Motion nothing moves:
// figures fade in place and arrows turn at once.

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
            let tone = state.tone(stale: stale)
            let tint = tone.color
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
                                .dsAnimation(.arrival, value: state.deltaMgdl)
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
                        ActivityActionRow(state: state, stale: stale, followID: context.attributes.followID,
                                          person: context.person, compact: true)
                    }
                }
            } compactLeading: {
                Text(state.valueText)
                    .font(.system(.body, design: .rounded).weight(.heavy))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .readingChange(mgdl: state.mgdl, tone: tone)
                    .strikethrough(stale, color: .secondary)
                    .accessibilityLabel(state.accessibilitySummary(stale: stale, person: context.person))
            } compactTrailing: {
                HStack(spacing: 2) {
                    TrendArrow(trend: state.glucoseTrend, stale: stale)
                        .font(.body.weight(.bold))
                    if !stale, let delta = state.deltaText {
                        Text(delta)
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: state.deltaMgdl ?? 0))
                            .dsAnimation(.arrival, value: state.deltaMgdl)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(tint)
                .dsAnimation(.sweep, value: tone)
                .accessibilityHidden(true)
            } minimal: {
                Text(state.valueText)
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .readingChange(mgdl: state.mgdl, tone: tone)
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
            SmallGlucoseCard(state: context.state, stale: context.isStaleCard, person: context.person,
                             followID: context.attributes.followID)
        default:
            LockScreenGlucoseCard(state: context.state, stale: context.isStaleCard, person: context.person,
                                  followID: context.attributes.followID)
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
    /// The share, on a follower's card (for its Check in button). nil on the owner's own card.
    var followID: String? = nil

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
                                .dsAnimation(.arrival, value: state.deltaMgdl)
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
            ActivityActionRow(state: state, stale: stale, followID: followID, person: person, compact: false)
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
/// with age. Dims on the watch's Always On display. While there's a check-in to make or answer, the
/// rail gives way to the check-in row (docs/Sharing.md "Check-ins"): the buttons run on the iPhone,
/// so a tap on the watch or in the car does the same as on the Lock Screen.
struct SmallGlucoseCard: View {
    let state: GlucoseActivityState
    let stale: Bool
    var person: String? = nil
    /// The share, on a follower's card. nil on the owner's own card.
    var followID: String? = nil
    @Environment(\.isLuminanceReduced) private var luminanceReduced

    var body: some View {
        let actions = SmallCheckInRow.shows(state: state, followID: followID)
        VStack(alignment: .leading, spacing: actions ? 3 : 4) {
            reading(actions: actions)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(state.accessibilitySummary(stale: stale, person: person))
            if actions {
                SmallCheckInRow(state: state, stale: stale, followID: followID, person: person)
                    .opacity(luminanceReduced ? 0.6 : 1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, actions ? 6 : 8)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func reading(actions: Bool) -> some View {
        let tone = state.tone(stale: stale)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                ActivityValueText(state: state, stale: stale, size: actions ? 24 : 30)
                if !stale {
                    TrendArrow(trend: state.glucoseTrend)
                        .font(.system(size: actions ? 15 : 18, weight: .heavy))
                        .foregroundStyle(tone.color)
                        .dsAnimation(.sweep, value: tone)
                }
                Spacer(minLength: 2)
                if actions {
                    // The status row makes way for the buttons, so its age moves up here.
                    ReadingAge(readingDate: state.readingDate, stale: stale, timerWidth: 34)
                        .font(.caption2.weight(.semibold))
                } else if let delta = state.deltaText, !stale {
                    Text(delta)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: state.deltaMgdl ?? 0))
                        .dsAnimation(.arrival, value: state.deltaMgdl)
                        .foregroundStyle(.secondary)
                }
            }
            if !actions {
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
        }
    }
}

/// The check-in on the small card: a short note over the buttons, sized for a watch face. The owner
/// gets "I'm okay" and "Help" while someone's waiting; a follower gets Check in while the person they
/// follow is low or heading low, and Ask again when there's been no answer.
private struct SmallCheckInRow: View {
    let state: GlucoseActivityState
    let stale: Bool
    let followID: String?
    let person: String?

    /// Whether the small card has a check-in row at all.
    static func shows(state: GlucoseActivityState, followID: String?) -> Bool {
        if followID == nil { return state.checkIn?.isWaiting == true }
        return state.checkIn != nil || state.offersCheckIn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let followID {
                follower(followID)
            } else if let checkIn = state.checkIn {
                CheckInNote(text: "\(checkIn.askers) checking in", systemImage: "hand.wave.fill",
                            tint: Tone.warning.color, small: true)
                HStack(spacing: 4) {
                    CheckInButton(title: "I'm okay", systemImage: "checkmark", tint: Tone.success.color,
                                  intent: AnswerCheckInIntent(okay: true),
                                  accessibility: "Tell \(checkIn.askers) you're okay", fill: true)
                    CheckInButton(title: "Help", systemImage: nil, tint: Tone.critical.color,
                                  intent: AnswerCheckInIntent(okay: false),
                                  accessibility: "Tell \(checkIn.askers) you need help", fill: true)
                }
            }
        }
    }

    @ViewBuilder
    private func follower(_ followID: String) -> some View {
        let name = person ?? "them"
        let checkIn = state.checkIn
        switch checkIn?.status {
        case .asked?:
            CheckInNote(text: "Checked in \(ActivityActionRow.time(checkIn!.askedDate)) · waiting",
                        systemImage: "hand.wave.fill", tint: .secondary, small: true)
        case .noAnswer?:
            CheckInNote(text: "No answer since \(ActivityActionRow.time(checkIn!.askedDate))",
                        systemImage: "exclamationmark.triangle.fill", tint: Tone.warning.color, small: true)
            CheckInButton(title: "Ask again", systemImage: "hand.wave.fill", tint: Tone.warning.color,
                          intent: CheckInIntent(followID: followID), accessibility: "Ask \(name) again if they're okay",
                          fill: true)
        case .okay?:
            CheckInNote(text: "\(name) is okay · \(ActivityActionRow.time(checkIn!.answeredDate ?? checkIn!.askedDate))",
                        systemImage: "checkmark.circle.fill", tint: Tone.success.color, small: true)
            if state.offersCheckIn { checkInButton(followID, name: name) }
        case .help?:
            CheckInNote(text: "\(name) needs help · \(ActivityActionRow.time(checkIn!.answeredDate ?? checkIn!.askedDate))",
                        systemImage: "exclamationmark.triangle.fill", tint: Tone.critical.color, small: true)
        case nil:
            ActivityStatusLabel(state: state, stale: stale, person: person)
                .font(.caption2.weight(.semibold))
            checkInButton(followID, name: name)
        }
    }

    private func checkInButton(_ followID: String, name: String) -> some View {
        CheckInButton(title: "Check in", systemImage: "hand.wave.fill", tint: .white,
                      intent: CheckInIntent(followID: followID), accessibility: "Ask \(name) if they're okay", fill: true)
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
            .foregroundStyle(stale ? AnyShapeStyle(Color.secondary)
                             : state.range == .inRange ? AnyShapeStyle(Color.primary) : AnyShapeStyle(tone.color))
            .readingChange(mgdl: state.mgdl, tone: tone)
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
                .foregroundStyle(state.tone(stale: stale).color)
                .readingChange(mgdl: state.mgdl, tone: state.tone(stale: stale))
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
        // The push needs an animation on the change; under Reduce Motion the word swaps at once.
        .dsAnimation(.emphasized, value: stale ? "stale" : state.range.label)
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

// MARK: - Check-ins

/// The bottom row: the forecast and Log on the owner's card, or the check-in (docs/Sharing.md
/// "Check-ins"). A follower gets Check in while the person they follow is low or heading low; the
/// owner gets "I'm okay" and "Help" while someone's waiting. The buttons run in the app
/// (Sources/iOSIntents), so neither has to unlock the phone.
struct ActivityActionRow: View {
    let state: GlucoseActivityState
    let stale: Bool
    /// nil on the owner's own card.
    let followID: String?
    let person: String?
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            if let followID {
                followerRow(followID)
            } else if let checkIn = state.checkIn, checkIn.isWaiting {
                CheckInNote(text: "\(checkIn.askers) \((checkIn.count ?? 1) > 1 ? "are" : "is") checking in",
                            systemImage: "hand.wave.fill", tint: Tone.warning.color)
                Spacer(minLength: 4)
                CheckInButton(title: "I'm okay", systemImage: "checkmark", tint: Tone.success.color,
                              intent: AnswerCheckInIntent(okay: true),
                              accessibility: "Tell \(checkIn.askers) you're okay")
                CheckInButton(title: "Help", systemImage: nil, tint: Tone.critical.color,
                              intent: AnswerCheckInIntent(okay: false),
                              accessibility: "Tell \(checkIn.askers) you need help")
            } else {
                ActivityFooter(state: state, stale: stale, compact: compact)
                LogLink()
            }
        }
    }

    @ViewBuilder
    private func followerRow(_ followID: String) -> some View {
        let name = person ?? "them"
        switch state.checkIn?.status {
        case .asked?:
            CheckInNote(text: "Checked in \(Self.time(state.checkIn!.askedDate)) · waiting", systemImage: "hand.wave.fill",
                        tint: .secondary)
            Spacer(minLength: 4)
        case .noAnswer?:
            CheckInNote(text: "No answer since \(Self.time(state.checkIn!.askedDate))",
                        systemImage: "exclamationmark.triangle.fill", tint: Tone.warning.color)
            Spacer(minLength: 4)
            CheckInButton(title: "Ask again", systemImage: "hand.wave.fill", tint: Tone.warning.color,
                          intent: CheckInIntent(followID: followID), accessibility: "Ask \(name) again if they're okay")
        case .okay?:
            CheckInNote(text: "\(name) is okay · \(Self.time(state.checkIn!.answeredDate ?? state.checkIn!.askedDate))",
                        systemImage: "checkmark.circle.fill", tint: Tone.success.color)
            Spacer(minLength: 4)
            if state.offersCheckIn { checkInButton(followID, name: name) }
        case .help?:
            CheckInNote(text: "\(name) needs help · \(Self.time(state.checkIn!.answeredDate ?? state.checkIn!.askedDate))",
                        systemImage: "exclamationmark.triangle.fill", tint: Tone.critical.color)
            Spacer(minLength: 4)
        case nil:
            ActivityFooter(state: state, stale: stale, compact: compact)
            if state.offersCheckIn { checkInButton(followID, name: name) }
        }
    }

    private func checkInButton(_ followID: String, name: String) -> some View {
        CheckInButton(title: "Check in", systemImage: "hand.wave.fill", tint: .white,
                      intent: CheckInIntent(followID: followID), accessibility: "Ask \(name) if they're okay")
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }
}

/// The check-in, where the forecast note usually goes.
private struct CheckInNote: View {
    let text: String
    let systemImage: String
    let tint: Color
    /// The Watch and CarPlay size.
    var small: Bool = false

    var body: some View {
        Label(text, systemImage: systemImage)
            .font((small ? Font.caption2 : Font.caption).weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// A capsule button that runs a check-in intent in the app.
private struct CheckInButton<I: AppIntent>: View {
    let title: String
    let systemImage: String?
    let tint: Color
    let intent: I
    let accessibility: String
    /// Takes the row's width (the small Watch and CarPlay card, where it needs to be easy to hit).
    var fill: Bool = false

    var body: some View {
        Button(intent: intent) {
            Group {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .font(.caption.weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, fill ? 6 : 10)
            .padding(.vertical, fill ? 5 : 4)
            .frame(maxWidth: fill ? .infinity : nil)
            .foregroundStyle(tint)
            .background(tint.opacity(0.2), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
    }
}
