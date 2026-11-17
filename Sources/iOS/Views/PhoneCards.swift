import SwiftUI

// The iPhone's cards. Same surfaces, colours and type as the Mac popover: the reading's range
// decides the hue, a stale reading turns grey and is crossed through, and forecasts are always
// grey and marked "≈".

// MARK: - Hero

/// The stage (docs/Redesign.md §7.1): the reading on the screen's range field rather than in a
/// card. Range pill and streak, the value with its needle, the range rail with the forecast's ghost
/// marker, the forecast note, and the freshness meter. A new reading rolls the value, swings the
/// needle, glides the rail marker and sends one ripple out of the needle.
struct PhoneHeroCard: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    private let textScale = DSScaledValue()
    /// Bumped on each new reading to play one soft ripple around the card, like the Mac popover.
    @State private var ripple = 0

    private var s: GlucoseSnapshot { store.snapshot }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let now = context.date
            let stale = s.isStale(at: now)
            let tone = s.displayTone(at: now)
            let outlook = settings.showForecast && !stale ? s.currentOutlook(at: now) : nil
            let headline = outlook.flatMap(OutlookFormat.headlineSample)
            // A new sensor's first hour: a countdown instead of the old sensor's last reading.
            let warmUp = s.warmUp(at: now)
            // Right after launch: the saved reading, dimmed with its age, until the first fetch.
            let launch = store.launchPhase(at: now)
            VStack(alignment: .leading, spacing: DS.Space.md) {
                HStack(spacing: DS.Space.sm) {
                    // The streak drops under the pill at the accessibility text sizes.
                    DSAccessibleStack(spacing: DS.Space.sm) {
                        if let range = s.range, warmUp == nil {
                            RangeBadge(range: range, stale: stale)
                                .id(stale ? "stale" : range.label)
                                .transition(.push(from: (s.current?.trend.isFalling ?? false) ? .top : .bottom))
                        }
                        if warmUp == nil, let streak = s.rangeStreak(at: now), streak.duration >= 5 * 60 {
                            Text("for \(streak.isOpenEnded ? "over " : "")\(PopoverFormat.streak(streak.duration))")
                                .dsFont(.label)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                    }
                    Spacer(minLength: 0)
                    if launch.showsSpinner(isRefreshing: store.isRefreshing) { ProgressView().controlSize(.small) }
                }
                .dsAnimation(.standard, value: s.range)
                // The pill swaps to "No recent data" and back without a jump.
                .dsAnimation(.standard, value: stale)
                if let warmUp {
                    PhoneWarmUpView(warmUp: warmUp, now: now)
                        .transition(.opacity)
                } else if let cur = s.current {
                    HStack(alignment: .center, spacing: DS.Space.md) {
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            valueRow(cur, stale: stale, tint: tone.color, now: now, launch: launch)
                                // Crossing into or out of the target range: one light tap (a low
                                // keeps its warning) and a brief wash of the new colour, once per
                                // crossing and never while hovering at the edge. No wash under
                                // Reduce Motion. Alerts are separate.
                                .rangeCrossingCue(mgdl: cur.mgdl, at: cur.timestamp,
                                                  lowMgdl: s.lowMgdl, highMgdl: s.highMgdl,
                                                  live: !stale && launch == .live && warmUp == nil,
                                                  tint: tone.color) { Haptics.play($0.haptic) }
                            trendRow(cur, stale: stale)
                        }
                        .launchDim(launch, stale: stale)
                        Spacer(minLength: DS.Space.sm)
                        // At the accessibility text sizes the reading needs the whole width, and
                        // the trend is in words under it, so the needle steps aside.
                        if !typeSize.dsLargeText {
                            TrendDial(trend: stale ? .unknown : cur.trend, tint: tone.color, size: 80)
                                .opacity(stale ? 0.6 : 1)
                                .launchDim(launch, stale: stale)
                                .readingRipple(trigger: ripple, in: Circle(), tint: tone.color)
                                .accessibilityHidden(true)
                        }
                    }
                    RangeRail(mgdl: cur.mgdl, lowMgdl: s.lowMgdl, highMgdl: s.highMgdl, stale: stale,
                              forecastMgdl: headline?.sample.mgdl, thickness: 6, unit: s.unit)
                        .launchDim(launch, stale: stale)
                        .padding(.vertical, DS.Space.xxs)
                    if let outlook, headline != nil || outlook.lowExpectedAt != nil {
                        ForecastNote(unit: s.unit, headline: headline.map { (minutes: $0.minutes, mgdl: $0.sample.mgdl) },
                                     lowExpectedAt: outlook.lowExpectedAt, readingDate: cur.timestamp, wraps: true)
                            .dsFont(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let back = backInRange(outlook) {
                        BackInRangeNote(minutes: BackInRangeText.minutes(back, from: cur.timestamp))
                            .dsFont(.callout)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                    freshness(cur, stale: stale, now: now, launch: launch)
                } else {
                    waiting
                }
            }
            .padding(.horizontal, DS.Space.xs)
            .padding(.vertical, DS.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Losing the signal or getting it back: the trend row, needle, rail and freshness meter
            // fade over with the number (whose own fade and strike come from `.staleStrike`). The
            // first reading after a sensor warms up fades in over the placeholder. Only fades
            // remain under Reduce Motion, and nothing repeats.
            .dsAnimation(.sweep, value: stale)
            .dsAnimation(.standard, value: s.current == nil)
            // The warm-up countdown cross-fades to the first reading: a fade, so it stays under
            // Reduce Motion (`.sweep` keeps a short fade there).
            .dsAnimation(.sweep, value: warmUp == nil)
            // An urgent low gets a rim as well as its colour, so it reads without colour vision.
            .padding(s.range == .urgentLow && !stale && warmUp == nil ? DS.Space.md : 0)
            .urgentRim(s.range == .urgentLow && !stale && warmUp == nil,
                       in: RoundedRectangle(cornerRadius: DS.Radius.hero, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(warmUp.map { $0.spoken(at: now) }
                                ?? (s.current == nil ? waitingSummary
                                    : s.accessibilitySummary(at: now) + (launch.spokenNote.map { ". \($0)" } ?? "")
                                      + forecastSentence(outlook, headline: headline)))
            .accessibilityAddTraits(.updatesFrequently)
            // The card is one VoiceOver element, so the empty state's button is an action on it.
            .accessibilityActions {
                if s.current == nil, emptyStep != nil {
                    Button("Check Again") { Task { await store.refresh() } }
                }
            }
            .contextMenu {
                Button("Copy Reading", systemImage: "doc.on.doc") { store.copyReadingToClipboard() }
                Button("Refresh Now", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
            }
        }
        // One ripple per new reading, but not for the launch handover, which is a single fade.
        .onChange(of: RippleKey(timestamp: s.current?.timestamp, phase: store.launchPhase())) { old, new in
            guard LaunchReading.playsRipple(from: (old.timestamp, old.phase), to: (new.timestamp, new.phase),
                                            reduceMotion: reduceMotion) else { return }
            ripple += 1
        }
        // VoiceOver hears a new trend once, here only (the trend row and title arrows say nothing
        // of their own). The same trend again, or a reading going stale, stays quiet, and so does a
        // reading that's already stale when it arrives (a late fetch): its trend isn't news.
        .onChange(of: s.current?.trend) { old, new in
            if !s.isStale(at: .now), let text = TrendTurn.announcement(from: old, to: new) {
                AccessibilityNotification.Announcement(text).post()
            }
        }
    }

    /// Before the first reading: the shape of the card with a placeholder number, so the screen
    /// doesn't jump when it arrives, and what's happening in words. A connection problem has its
    /// own banner above with the fix. Signed in with nothing to show (a new account, a sensor that
    /// has ended, LibreLink not uploading) says what to do next.
    private var waiting: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs + 2) {
                Text("–.–")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundStyle(.quaternary)
                Text(s.unit.label).dsFont(.callout).fontWeight(.semibold).foregroundStyle(.tertiary)
            }
            if let empty = emptyStep {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(empty.title).dsFont(.headline)
                    Text(empty.detail).dsFont(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label(store.isRefreshing ? "Checking…" : "Check Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(store.isRefreshing)
                .padding(.top, DS.Space.xxs)
            } else {
                HStack(spacing: DS.Space.xs) {
                    if store.connectionProblem == nil { ProgressView().controlSize(.small) }
                    Text(store.connectionProblem == nil && store.isRefreshing ? "Getting your latest reading…" : store.statusLine)
                }
                .dsFont(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Signed in and connected, but LibreLinkUp has no reading: what to do about it. Nil while the
    /// first fetch is still going or when a connection problem's banner already says.
    private var emptyStep: NoReadingsStep? {
        NoReadingsStep.current(snapshot: s, hasConnectionProblem: store.connectionProblem != nil)
    }

    /// What the empty card says, for VoiceOver.
    private var waitingSummary: String {
        if let empty = emptyStep { return "\(empty.title). \(empty.detail)" }
        return store.statusLine
    }

    private func valueRow(_ cur: GlucoseReading, stale: Bool, tint: Color, now: Date,
                          launch: LaunchReading) -> some View {
        // The unit moves under the number at the accessibility sizes, so the number keeps the width.
        DSAccessibleStack(verticalAlignment: .firstTextBaseline, spacing: DS.Space.xs + 2) {
            // The saved reading cross-fades to the first live one once, rather than rolling.
            LaunchFigure(phase: launch) {
                Text(s.unit.format(mgdl: cur.mgdl))
                    // Already very large: it stops growing at xxxLarge (about 115 pt), so even
                    // "22.2" fits a small phone at AX5 without shrinking much.
                    .font(.system(size: (96 * (1 + (min(textScale.scale, 1.5) - 1) * 0.4)).rounded(), weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(stale ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(tint))
                    // A new reading rolls the digits over to it (up or down with the change) and a range
                    // change cross-fades the colour, like the Live Activity. Once per change; under Reduce
                    // Motion the number just changes. VoiceOver reads the card's label, which is always
                    // the new reading, never a figure part-way through the roll.
                    .readingChange(mgdl: cur.mgdl, tone: s.displayTone(at: now), instantUnderReduceMotion: true)
                    // The line draws across as the data goes stale (docs/Redesign.md §4.3).
                    .staleStrike(stale)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            Text(s.unit.label)
                .dsFont(.callout)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
        }
    }

    private func trendRow(_ cur: GlucoseReading, stale: Bool) -> some View {
        DSAccessibleStack(spacing: DS.Space.sm) {
            if stale {
                Text("Trend unavailable").foregroundStyle(.secondary)
            } else {
                HStack(spacing: DS.Space.sm) {
                    // One arrow that turns to the new direction (at once under Reduce Motion),
                    // rather than one glyph swapped for another.
                    TrendArrow(trend: cur.trend)
                        .fontWeight(.bold)
                        .accessibilityHidden(true)
                    Text(cur.trend.description)
                        .contentTransition(.opacity)
                        .dsAnimation(.sweep, value: cur.trend)
                }
                if let d = s.deltaMgdl {
                    Text(s.unit.formatDelta(mgdl: d)).monospacedDigit().foregroundStyle(.secondary)
                        .contentTransition(reduceMotion ? .identity : .numericText(value: d))
                        .dsAnimation(.arrival, value: d)
                }
            }
        }
        .dsFont(.headline)
    }

    /// What the forecast note says, for VoiceOver. Empty when no note is shown.
    private func forecastSentence(_ outlook: OutlookSnapshot?,
                                  headline: (minutes: Int, sample: ForecastSample)?) -> String {
        guard let outlook, let cur = s.current else { return "" }
        if let low = outlook.lowExpectedAt {
            return ". Low expected in about \(ForecastNote.roundedMinutes(low.timeIntervalSince(cur.timestamp))) minutes"
        }
        var out = ""
        if let headline {
            out = ". Forecast about \(s.unit.format(mgdl: headline.sample.mgdl)) in \(headline.minutes) minutes"
        }
        if let back = backInRange(outlook) {
            out += ". " + BackInRangeText.spoken(minutes: BackInRangeText.minutes(back, from: cur.timestamp))
        }
        return out
    }

    /// When the forecast says a high comes back into range. Only above range, never with a low
    /// expected, and only while this device's checks of it stay within 15 minutes (`BackInRange`).
    private func backInRange(_ outlook: OutlookSnapshot?) -> Date? {
        guard outlook != nil else { return nil }
        return s.backInRange()?.date
    }

    private func tint(stale: Bool) -> Color { stale ? Tone.warning.color : Palette.neutral }

    private func freshness(_ cur: GlucoseReading, stale: Bool, now: Date, launch: LaunchReading) -> some View {
        // Meter, age and clock time on one line; each on its own at the accessibility sizes.
        DSAccessibleStack(spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.xs) {
                if stale {
                    Image(systemName: "clock.badge.exclamationmark")
                } else if launch == .stored {
                    // Not live yet: no pulsing dot until this launch's first fetch lands.
                    Image(systemName: "clock")
                } else {
                    LiveDot(live: true).padding(.trailing, 2)
                }
                FreshnessMeter(readingDate: cur.timestamp, stale: stale, tint: tint(stale: stale), width: 36)
                    .padding(.trailing, DS.Space.xxs)
            }
            Text("\(launch.ageLead(stale: stale)) \(PopoverFormat.ageAgo(cur.age(at: now)))")
            Text(typeSize.dsLargeText ? ClockLabel.dayTime(cur.timestamp, now: now)
                                      : "· \(ClockLabel.dayTime(cur.timestamp, now: now))")
                .foregroundStyle(.tertiary)
        }
        .dsFont(.caption)
        .foregroundStyle(stale ? AnyShapeStyle(Tone.warning.textColor) : AnyShapeStyle(Color.secondary))
        .monospacedDigit()
    }
}

// MARK: - Sensor warm-up

/// The stage while a new sensor warms up: a ring filling over its first hour with the minutes
/// left in the middle, and when the first reading is due. Moves only when the card's 15-second
/// clock ticks (one short ease per tick, none under Reduce Motion), never on a loop.
struct PhoneWarmUpView: View {
    let warmUp: SensorWarmUp
    let now: Date
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let minutes = warmUp.minutesLeft(at: now)
        DSAccessibleStack(spacing: DS.Space.lg) {
            WarmUpRing(fraction: warmUp.fraction(at: now), minutes: minutes,
                       size: typeSize.dsLargeText ? 120 : 96)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Sensor warming up")
                    .dsFont(.label)
                    .foregroundStyle(.secondary)
                Text(warmUp.headline(at: now))
                    .dsFont(.title)
                    .contentTransition(.numericText(value: Double(minutes)))
                    .fixedSize(horizontal: false, vertical: true)
                Text(minutes > 0
                     ? "First reading around \(ClockLabel.time(warmUp.endsAt)). Keep your phone near you; it fades in here when it arrives."
                     : "LibreLinkUp can take a few minutes to pass on the first reading.")
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .dsAnimation(.standard, value: minutes)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - On board

/// What's still acting and where glucose is heading, as three tiles under the reading: fast-acting
/// insulin, carbs and the forecast. Worked out on the view's clock from the logbook, like the Mac's
/// Overview, so the numbers keep counting down between readings. Estimates only, never advice.
struct PhoneOnBoardCard: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var logbook: LogbookStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let now = ctx.date
            let onBoard = OnBoardNow(doses: logbook.doses, meals: logbook.meals, contexts: logbook.contexts, at: now)
            let s = store.snapshot
            // Three tiles side by side; one under another at the accessibility text sizes, where
            // a third of the width can't hold a number and its caption.
            DSAccessibleStack(verticalAlignment: .top, spacing: DS.Space.sm) {
                if onBoard.showsInsulin(therapy: settings.therapy) {
                    insulinTile(onBoard, now: now)
                }
                carbsTile(onBoard, now: now)
                forecastTile(s.currentOutlook(at: now), unit: s.unit, lowMgdl: s.lowMgdl, stale: s.isStale(at: now))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func insulinTile(_ o: OnBoardNow, now: Date) -> some View {
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

    private func carbsTile(_ o: OnBoardNow, now: Date) -> some View {
        let active = o.carbs.onBoard >= 1
        var caption = "None absorbing"
        if active {
            caption = o.carbs.mostlyAbsorbedAt.map { "Done ~\(ClockLabel.time($0))" } ?? "Nearly absorbed"
        }
        return OnBoardTile(title: "Carbs", systemImage: "fork.knife", tint: Palette.food,
                           value: active ? "\(Int(o.carbs.onBoard.rounded()))" : "0", unit: "g", fraction: nil,
                           caption: caption, detail: o.carbs.uncountedFood ? "Some food has no carbs" : nil,
                           accessibility: active ? "Carbs on board, \(Int(o.carbs.onBoard.rounded())) grams. \(caption)" : "No carbs on board")
    }

    @ViewBuilder
    private func forecastTile(_ outlook: OutlookSnapshot?, unit: GlucoseUnit, lowMgdl: Double, stale: Bool) -> some View {
        if let outlook, let headline = OutlookFormat.headlineSample(outlook) {
            let s = headline.sample
            let low = outlook.lowExpectedAt
            OnBoardTile(title: "In \(headline.minutes) min", systemImage: low == nil ? "chart.line.uptrend.xyaxis" : "exclamationmark.triangle.fill",
                        tint: Palette.stale, valueTint: low == nil ? nil : Tone.warning.textColor,
                        value: OutlookFormat.approx(s.mgdl, unit: unit), unit: nil, fraction: nil,
                        caption: low.map { "Low ~\(ClockLabel.time($0))" } ?? OutlookFormat.range(s, unit: unit),
                        captionTone: low == nil ? .neutral : .warning,
                        detail: (outlook.basis == .trend ? "Trend" : "Trend + logbook") + (outlook.morning != nil ? " + morning" : outlook.basis == .trend ? " only" : ""),
                        accessibility: "Forecast, not a reading. In \(headline.minutes) minutes about \(unit.format(mgdl: s.mgdl, withUnit: true)), likely \(OutlookFormat.range(s, unit: unit))\(low.map { ". Low expected around \(ClockLabel.time($0))" } ?? "")")
        } else {
            OnBoardTile(title: "Forecast", systemImage: "chart.line.uptrend.xyaxis", tint: Palette.stale,
                        value: "–", unit: nil, fraction: nil,
                        caption: stale ? "Needs a new reading" : "Not available", detail: nil,
                        accessibility: "No forecast right now")
        }
    }
}

enum OnBoardFormatPhone {
    /// "2.4", or "12" from 10 up.
    static func number(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(v < 10 ? 1 : 0)))
    }
}

struct OnBoardTile: View {
    let title: String
    let systemImage: String
    let tint: Color
    var valueTint: Color? = nil
    let value: String
    let unit: String?
    let fraction: Double?
    let caption: String
    var captionTone: Tone = .neutral
    let detail: String?
    let accessibility: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Label {
                Text(title).dsLineLimit(1).minimumScaleFactor(0.8)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(valueTint ?? tint)
            }
            .dsFont(.label)
            .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xxs) {
                Text(value)
                    .dsFont(.metricValueLarge)
                    .foregroundStyle(valueTint ?? tint)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                if let unit { Text(unit).dsFont(.unit).foregroundStyle(.secondary) }
            }
            if let fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(tint.opacity(0.85))
                            .frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
                    }
                }
                .frame(height: 4)
            }
            Spacer(minLength: 0)
            Text(caption)
                .dsFont(.caption)
                .monospacedDigit()
                .foregroundStyle(captionTone == .neutral ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(captionTone.textColor))
                .dsLineLimit(1)
                .minimumScaleFactor(0.85)
            if let detail {
                Text(detail).dsFont(.caption).foregroundStyle(.tertiary).dsLineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dsCard(.standard, padding: DS.Space.md)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }
}

// MARK: - Chart

/// The trace with logged insulin and food marked along the bottom, the forecast past "Now", and a
/// one-line forecast summary under it. Replaces the separate Outlook card, so the forecast's
/// number sits next to the line it describes.
struct PhoneChartCard: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var logbook: LogbookStore
    @Environment(\.phoneNavigator) private var navigator

    private static let choices = ChartHours.choices
    /// What the chart is handed whatever span is picked, plus its lead past the left edge.
    private static let longest = ChartHours.longestPlotted
    /// When the forecast starts drawing in: this card's `dsEntrance(2)` waits 0.11 s and is most of
    /// the way in about 0.3 s later.
    private static let forecastDelay: TimeInterval = 0.4

    var body: some View {
        let s = store.snapshot
        let hours = Double(settings.chartHours)
        let outlook = settings.showForecast ? s.currentOutlook() : nil
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSAccessibleStack(spacing: DS.Space.sm) {
                Eyebrow(title: "Glucose", systemImage: "chart.xyaxis.line")
                SlidingSegments(selection: $settings.chartHours, options: Self.choices) { "\($0)h" }
                    .frame(maxWidth: 200)
                    .haptic(.choice, trigger: settings.chartHours)
                    .accessibilityLabel("Chart hours")
            }
            // The chart gets the longest span's readings and markers and shows `hours` of them,
            // so switching 3h / 6h / 12h / 24h springs the axes (the chart animates it itself;
            // under Reduce Motion it cross-fades). Pinching the chart steps through the same spans,
            // and the choice is remembered (`AppSettings.chartHours`).
            // The forecast draws in from "Now" once the card has come in, and bends into each new
            // one rather than jumping (as in the Mac popover). Under Reduce Motion it just changes.
            ForecastMotion(forecast: outlook?.forecast ?? [], drawInDelay: Self.forecastDelay) { forecast, reveal in
                GlucoseChart(readings: store.readings(lastHours: Self.longest), unit: s.unit, lowMgdl: s.lowMgdl,
                             highMgdl: s.highMgdl, hours: hours, showAxes: true, interactive: true,
                             forecast: forecast, forecastReveal: reveal, events: events(hours: Self.longest),
                             timeLabelCount: hours <= 3 ? 4 : 6, marksNow: true, popsMarkers: true)
            }
                .frame(height: 260)
                .chartHoursPinch($settings.chartHours)
                .accessibilityAction(named: "Show fewer hours") {
                    settings.chartHours = ChartHours.shorter(than: settings.chartHours)
                }
                .accessibilityAction(named: "Show more hours") {
                    settings.chartHours = ChartHours.longer(than: settings.chartHours)
                }
            legend(outlook)
            lastLogged
            ForecastCaveatLine(caveat: caveat(s, outlook: outlook))
            if let outlook, !outlook.forecast.isEmpty { forecastLine(outlook, unit: s.unit) }
        }
        .dsCard(.standard, padding: DS.Space.lg)
    }

    private func events(hours: Double) -> [ChartLogMarker] {
        ChartLogMarker.logbook(doses: logbook.doses, meals: logbook.meals, contexts: logbook.contexts,
                               since: Date().addingTimeInterval(-hours * 3600))
    }

    /// "Meal 1 h 40 m ago · 45 g" (`LastLogged`): what was logged last, in the last 12 hours. A tap
    /// zooms into the Logbook with that entry opening. Hidden when nothing was logged.
    @ViewBuilder
    private var lastLogged: some View {
        let line = LastLoggedLine(entries: logbook.entries) { id in navigator?.push(.logbookEntry(id)) }
        if let navigator {
            line.matchedTransitionSource(id: AnyHashable(PhoneRoute.lastLoggedSource), in: navigator.zoom)
        } else {
            line
        }
    }

    @ViewBuilder
    private func legend(_ outlook: OutlookSnapshot?) -> some View {
        HStack(spacing: DS.Space.md) {
            LegendText(color: Palette.insulin, text: "Insulin")
            LegendText(color: Palette.food, text: "Food")
            if outlook != nil {
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
    }

    /// Why the forecast is hidden, trend-only, shorter or wider, when it is. A stale reading hides
    /// the forecast before the engine sees it, so that reason is said here.
    private func caveat(_ s: GlucoseSnapshot, outlook: OutlookSnapshot?) -> ForecastCaveat? {
        guard settings.showForecast, s.current != nil else { return nil }
        if let outlook { return outlook.caveat }
        guard s.isStale() else { return nil }
        let stale = ForecastUnavailable.stale(age: 0)
        return ForecastCaveat(kind: .hidden, text: stale.message, detail: nil, source: "unavailable:\(stale.code)")
    }

    private func forecastLine(_ outlook: OutlookSnapshot, unit: GlucoseUnit) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if let low = outlook.lowExpectedAt {
                Label("Low expected around \(ClockLabel.time(low))", systemImage: "exclamationmark.triangle.fill")
                    .dsFont(.label)
                    .foregroundStyle(Tone.warning.textColor)
            }
            if let morning = outlook.morning {
                Label(MorningFormat.todayLine(morning, unit: unit), systemImage: ContextTag.wokeUp.systemImage)
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Forecast from \(outlook.basis.title.lowercased()). An estimate, not a reading: never use it to decide a dose.")
                .dsFont(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - At a glance

struct PhoneGlanceCard: View {
    @EnvironmentObject var store: GlucoseStore
    @State private var window: GlanceWindow = .day
    /// Each of the last 14 days' time in range, worked out off the main thread once per 15 minutes
    /// of new readings or a new target range.
    @State private var trend: InsightsSparkline?

    private struct TrendKey: Hashable {
        let slot: Int
        let low: Double
        let high: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSAccessibleStack(spacing: DS.Space.sm) {
                Eyebrow(title: "At a glance", systemImage: "circle.dashed")
                Picker("Period", selection: $window) {
                    ForEach(GlanceWindow.allCases) { Text($0.shortLabel).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)
            }
            if let stats = store.glanceStats(window) {
                GlanceStatsContent(stats: stats, unit: store.snapshot.unit)
                if let trend {
                    InsightsSparklineView(series: trend, tint: GlucoseRange.inRange.tint,
                                          label: InsightsSparkline.timeInRangeLabel)
                }
            } else {
                Text("Readings will appear here as GlucOS collects them.")
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .dsCard(.standard, padding: DS.Space.lg)
        .task(id: TrendKey(slot: Int((store.archive.last?.timestamp.timeIntervalSince1970 ?? 0) / 900),
                           low: store.snapshot.lowMgdl, high: store.snapshot.highMgdl)) {
            let readings = store.readings(lastHours: 15 * 24)
            let low = store.snapshot.lowMgdl, high = store.snapshot.highMgdl
            let new = await Task.detached(priority: .utility) {
                InsightsSparkline.timeInRange(readings: readings, low: low, high: high)
            }.value
            // The line bends into its new shape by itself (a cross-fade under Reduce Motion).
            trend = new
        }
    }
}

/// Time in range ring, average, GMI and CV, the range bar and its legend, for one period's stats.
struct GlanceStatsContent: View {
    let stats: GlucoseStats
    let unit: GlucoseUnit
    @Environment(\.figuresCountUp) private var countsUp

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSAccessibleStack(spacing: DS.Space.lg) {
                TimeInRangeRing(stats: stats, lineWidth: 11, drawsIn: true)
                    .frame(width: 112, height: 112)
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    StatTile("Average", value: unit.format(mgdl: stats.meanMgdl), unit: unit.label,
                             rolling: .init(stats.meanMgdl) { unit.format(mgdl: $0) })
                    DSAccessibleStack(spacing: DS.Space.lg) {
                        StatTile("GMI", value: String(format: "%.1f", stats.gmiPercent), unit: "%",
                                 rolling: .init(stats.gmiPercent) { String(format: "%.1f", $0) })
                        StatTile("CV", value: Format.percent(stats.coefficientOfVariation),
                                 tone: stats.coefficientOfVariation > 0.36 ? .warning : .neutral,
                                 rolling: .init(stats.coefficientOfVariation) { Format.percent($0) })
                    }
                }
            }
            TimeInRangeBar(stats: stats, drawsIn: countsUp)
            // Spread across the card; one per line at the accessibility text sizes.
            ViewThatFits(in: .horizontal) {
                HStack {
                    glanceLegend(stats, spaced: true)
                }
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    glanceLegend(stats, spaced: false)
                }
            }
        }
    }

    @ViewBuilder
    private func glanceLegend(_ stats: GlucoseStats, spaced: Bool) -> some View {
        LegendText(color: GlucoseRange.low.tint, text: "Below", fraction: stats.timeBelowRange)
        if spaced { Spacer() }
        LegendText(color: GlucoseRange.inRange.tint, text: "In range", fraction: stats.timeInRange)
        if spaced { Spacer() }
        LegendText(color: GlucoseRange.high.tint, text: "Above", fraction: stats.timeAboveRange)
    }
}

struct LegendText: View {
    let color: Color
    let text: String
    /// A share written after `text` as a rolling percentage ("Below 4%").
    var fraction: Double? = nil

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Circle().fill(color).frame(width: 8, height: 8)
            if let fraction {
                HStack(spacing: 0) {
                    Text(text + " ")
                    RollingFigure(fraction) { Format.percent($0) }
                }
                .monospacedDigit()
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(text) \(Format.percent(fraction))")
            } else {
                Text(text).monospacedDigit().fixedSize()
            }
        }
        .dsFont(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Sensor

struct PhoneSensorCard: View {
    let sensor: SensorInfo

    var body: some View {
        let days = sensor.daysRemaining()
        let fraction = days / Double(max(1, sensor.lifetimeDays))
        let tone: Tone = days < 1 ? .critical : days < 2 ? .warning : .neutral
        HStack(spacing: DS.Space.md) {
            ProgressRing(fraction: fraction, tint: tone == .neutral ? Palette.brand : tone.color, lineWidth: 5, drawsIn: true)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text("Sensor").dsFont(.label).foregroundStyle(.secondary)
                Text("\(Format.days(days)) left")
                    .dsFont(.headline)
                    .foregroundStyle(tone == .neutral ? AnyShapeStyle(Color.primary) : AnyShapeStyle(tone.textColor))
            }
            Spacer()
            Text("Ends \(ClockLabel.dayTime(sensor.expires, now: Date()))")
                .dsFont(.caption)
                .foregroundStyle(.secondary)
        }
        .dsCard(.standard, padding: DS.Space.lg)
    }
}
