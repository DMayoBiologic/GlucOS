import SwiftUI

// The follower view (docs/Sharing.md "What followers see"): someone a phone follows, shown the way
// they see themselves. The stage with their reading, needle, rail and forecast note; Check in,
// always one tap away; what's on board; the chart with their logbook marked; their last day's
// logbook; and time in range over 24 hours to 14 days, day by day. Built from the same Signal
// pieces as the owner's own home screen. The data is the share link's: the Lock Screen card
// (`ShareSnapshot.card`) and `FollowStore.details` (readings and logbook, from /v1/detail).

/// Everything about one followed person, as the cards of a scrolling screen. The screen around
/// it (title, backdrop, check-in bar) belongs to whoever shows it.
struct FollowPersonView: View {
    @EnvironmentObject var follows: FollowStore
    let follow: Follow

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let now = context.date
            let card = follows.snapshots[follow.id]?.card
            let detail = follows.details[follow.id]
            VStack(spacing: DS.Space.lg) {
                if follows.ended.contains(follow.id) {
                    FollowEndedCard(follow: follow)
                } else if let card {
                    FollowStage(follow: follow, card: card, history: detail?.history, now: now)
                        .dsEntrance(0)
                    FollowCheckInCard(follow: follow, card: card, now: now)
                        .dsEntrance(1)
                    if let logbook = detail?.logbook {
                        FollowOnBoardRow(card: card, logbook: logbook, now: now).dsEntrance(1)
                    }
                    FollowChartCard(card: card, detail: detail, now: now).dsEntrance(2)
                    FollowLogbookCard(follow: follow, detail: detail, now: now).dsEntrance(3)
                    FollowRangeCard(card: card, detail: detail, now: now).dsEntrance(4)
                } else {
                    FollowWaitingCard(follow: follow)
                }
            }
        }
    }
}

// MARK: - Stage

/// Their reading the way the owner's stage shows it: range pill and how long they've been in it,
/// the value with its needle, the rail with the forecast's ghost marker, the forecast note and
/// the freshness meter. A new reading rolls the value and sends one ripple out of the needle.
struct FollowStage: View {
    let follow: Follow
    let card: GlucoseActivityState
    let history: FollowHistory?
    let now: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    private let textScale = DSScaledValue()
    @State private var ripple = 0

