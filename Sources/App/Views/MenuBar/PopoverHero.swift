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
    /// The reading details card (round 56), opened by clicking the reading.
    @State private var showDetails = false

    private var s: GlucoseSnapshot { store.snapshot }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PopoverLayout.heroRadius, style: .continuous)
    }

    var body: some View {
        // Drawn once more at the moment the reading goes stale, so an open popover fades the number
        // to grey and strikes it through right then rather than at the next refresh.
        TimelineView(.explicit(staleMoments)) { _ in hero }
    }

    private var staleMoments: [Date] {
        s.current.map { [$0.timestamp.addingTimeInterval(GlucoseSnapshot.staleAfter + 1)] } ?? []
    }

    @ViewBuilder
    private var hero: some View {
        let stale = s.isStale()
        let tone = s.displayTone()
        let tint = tone.color
        // The first open after launch, before the first fetch lands: the saved reading, dimmed
        // with its age, then one cross-fade to the live one (`LaunchReading`).
        let launch = store.launchPhase()
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    statusRow(stale: stale, launch: launch)
                    if let cur = s.current {
                        Group {
                            valueRow(cur, stale: stale, tint: tint, launch: launch)
                                // Crossing into or out of the target range: one brief wash of the
                                // new colour behind the reading, once per crossing and never while
                                // hovering at the edge (`RangeCrossing`). No haptic on the Mac, and
                                // no wash under Reduce Motion. Alerts are separate. Back in range
                                // after 15+ min out also sweeps one in-range ring (round 89).
                                .rangeCrossingCue(mgdl: cur.mgdl, at: cur.timestamp,
                                                  lowMgdl: s.lowMgdl, highMgdl: s.highMgdl,
                                                  live: !stale && launch == .live, tint: tint)
                            trendRow(cur, stale: stale)
                        }
                        .launchDim(launch, stale: stale)
                    }
                }
                Spacer(minLength: 4)
                if let cur = s.current {
                    TrendDial(trend: stale ? .unknown : cur.trend, tint: tint, size: 62)
                        .opacity(stale ? 0.6 : 1)
                        .launchDim(launch, stale: stale)
                        .accessibilityHidden(true)
                }
            }
            // A click on the reading opens a small card: when it was taken, where it came from,
            // the rate per minute and when the next one is due (round 56).
            .readingDetailsPopover(isPresented: $showDetails, snapshot: s, unit: store.shownUnit,
                                   lastCheck: store.lastAttempt,
                                   checkEvery: TimeInterval(settings.pollIntervalSeconds)) {
                // Copy and Share under the details (round 100). Copy is the same as ⌘C: one
                // line, the "Copied" toast and one announce.
                AnyView(ReadingCopyButtons(line: store.readingCopyText(), onCopy: onCopy))
            }
            .help(s.current == nil ? "" : "Click for reading details")
            if let cur = s.current {
                RangeRail(mgdl: cur.mgdl, lowMgdl: s.lowMgdl, highMgdl: s.highMgdl, stale: stale,
                          forecastMgdl: stale || !settings.showForecast ? nil : s.currentOutlook().flatMap(OutlookFormat.headlineSample)?.sample.mgdl,
                          thickness: 5, unit: store.shownUnit)
                    .launchDim(launch, stale: stale)
                FreshnessRow(reading: cur, launch: launch)
                // The sensor's last 24 hours: day count and time left, quietly (docs/SensorEnd.md).
                if let sensor = s.sensor { PopoverSensorCountdown(sensor: sensor) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // First stop in the popover; Return opens the reading details, as a click does.
        .keyStop("popover.hero", radius: PopoverLayout.heroRadius) { if s.current != nil { showDetails = true } }
        // Losing the signal or getting it back: the trend line, needle and rail fade over with the
        // number (whose own fade and strike come from `.staleStrike`). The first reading after
        // waiting fades in. Only fades remain under Reduce Motion.
        .dsAnimation(.sweep, value: stale)
        .dsAnimation(.standard, value: s.current == nil)
        // One element for VoiceOver: the whole reading in a sentence, with the card's actions.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits([.isHeader, .updatesFrequently])
        .accessibilityAction(named: "Copy reading", onCopy)
        .accessibilityAction(named: "Refresh", onRefresh)
        .accessibilityAction(named: "Open Dashboard", onOpenDashboard)
        .accessibilityAction(named: "Show reading details") { if s.current != nil { showDetails = true } }
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
        // An urgent low gets a rim as well as its colour, so it reads without colour vision.
        .urgentRim(!stale && s.range == .urgentLow, in: shape)
        .readingRipple(trigger: ripple, in: shape, tint: tint)
        .dsShadow(.medium, tint: stale ? nil : tint)
        .contentShape(shape)
        .contextMenu {
            Button("Copy Reading", systemImage: "doc.on.doc", action: onCopy)
                .disabled(s.current == nil)
            Button("Refresh Now", systemImage: "arrow.clockwise", action: onRefresh)
                .disabled(store.isRefreshing)
            Button("Reading Details", systemImage: "info.circle") { showDetails = true }
                .disabled(s.current == nil)
            Divider()
            Button("Open Dashboard", systemImage: "macwindow", action: onOpenDashboard)
        }
        // One ripple per new reading, but not for the launch handover, which is a single fade.
        .onChange(of: RippleKey(timestamp: s.current?.timestamp, phase: store.launchPhase())) { old, new in
            guard LaunchReading.playsRipple(from: (old.timestamp, old.phase), to: (new.timestamp, new.phase),
                                            reduceMotion: reduceMotion) else { return }
            ripple += 1
        }
    }

    // MARK: Rows

    private func statusRow(stale: Bool, launch: LaunchReading) -> some View {
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
            // Not while the saved reading waits: its dimmed figure already says it is being checked.
            if launch.showsSpinner(isRefreshing: store.isRefreshing) {
                ProgressView().controlSize(.mini)
                    .transition(.opacity)
            }
        }
        .frame(height: 22)
    }

    private func valueRow(_ cur: GlucoseReading, stale: Bool, tint: Color, launch: LaunchReading) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            // The saved reading cross-fades to the first live one once, rather than rolling.
            LaunchFigure(phase: launch) {
                Text(store.shownUnit.format(mgdl: cur.mgdl))
                    .font(.system(size: (54 * (1 + (textScale.scale - 1) * 0.5)).rounded(), weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(stale ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(numberStyle(tint)))
                    // A new reading rolls the digits over to it, up or down with the change, like the
                    // iPhone and the Live Activity. Crossing a range edge moves the figure and its colour
                    // together on the slower colour fade. Once per change, never while the popover just
                    // sits open; under Reduce Motion the number just changes. VoiceOver reads the card's
                    // label, which is always the new reading, never a figure part-way through the roll.
                    .readingChange(mgdl: cur.mgdl, tone: s.displayTone(), instantUnderReduceMotion: true)
                    // A stale value is crossed through lightly, so it can't be read as current even in
                    // a quick glance or a screenshot. The line draws across as the data goes stale.
                    .staleStrike(stale)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Text(store.shownUnit.label)
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
                // The words cross-fade when the trend turns (the dial's needle swings with them).
                Text(cur.trend.description)
                    .fontWeight(.semibold).dsFont(.callout)
                    .contentTransition(.opacity)
                    .dsAnimation(.sweep, value: cur.trend)
                if let d = s.deltaMgdl {
                    Text(store.shownUnit.formatDelta(mgdl: d))
                        .fontWeight(.medium).dsFont(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        // Rolls with the reading; just changes under Reduce Motion.
                        .contentTransition(reduceMotion ? .identity : .numericText(value: d))
                        .dsAnimation(.arrival, value: d)
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
        if let countdown = s.sensorCountdown() { label += ". " + countdown.spoken() }
        if let note = store.launchPhase().spokenNote { label += ", \(note)" }
        if let streak = s.rangeStreak(), streak.duration >= 5 * 60 {
            label += ", \(streak.range.label) for \(streak.isOpenEnded ? "over " : "")\(PopoverFormat.spokenStreak(streak.duration))"
        }
        return label
    }
}

/// The quiet "Sensor day 15 of 15 · 6 h left" line, from 24 hours before the sensor ends. Waits
/// for that moment without ticking, then redraws once a minute while it shows.
private struct PopoverSensorCountdown: View {
    let sensor: SensorInfo

    var body: some View {
        if SensorEnd.countdown(sensor: sensor) != nil {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                if let countdown = SensorEnd.countdown(sensor: sensor, at: context.date) {
                    SensorCountdownLine(countdown: countdown)
                        .help("Sensor \(sensor.serial) ends \(ClockLabel.dayTime(sensor.expires, now: context.date))")
                }
            }
        } else if let starts = SensorEnd.countdownStarts(sensor: sensor), starts > Date() {
            TimelineView(.explicit(RedrawMoments.explicit([starts], now: Date()))) { context in
                if let countdown = SensorEnd.countdown(sensor: sensor, at: context.date) {
                    SensorCountdownLine(countdown: countdown)
                }
            }
        }
    }
}

/// "Updated 32s ago · 3:41 pm" over the shared `FreshnessMeter`, which fills from the reading to
/// the moment it goes stale (docs/Redesign.md §5.4, §8.2) and is drawn full and amber once stale.
/// The label ticks every second on its own, so the rest of the popover doesn't re-render with it.
private struct FreshnessRow: View {
    let reading: GlucoseReading
    /// The saved reading from before launch is never "Updated", and isn't warned about as nearly stale.
    var launch: LaunchReading = .live

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let age = reading.age(at: context.date)
            let stale = age > GlucoseSnapshot.staleAfter
            let nearlyStale = !stale && launch == .live && age > GlucoseSnapshot.staleAfter * 0.66
            let warning = Tone.warning
            let color: Color = stale || nearlyStale ? warning.textColor : .secondary
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    if stale {
                        Image(systemName: "exclamationmark.triangle.fill").imageScale(.small)
                    } else {
                        Image(systemName: "clock").imageScale(.small)
                    }
                    Text("\(launch.ageLead(stale: stale)) \(PopoverFormat.ageAgo(age))")
                        .monospacedDigit()
                    Spacer(minLength: 4)
                    Text(reading.timestamp.formatted(date: .omitted, time: .shortened))
                        .foregroundStyle(.tertiary)
                }
                .dsFont(.label)
                .foregroundStyle(color)

                FreshnessMeter(readingDate: reading.timestamp, stale: stale,
                               tint: nearlyStale ? warning.color.opacity(0.8) : Palette.neutral,
                               width: nil)
                    .help("Readings older than \(Int(GlucoseSnapshot.staleAfter / 60)) minutes are treated as stale")
            }
            .dsAnimation(.ambient, value: stale)
        }
    }
}