    var body: some View {
        let stale = card.isStale(at: now)
        let tone = card.range.tone(stale: stale)
        let unit = card.glucoseUnit
        let headline = stale ? nil : card.forecastHeadline
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSAccessibleStack(spacing: DS.Space.sm) {
                RangeBadge(range: card.range, stale: stale)
                    .id(stale ? "stale" : card.range.label)
                    .transition(.push(from: card.glucoseTrend.isFalling ? .top : .bottom))
                if !stale, let since = rangeSince, now.timeIntervalSince(since) >= 5 * 60 {
                    Text("for \(PopoverFormat.streak(now.timeIntervalSince(since)))")
                        .dsFont(.label)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            .dsAnimation(.standard, value: card.range)
            HStack(alignment: .center, spacing: DS.Space.md) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    DSAccessibleStack(verticalAlignment: .firstTextBaseline, spacing: DS.Space.xs + 2) {
                        Text(card.valueText)
                            .font(.system(size: (96 * (1 + (min(textScale.scale, 1.5) - 1) * 0.4)).rounded(), weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(stale ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(tone.color))
                            .staleStrike(stale)
                            .contentTransition(.numericText(value: card.mgdl))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text(unit.label).dsFont(.callout).fontWeight(.semibold).foregroundStyle(.secondary)
                    }
                    DSAccessibleStack(spacing: DS.Space.sm) {
                        if stale {
                            Text("Trend unavailable").foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: DS.Space.sm) {
                                TrendSymbol(trend: card.glucoseTrend)
                                Text(card.glucoseTrend.description)
                            }
                            if let delta = card.deltaText {
                                Text(delta).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                    .dsFont(.headline)
                }
                Spacer(minLength: DS.Space.sm)
                if !typeSize.dsLargeText {
                    TrendDial(trend: stale ? .unknown : card.glucoseTrend, tint: tone.color, size: 80)
                        .opacity(stale ? 0.6 : 1)
                        .readingRipple(trigger: ripple, in: Circle(), tint: tone.color)
                        .accessibilityHidden(true)
                }
            }
            RangeRail(mgdl: card.mgdl, lowMgdl: card.lowMgdl, highMgdl: card.highMgdl, stale: stale,
                      forecastMgdl: headline?.mgdl, thickness: 6, unit: unit)
                .padding(.vertical, DS.Space.xxs)
            if !stale, headline != nil || card.lowExpectedAt != nil {
                ForecastNote(unit: unit, headline: headline, lowExpectedAt: card.lowExpectedDate,
                             readingDate: card.readingDate, wraps: true)
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
            }
            freshness(stale: stale)
        }
        .padding(.horizontal, DS.Space.xs)
        .padding(.vertical, DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(card.range == .urgentLow && !stale ? DS.Space.md : 0)
        .urgentRim(card.range == .urgentLow && !stale, in: RoundedRectangle(cornerRadius: DS.Radius.hero, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility(stale: stale))
        .accessibilityAddTraits(.updatesFrequently)
        .onChange(of: card.readingAt) { old, new in
            guard old != new, !reduceMotion else { return }
            ripple += 1
        }
        .sensoryFeedback(trigger: card.range) { old, new in
            switch new {
            case .low, .urgentLow: return old == new ? nil : .warning
            case .inRange: return old == new ? nil : .success
            case .high, .veryHigh: return nil
            }
        }
    }

    /// When their readings last crossed into the range they're in now, from the readings this
    /// phone has. Nil when it can't tell.
    private var rangeSince: Date? {
        guard let readings = history?.readings, !readings.isEmpty else { return nil }
        let current = card.range
        var since: Date?
        for r in readings.reversed() {
            if GlucoseRange.classify(mgdl: r.mgdl, low: card.lowMgdl, high: card.highMgdl) != current { break }
            since = r.timestamp
        }
        return since
    }

    private func freshness(stale: Bool) -> some View {
        DSAccessibleStack(spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.xs) {
                if stale {
                    Image(systemName: "clock.badge.exclamationmark")
                } else {
                    LiveDot(live: true).padding(.trailing, 2)
                }
                FreshnessMeter(readingDate: card.readingDate, stale: stale,
                               tint: stale ? Tone.warning.color : Palette.neutral, width: 36)
                    .padding(.trailing, DS.Space.xxs)
            }
            Text(stale ? "Last reading \(PopoverFormat.ageAgo(now.timeIntervalSince(card.readingDate)))"
                       : "Updated \(PopoverFormat.ageAgo(now.timeIntervalSince(card.readingDate)))")
            Text(typeSize.dsLargeText ? ClockLabel.dayTime(card.readingDate, now: now)
                                      : "· \(ClockLabel.dayTime(card.readingDate, now: now))")
                .foregroundStyle(.tertiary)
        }
        .dsFont(.caption)
        .foregroundStyle(stale ? AnyShapeStyle(Tone.warning.textColor) : AnyShapeStyle(Color.secondary))
        .monospacedDigit()
    }

    private func accessibility(stale: Bool) -> String {
        let unit = card.glucoseUnit
        var s = "\(follow.label): \(unit.format(mgdl: card.mgdl, withUnit: true))"
        if stale {
            s += ", last reading \(PopoverFormat.ageAgo(now.timeIntervalSince(card.readingDate)))"
            return s
        }
        s += ", \(card.range.label), \(card.glucoseTrend.description)"
        if let low = card.lowExpectedDate {
            s += ". Low expected in about \(ForecastNote.roundedMinutes(low.timeIntervalSince(card.readingDate))) minutes"
        } else if let h = card.forecastHeadline {
            s += ". Forecast about \(unit.format(mgdl: h.mgdl)) in \(h.minutes) minutes"
        }
        return s
    }
}

// MARK: - Check in

/// Check in, on their screen whatever their reading: one tap asks them if they're okay, and
/// their answer shows here. While they're low (or forecast to be) it says so and leads; otherwise
/// it sits quietly under the stage. Asking for this phone's name happens right here, so their
/// notification can say who's asking.
struct FollowCheckInCard: View {
    @EnvironmentObject var follows: FollowStore
    let follow: Follow
    let card: GlucoseActivityState
    let now: Date
    @State private var error: String?
    @State private var asked = 0
    @FocusState private var nameFocused: Bool

    var body: some View {
        let checkIn = follows.checkIns[follow.id]
        let low = !card.isStale(at: now) && card.offersCheckIn
        let tone: Tone = checkIn?.status == .help ? .critical : (low || checkIn?.status == .noAnswer) ? .warning
            : checkIn?.status == .okay ? .success : .neutral
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(alignment: .top, spacing: DS.Space.md) {
                Image(systemName: icon(checkIn))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tone == .neutral ? Palette.brand : tone.color)
                    .symbolEffect(.bounce, value: asked)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(title(checkIn, low: low)).dsFont(.headline)
                        .foregroundStyle(tone == .neutral ? AnyShapeStyle(Color.primary) : AnyShapeStyle(tone.textColor))
                    Text(detail(checkIn, low: low))
                        .dsFont(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if canAsk(checkIn) {
                Button(action: ask) {
                    HStack {
                        Label(checkIn?.status == .noAnswer ? "Ask Again" : "Check In on \(follow.label)",
                              systemImage: "hand.wave.fill")
                            .dsFont(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if follows.checkingIn.contains(follow.id) { ProgressView().controlSize(.small) }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(low || checkIn?.status == .noAnswer ? Tone.warning.color : Palette.brand)
                .controlSize(.large)
                .disabled(follows.checkingIn.contains(follow.id))
                .accessibilityHint("Sends \(follow.label) a notification asking if they're okay")
            }
            if follows.myName.isEmpty {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                    TextField("Your name, so \(follow.label) knows who's asking", text: $follows.myName)
                        .textContentType(.givenName)
                        .submitLabel(.done)
                        .focused($nameFocused)
                        .dsFont(.callout)
                }
                .padding(DS.Space.sm)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            }
            if let error {
                Text(error).dsFont(.caption).foregroundStyle(Tone.warning.textColor)
            }
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { DSSurface(style: tone == .neutral ? .standard : .tinted(tone), radius: DS.Radius.card) }
        .dsAnimation(.standard, value: checkIn?.status)
        .dsAnimation(.standard, value: low)
        .accessibilityElement(children: .contain)
    }

    private func canAsk(_ c: CheckInState?) -> Bool {
        guard let c else { return true }
        return !c.isWaiting || c.status == .noAnswer
    }

    private func ask() {
        error = nil
        nameFocused = false
        asked += 1
        Task {
            do {
                try await follows.checkIn(follow.id)
                Haptics.success()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func icon(_ c: CheckInState?) -> String {
        switch c?.status {
        case .okay: return "checkmark.circle.fill"
        case .help, .noAnswer: return "exclamationmark.triangle.fill"
        case .asked: return "hand.wave.fill"
        case nil: return "hand.wave"
        }
    }

    private func title(_ c: CheckInState?, low: Bool) -> String {
        guard let c else { return low ? "\(follow.label) is \(lowWords)" : "Check in" }
        switch c.status {
        case .asked: return "Asked at \(ClockLabel.time(c.askedDate))"
        case .noAnswer: return "No answer since \(ClockLabel.time(c.askedDate))"
        case .okay: return "\(follow.label) is okay"
        case .help: return "\(follow.label) needs help"
        }
    }

    private var lowWords: String {
        card.range == .low || card.range == .urgentLow ? "low" : "heading low"
    }

    private func detail(_ c: CheckInState?, low: Bool) -> String {
        guard let c else {
            return low ? "Ask if they're okay. They can answer from their Lock Screen without unlocking."
                       : "Ask \(follow.label) if they're okay at any time. They answer I'm okay or I need help from their Lock Screen, and you'll see it here."
        }
        switch c.status {
        case .asked: return "Waiting for \(follow.label) to answer. You'll get a notification when they do."
        case .noAnswer: return "They've been reminded. Everyone following them has been told too. Ask again, or call them."
        case .okay: return "They answered at \(ClockLabel.time(c.answeredDate ?? c.askedDate))."
        case .help: return "They answered at \(ClockLabel.time(c.answeredDate ?? c.askedDate)). Call them or go to them now."
        }
    }
}

/// Along the bottom of a followed person's screen: Check in, always in reach without scrolling,
/// with the latest check-in's status beside it. The same action as the card under the stage.
struct FollowCheckInBar: View {
    @EnvironmentObject var follows: FollowStore
    let follow: Follow
    @State private var taps = 0
    @State private var error: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let checkIn = follows.checkIns[follow.id]
        let card = follows.snapshots[follow.id]?.card
        let low = card.map { !$0.isStale() && $0.offersCheckIn } ?? false
        let waiting = checkIn.map { $0.isWaiting && $0.status != .noAnswer } ?? false
        HStack(spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: 0) {
                Text(status(checkIn, low: low))
                    .dsFont(.label)
                    .foregroundStyle(statusTone(checkIn, low: low).map { AnyShapeStyle($0.textColor) } ?? AnyShapeStyle(Color.secondary))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                if let error {
                    Text(error).dsFont(.caption).foregroundStyle(Tone.warning.textColor).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button {
                if !reduceMotion { taps += 1 }
                error = nil
                Task {
                    do {
                        try await follows.checkIn(follow.id)
                        Haptics.success()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            } label: {
                Label(checkIn?.status == .noAnswer ? "Ask Again" : "Check In", systemImage: "hand.wave.fill")
                    .symbolEffect(.bounce, value: taps)
                    .dsFont(.headline)
                    .padding(.horizontal, DS.Space.md)
                    .padding(.vertical, DS.Space.sm + 2)
                    .foregroundStyle(.white)
                    .background(low || checkIn?.status == .noAnswer ? Tone.warning.color : Palette.brand, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(PressScaleStyle())
            .disabled(waiting || follows.checkingIn.contains(follow.id) || follows.ended.contains(follow.id))
            .opacity(waiting ? 0.55 : 1)
            .accessibilityHint("Asks \(follow.label) if they're okay")
            .accessibilityShowsLargeContentViewer()
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.top, DS.Space.sm + 2)
        .padding(.bottom, DS.Space.xs)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .background {
            Rectangle()
                .fill(.bar)
                .overlay(alignment: .top) { Divider() }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func status(_ c: CheckInState?, low: Bool) -> String {
        guard let c else { return low ? "\(follow.label) is low. Ask if they're okay." : "Ask \(follow.label) if they're okay" }
        switch c.status {
        case .asked: return "Checked in at \(ClockLabel.time(c.askedDate)), waiting"
        case .noAnswer: return "No answer since \(ClockLabel.time(c.askedDate))"
        case .okay: return "\(follow.label) is okay (\(ClockLabel.time(c.answeredDate ?? c.askedDate)))"
        case .help: return "\(follow.label) needs help (\(ClockLabel.time(c.answeredDate ?? c.askedDate)))"
        }
    }

    private func statusTone(_ c: CheckInState?, low: Bool) -> Tone? {
        switch c?.status {
        case .help: return .critical
        case .noAnswer: return .warning
        case .okay: return .success
        case .asked: return nil
        case nil: return low ? .warning : nil
        }
    }
}

// MARK: - On board

/// What's still acting from their logbook, and the forecast's headline: the owner's three tiles.
struct FollowOnBoardRow: View {
    let card: GlucoseActivityState
    let logbook: FollowLogbook
    let now: Date

    var body: some View {
        let c = logbook.contents
        let o = OnBoardNow(doses: c.doses, meals: c.meals, contexts: c.contexts, at: now)
        DSAccessibleStack(verticalAlignment: .top, spacing: DS.Space.sm) {
            if o.insulin.doseCount > 0 || o.background.isActive { insulinTile(o) }
            carbsTile(o)
            forecastTile
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func insulinTile(_ o: OnBoardNow) -> some View {
        let active = o.insulin.onBoard >= 0.05
        var caption = "None acting"
        if active {
            if let peak = o.insulin.peakAt, peak > now { caption = "Peaks \(ClockLabel.time(peak))" }
            else if let done = o.insulin.mostlyDoneAt { caption = "Done ~\(ClockLabel.time(done))" }
            else { caption = "Winding down" }
        }
        let basal = o.background.isActive ? "Basal ≈ \(OnBoardFormatPhone.number(o.background.onBoard)) u" : nil
        return OnBoardTile(title: "Insulin", systemImage: "syringe", tint: Palette.insulin,
                           value: active ? OnBoardFormatPhone.number(o.insulin.onBoard) : "0", unit: "u",
                           fraction: active && o.insulin.unitsGiven > 0 ? o.insulin.onBoard / o.insulin.unitsGiven : nil,
                           caption: caption, detail: basal,
                           accessibility: active ? "Insulin on board, \(OnBoardFormatPhone.number(o.insulin.onBoard)) units. \(caption)" : "No fast-acting insulin on board")
    }

    private func carbsTile(_ o: OnBoardNow) -> some View {
        let active = o.carbs.onBoard >= 1
        var caption = "None absorbing"
        if active { caption = o.carbs.mostlyAbsorbedAt.map { "Done ~\(ClockLabel.time($0))" } ?? "Nearly absorbed" }
        return OnBoardTile(title: "Carbs", systemImage: "fork.knife", tint: Palette.food,
                           value: active ? "\(Int(o.carbs.onBoard.rounded()))" : "0", unit: "g", fraction: nil,
                           caption: caption, detail: o.carbs.uncountedFood ? "Some food has no carbs" : nil,
                           accessibility: active ? "Carbs on board, \(Int(o.carbs.onBoard.rounded())) grams. \(caption)" : "No carbs on board")
    }

    @ViewBuilder
    private var forecastTile: some View {
        let unit = card.glucoseUnit
        if !card.isStale(at: now), let h = card.forecastHeadline {
            let low = card.lowExpectedDate
            let range = [card.forecastLower, card.forecastUpper].compactMap { $0 }
            OnBoardTile(title: "In \(h.minutes) min", systemImage: low == nil ? "chart.line.uptrend.xyaxis" : "exclamationmark.triangle.fill",
                        tint: Palette.stale, valueTint: low == nil ? nil : Tone.warning.textColor,
                        value: "≈ \(unit.format(mgdl: h.mgdl))", unit: nil, fraction: nil,
                        caption: low.map { "Low ~\(ClockLabel.time($0))" }
                            ?? (range.count == 2 ? "\(unit.format(mgdl: Double(range[0])))–\(unit.format(mgdl: Double(range[1])))" : "Trend"),
                        captionTone: low == nil ? .neutral : .warning,
                        detail: "Trend only",
                        accessibility: "Forecast, not a reading. In \(h.minutes) minutes about \(unit.format(mgdl: h.mgdl, withUnit: true))\(low.map { ". Low expected around \(ClockLabel.time($0))" } ?? "")")
        } else {
            OnBoardTile(title: "Forecast", systemImage: "chart.line.uptrend.xyaxis", tint: Palette.stale,
                        value: "–", unit: nil, fraction: nil,
                        caption: card.isStale(at: now) ? "Needs a new reading" : "Not available", detail: nil,
                        accessibility: "No forecast right now")
        }
    }
}

// MARK: - Chart

/// Their trace over 3 to 24 hours, their logged insulin and food along the bottom, and the
/// forecast past "Now". Before the 14 days have loaded it draws the card's last 3 hours.
struct FollowChartCard: View {
    let card: GlucoseActivityState
    let detail: FollowDetail?
    let now: Date
    @AppStorage("followChartHours") private var hours = 6

    private static let choices = [3, 6, 12, 24]
    /// What the chart is handed whatever span is picked, plus its lead past the left edge.
    private static let longest = Double(choices.max() ?? 24) + 0.25

    var body: some View {
        let unit = card.glucoseUnit
        let span = Double(hours)
        let readings = readings(hours: Self.longest)
        let forecast = card.isStale(at: now) ? [] : forecastSamples
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSAccessibleStack(spacing: DS.Space.sm) {
                Eyebrow(title: "Glucose", systemImage: "chart.xyaxis.line")
                SlidingSegments(selection: $hours, options: Self.choices) { "\($0)h" }
                    .frame(maxWidth: 200)
                    .sensoryFeedback(.selection, trigger: hours)
                    .accessibilityLabel("Chart hours")
            }
            // The longest span's readings, `span` of them shown: the chart glides between spans itself.
            GlucoseChart(readings: readings, unit: unit, lowMgdl: card.lowMgdl, highMgdl: card.highMgdl,
                         hours: span, showAxes: true, interactive: true, latestIsStale: card.isStale(at: now),
                         forecast: forecast, events: events(hours: Self.longest),
                         timeLabelCount: hours <= 3 ? 4 : 6, marksNow: true)
                .frame(height: 260)
            HStack(spacing: DS.Space.md) {
                if detail?.logbook != nil {
                    LegendText(color: Palette.insulin, text: "Insulin")
                    LegendText(color: Palette.food, text: "Food")
                }
                if !forecast.isEmpty {
                    HStack(spacing: DS.Space.xs) {
                        Capsule().fill(Palette.stale).frame(width: 12, height: 2)
                        Text("Forecast")
                    }
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityHidden(true)
            if !forecast.isEmpty {
                Text("Forecast from the trend only. An estimate, not a reading.")
                    .dsFont(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .dsCard(.standard, padding: DS.Space.lg)
    }

    /// The loaded readings, with the card's newer ones on the end; just the card's before they load.
    private func readings(hours: Double) -> [GlucoseReading] {
        let cardReadings = card.historyReadings
        guard let loaded = detail?.history, !loaded.isEmpty else { return cardReadings }
        var out = loaded.readings(lastHours: hours, now: now)
        let last = out.last?.timestamp ?? .distantPast
        out.append(contentsOf: cardReadings.filter { $0.timestamp > last.addingTimeInterval(60) })
        if let newest = out.last, newest.timestamp < card.readingDate.addingTimeInterval(-60) {
            out.append(GlucoseReading(timestamp: card.readingDate, mgdl: card.mgdl, trend: card.glucoseTrend))
        }
        return out
    }

    /// The card's forecast line, with a likely range that widens from the reading to the card's
    /// end-of-forecast range.
    private var forecastSamples: [ForecastSample] {
        let points = card.forecastPoints
        guard let end = points.last else { return [] }
        let lowerGap = card.forecastLower.map { end.mgdl - Double($0) } ?? 0
        let upperGap = card.forecastUpper.map { Double($0) - end.mgdl } ?? 0
        return points.enumerated().map { i, p in
            let f = Double(i + 1) / Double(points.count)
            return ForecastSample(date: p.date, mgdl: p.mgdl, lowerMgdl: p.mgdl - lowerGap * f, upperMgdl: p.mgdl + upperGap * f)
        }
    }

    private func events(hours: Double) -> [ChartLogMarker] {
        guard let c = detail?.logbook?.contents else { return [] }
        return ChartLogMarker.logbook(doses: c.doses, meals: c.meals, contexts: c.contexts,
                                      since: now.addingTimeInterval(-hours * 3600))
    }
}

// MARK: - Logbook

/// Their last day's logbook, grouped under Today and Yesterday, without notes. Read-only.
struct FollowLogbookCard: View {
    let follow: Follow
    let detail: FollowDetail?
    let now: Date

    private static let maxRows = 8

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(title: "Logbook", systemImage: "list.bullet.rectangle", trailing: "Last 24 hours")
                if let logbook = detail?.logbook, !logbook.entries.isEmpty {
                    NavigationLink(value: FollowRoute.logbook(follow.id)) {
                        Text("See All").dsFont(.label)
                    }
                    .accessibilityLabel("See \(follow.label)'s last two days")
                }
            }
            if let detail, !detail.showsLogbook {
                Text("\(follow.label) shares their readings but not their logbook.")
                    .dsFont(.callout).foregroundStyle(.secondary)
            } else if let logbook = detail?.logbook {
                let recent = logbook.entries.filter { $0.timestamp > now.addingTimeInterval(-24 * 3600) }
                if recent.isEmpty {
                    Text("Nothing logged in the last 24 hours.").dsFont(.callout).foregroundStyle(.secondary)
                } else {
                    FollowLogRows(entries: Array(recent.prefix(Self.maxRows)), now: now)
                    if recent.count > Self.maxRows {
                        NavigationLink(value: FollowRoute.logbook(follow.id)) {
                            HStack(spacing: DS.Space.xs) {
                                Text("\(recent.count - Self.maxRows) more in the last 24 hours")
                                Image(systemName: "chevron.right").imageScale(.small)
                            }
                            .dsFont(.caption)
                        }
                        .padding(.top, DS.Space.xxs)
                    }
                }
            } else if detail?.fetchedAt != nil {
                Text("\(follow.label)'s insulin and food show here once their GlucOS syncs its logbook.")
                    .dsFont(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: DS.Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").dsFont(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard(.standard, padding: DS.Space.lg)
    }
}

/// Entries grouped by day, newest first.
struct FollowLogRows: View {
    let entries: [LogEntry]
    let now: Date

    var body: some View {
        ForEach(groups, id: \.title) { group in
            VStack(alignment: .leading, spacing: 0) {
                Text(group.title)
                    .dsFont(.label)
                    .foregroundStyle(.secondary)
                    .padding(.top, DS.Space.xs)
                    .padding(.bottom, DS.Space.xxs)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider().padding(.leading, 28) }
                    PhoneLogRow(entry: entry, site: entry.dose?.site, showsChevron: false)
                        .padding(.vertical, DS.Space.sm)
                }
            }
        }
    }

    private struct DayGroup {
        let title: String
        let entries: [LogEntry]
    }

    private var groups: [DayGroup] {
        var out: [DayGroup] = []
        for e in entries {
            let title = ClockLabel.dayTitle(ClockLabel.day(of: e.timestamp, now: now))
            if let last = out.last, last.title == title {
                out[out.count - 1] = DayGroup(title: title, entries: last.entries + [e])
            } else {
                out.append(DayGroup(title: title, entries: [e]))
            }
        }
        return out
    }
}

/// Pushed screens from a followed person's view.
enum FollowRoute: Hashable {
    /// Their whole screen, from the owner's home (`FollowPersonScreen`).
    case person(String)
    case logbook(String)
}

/// Their last two days of logbook, all of it.
struct FollowLogbookList: View {
    @EnvironmentObject var follows: FollowStore
    let followID: String

    var body: some View {
        let label = follows.follows.first { $0.id == followID }?.label ?? "Logbook"
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    if let entries = follows.details[followID]?.logbook?.entries, !entries.isEmpty {
                        FollowLogRows(entries: entries, now: ctx.date)
                    } else {
                        Text("Nothing logged in the last two days.").dsFont(.callout).foregroundStyle(.secondary)
                    }
                    Text("The last 48 hours. Notes stay private to \(label).")
                        .dsFont(.caption).foregroundStyle(.tertiary)
                        .padding(.top, DS.Space.sm)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .dsCard(.standard, padding: DS.Space.lg)
                .padding(.horizontal, DS.Space.lg)
                .padding(.bottom, DS.Space.lg)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
        }
        .background { PhoneBackdrop(tone: .neutral) }
        .navigationTitle("\(label)'s logbook")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await follows.refresh(canStart: true) }
    }
}

// MARK: - Time in range

/// Their time in range over 24 hours, 7 or 14 days, and each of the last seven days.
struct FollowRangeCard: View {
    let card: GlucoseActivityState
    let detail: FollowDetail?
    let now: Date
    @State private var window: GlanceWindow = .day

    var body: some View {
        let readings = detail?.history.readings ?? []
        let windowed = readings.filter { $0.timestamp >= now.addingTimeInterval(-window.hours * 3600) }
        let stats = windowed.count >= 12 ? GlucoseStats.compute(windowed, low: card.lowMgdl, high: card.highMgdl) : nil
        VStack(spacing: DS.Space.lg) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                DSAccessibleStack(spacing: DS.Space.sm) {
                    Eyebrow(title: "Time in range", systemImage: "circle.dashed")
                    Picker("Period", selection: $window) {
                        ForEach(GlanceWindow.allCases) { Text($0.shortLabel).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 180)
                }
                if let stats {
                    GlanceStatsContent(stats: stats, unit: card.glucoseUnit)
                    if let first = readings.first, now.timeIntervalSince(first.timestamp) < window.hours * 3600 - 3600 {
                        Text("From \(ClockLabel.dayTime(first.timestamp, now: now)), the oldest reading shared.")
                            .dsFont(.caption).foregroundStyle(.tertiary)
                    }
                } else if detail?.fetchedAt == nil {
                    HStack(spacing: DS.Space.sm) {
                        ProgressView().controlSize(.small)
                        Text("Loading…").dsFont(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Not enough readings yet.").dsFont(.callout).foregroundStyle(.secondary)
                }
            }
            .dsCard(.standard, padding: DS.Space.lg)
            DayColumnsCard(days: PhoneDayStats.lastDays(7, readings: readings.filter { $0.timestamp >= now.addingTimeInterval(-8 * 86_400) },
                                                        low: card.lowMgdl, high: card.highMgdl, now: now),
                           emptyText: "Each day's time in range shows here once there's a day of readings.")
        }
    }
}

// MARK: - Other states

private struct FollowEndedCard: View {
    @EnvironmentObject var follows: FollowStore
    let follow: Follow

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Label("Sharing ended", systemImage: "person.crop.circle.badge.xmark").dsFont(.headline)
            Text("\(follow.label) stopped sharing, or the link ended. Ask them for a new link to follow again.")
                .dsFont(.callout).foregroundStyle(.secondary)
            Button("Remove", role: .destructive) { Task { await follows.remove(follow) } }
                .dsFont(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard(.standard, padding: DS.Space.lg)
    }
}

private struct FollowWaitingCard: View {
    @EnvironmentObject var follows: FollowStore
    let follow: Follow

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            if follows.errors[follow.id] == nil { ProgressView().controlSize(.small) }
            Text(follows.errors[follow.id] ?? "Waiting for \(follow.label)'s first reading…")
                .dsFont(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard(.standard, padding: DS.Space.lg)
    }
}
