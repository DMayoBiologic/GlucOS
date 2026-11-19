import SwiftUI
import Charts
import Accessibility

/// Line chart of readings with the target band shaded. Compiled into both the app and the widget.
struct GlucoseChart: View {
    let readings: [GlucoseReading]
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    var hours: Double = 12
    var showAxes: Bool = true
    /// Hover to inspect a reading (app only; widgets aren't interactive).
    var interactive: Bool = false
    /// A reading to highlight as if hovered, e.g. while stepping through readings with the arrow
    /// keys. The pointer wins while it's over the chart.
    var pinnedDate: Date? = nil
    /// Whether the newest reading is old. Its dot and the glow under the trace go neutral grey, so
    /// a stale value is never drawn in a reassuring colour. `nil` (the default) works it out from
    /// the newest reading's age, with the same threshold as `GlucoseSnapshot.isStale`. Pass `false`
    /// only when showing a past period on purpose.
    var latestIsStale: Bool? = nil
    /// An estimate of where glucose may go next, drawn as a dashed grey line with its likely
    /// range, never in a reading's colour. Pass only a current forecast (`OutlookSnapshot.isCurrent`);
    /// it's hidden anyway while the newest reading is stale.
    var forecast: [ForecastSample] = []
    /// How much of the forecast is drawn, from its starting reading (0) to its end (1), while it
    /// draws in (`ForecastMotion`). The axes always make room for all of it, so they hold still.
    var forecastReveal: Double = 1
    /// Logged doses and food, drawn as small markers along the bottom of the chart.
    var events: [ChartLogMarker] = []
    /// How many time labels to aim for along the bottom.
    var timeLabelCount: Int = 4
    /// A faint "Now" line where readings end and the forecast begins.
    var marksNow: Bool = false
    /// Whether a marker that's just been logged (or has just arrived by sync) pops in at its time,
    /// and a deleted one shrinks out, with VoiceOver told which (`MarkerPop`). For the one chart
    /// the user logs against on each device: iPhone Today and the Mac popover. Interactive charts only.
    var popsMarkers: Bool = false
    /// Whether the current-reading dot gives one soft ripple when a newer reading lands, then holds
    /// still until the next one (`NewReadingRipple`), instead of breathing every few seconds. For
    /// iPhone Today and the Mac popover. Interactive charts only; never under Reduce Motion, in the
    /// background, or while a closed Mac popover keeps its chart.
    var ripplesNewReading: Bool = false
    /// Readings from the day before (and up to now: today's own drop out), drawn as a faint grey
    /// line at the same clock time today (`YesterdayLine`), behind the trace. Empty, the default,
    /// draws nothing. Pass them only while `AppSettings.showYesterdayLine` is on.
    var yesterday: [GlucoseReading] = []
    /// Whether a logged marker can be peeked at (`MarkerPeek`): touch and hold one on iPhone for a
    /// small card saying what it was, how long ago and the reading then, gone when the finger lifts;
    /// hover one on the Mac for the same card as a tooltip. Interactive charts only.
    var peeksMarkers: Bool = false
    /// Whether a stretch of the chart can be picked out for its figures (`ChartSpanStats`): rest
    /// two fingers on the chart and drag them, and a band covers the span with a small card of its
    /// average, lowest, highest, time in range and change, gone when the fingers lift. VoiceOver
    /// swipes up and down through spans ending at the newest reading instead (`ChartSpanVoiceOver`).
    /// iPhone Today only; interactive charts only.
    var selectsSpans: Bool = false
    /// Opens an entry in the Logbook. Given, a tap (iPhone) or click (Mac) on a logged marker opens
    /// a small callout springing out of it (`MarkerCallout`): what it was, the amount, when, any
    /// note, and an Open in Logbook button that calls this. A tap elsewhere on the chart or Esc
    /// closes it. VoiceOver reads each marker as a button. iPhone Today and the Mac popover;
    /// interactive charts only.
    var openInLogbook: ((UUID) -> Void)? = nil
    /// Bump to close an open callout from outside, e.g. Esc while the chart around it has focus.
    var closesCallout: Int = 0
    /// Whether the scrub line snaps onto a logged marker or a day's lowest or highest reading when
    /// the finger (or pointer) comes within a few points of it (`ScrubSnap`), with a light tap on
    /// iPhone and one VoiceOver line. Instant under Reduce Motion. iPhone Today and the Mac popover;
    /// interactive charts only.
    var snapsScrub: Bool = false
    /// Does what's picked on a marker's peek card (`MarkerActions`): Edit or Log Again Now, for the
    /// entry with that id. Given, holding a marker on iPhone past the peek, or right-clicking one on
    /// the Mac (`pinsHoveredMarker`), opens its callout with those buttons, and VoiceOver offers it
    /// as an action on each marker. The card never logs anything by itself: only these buttons do.
    /// iPhone Today and the Mac popover; interactive charts only.
    var markerActions: ((MarkerActions.Action, UUID) -> Void)? = nil
    /// Mac: bump to open the peek card on the marker under the pointer, from a right-click the
    /// screen around the chart caught while `MarkerHoveredKey` said the pointer was on one.
    var pinsHoveredMarker: Int = 0
    /// What the forecast details card says (`ForecastDetails`). Given, while a forecast is drawn, a
    /// tap (iPhone) or click (Mac) on its dashed line or range opens the card as a popover growing
    /// out of that point, and VoiceOver offers "Show forecast details" on the chart. Only a tap that
    /// lands on the forecast and doesn't move: a scrub, a hold (the yesterday-line menu) and the
    /// markers' own touches are unchanged, and nothing snaps. iPhone Today and the Mac popover;
    /// interactive charts only.
    var forecastDetails: ForecastDetails? = nil
    /// Mac: bump to open the forecast details card from the keyboard (Return on the chart).
    var opensForecastDetails: Int = 0
    /// Explains gaps in readings (`ReadingGaps`). Given, the trace breaks wherever readings stop for
    /// 10 minutes or more, a dashed grey bridge joins the ends (drawn in once), and a tap on iPhone
    /// or the pointer resting on it on the Mac says why. VoiceOver hears one line in the summary.
    /// iPhone Today and the Mac popover; interactive charts only.
    var gapContext: ReadingGaps.Context? = nil
    /// "Check now" on the newest gap's card when it says no signal or can't connect
    /// (`ReadingGapCheck`): the store's state and what a tap runs. Nil (followers): no button.
    var gapCheck: ReadingGapCheck.Control? = nil
    /// Whether the chart can be panned back to earlier hours (`ChartPan`): drag along the time
    /// axis under the chart, or (Mac) swipe sideways with two fingers on the trackpad, which the
    /// screen around it passes in as `panScroll`. While panned the forecast is hidden, a Now button
    /// springs back to the newest reading (a cross-fade under Reduce Motion), and the screen
    /// around it hears where the right edge is (`ChartPanKey`). VoiceOver swipes the time axis up
    /// and down instead. Hand it `ChartPan.hoursHanded` of readings. iPhone Today and the Mac
    /// popover; interactive charts only.
    var pansBack: Bool = false
    /// Mac: sideways trackpad scrolling over the chart, from the popover's own monitor.
    var panScroll: ChartPanScroll? = nil
    /// Mac: ⌥← ⌥→ and ⌘→ while the chart has the keyboard focus, from the screen around it
    /// (`ChartPan.KeyMove`). Each new `id` moves the pan once, with the same glide as Now.
    var panKey: ChartPanKeyPress? = nil
    /// Whether logged markers get a short label beside them ("45 g", "4 u") once the chart is
    /// zoomed in far enough for them to have room (`MarkerLabels`). They fade in and out as the
    /// hours change, static under Reduce Motion; a label that would cover another, or another
    /// marker, is left out. Drawing only: VoiceOver and every touch are unchanged. iPhone Today and
    /// the Mac popover; interactive charts only.
    var labelsMarkers: Bool = false

    /// The gap whose card is showing, after a tap (iPhone) or while the pointer is on it (Mac).
    @State private var openGap: Date?

    @State private var hoverDate: Date?
    /// What Charts' two-finger range selection last reported, armed or not.
    @State private var rawSpan: ClosedRange<Date>?
    /// The two-finger touch while it's deciding whether it's a span or a pinch (`ChartSpanHold`).
    @State private var spanTouch: SpanTouch?
    /// The span shown, once the touch has armed. Nil while it's still deciding, or was a pinch.
    @State private var span: ClosedRange<Date>?
    /// Counts two-finger touches, so a hold timer from one that's lifted never arms a later one.
    @State private var spanGeneration = 0
    /// VoiceOver's chosen span, in minutes back from the newest reading. Nil: the chart's summary.
    @State private var voSpanMinutes: Int?
    /// The marker being peeked at, while a finger holds it (iPhone) or the pointer is over it (Mac).
    @State private var peeked: UUID?
    /// Whether a finger is down on a marker, before or during a peek. The yesterday-line menu
    /// stands down meanwhile (`MarkerPeekPressKey`), so holding a marker never opens it.
    @State private var pressingMarker = false
    /// The marker whose callout is open, after a tap or click on it (`MarkerCallout`).
    @State private var callout: UUID?
    /// What the open callout shows: the details a tap opens, or the peek card's actions.
    @State private var calloutStyle: MarkerActions.Style = .details
    /// The marker under the pointer (Mac), whatever else is showing, for a right-click's card.
    @State private var hoveredMarker: UUID?
    /// VoiceOver moves onto an open callout, so what was logged is read straight away.
    @AccessibilityFocusState private var calloutVoiceOverFocus: Bool
    #if os(macOS)
    /// The open callout takes keyboard focus on the Mac, so Esc closes it.
    @FocusState private var calloutKeyFocus: Bool
    #endif
    /// Whether a finger (or the pointer) is on the chart, as opposed to the readout gliding back
    /// to the newest reading after a scrub, which mustn't tick.
    @State private var touching = false
    /// The reading the scrub was last on while touching, so the next one knows what it passed.
    @State private var scrubbedFrom: Date?
    @State private var scrubTick = ScrubTickTrigger()
    /// Counts touches, so a snap-back still finishing never clears a scrub that started after it.
    @State private var touchGeneration = 0
    /// What the scrub is snapped onto right now (`ScrubSnap`), if anything.
    @State private var snapped: ScrubSnap.Target?
    /// The last thing it snapped onto in this touch, kept after letting go: the snap already
    /// ticked for that marker, so passing it again on the way out doesn't tick a second time.
    @State private var lastSnap: ScrubSnap.Target?
    /// What VoiceOver has been told about in this touch, so each snapped point is said once.
    @State private var spokenSnaps: [ScrubSnap.Target] = []
    /// Where the finger came down, until it has moved far enough to snap (`ScrubSnap.arms`).
    /// Nil once it has, so the rest of the touch snaps.
    @State private var snapStart: Date?
    /// The plot area's width, for how many seconds one point of the time axis covers.
    @State private var plotWidth: Double = 0
    /// The span on screen while `hours` changes (app screens only; `nil` follows `hours`, which is
    /// all a widget ever does since it never runs `onAppear`). See `ChartSpanTransition`.
    @State private var range: ChartSpanTransition?
    /// Bumped when the span switches under Reduce Motion, so the chart cross-fades from the old
    /// span to the new one instead of moving its axes.
    @State private var spanFade = 0
    /// The markers as the chart last saw them, so it can tell which are new or gone. `nil` until the
    /// chart appears: what's there when it opens is already there, and never pops.
    @State private var seenMarkers: [ChartLogMarker]?
    /// Markers popping in or shrinking out right now, drawn over the chart until they settle.
    @State private var flights: [MarkerFlight] = []
    /// Markers logged from outside the Logbook (Siri, a control, an alert, a widget), each with
    /// its one soft ring and caption the first time this chart shows it (`LoggedElsewhere`).
    @State private var glows: [MarkerGlow] = []
    /// Between `onAppear` and `onDisappear`. A Mac popover that's closed keeps its chart, so a
    /// highlight waits for it to open again rather than playing where no one can see it.
    @State private var onScreen = false
    /// Bumped once per newly arrived reading that ripples (`ripplesNewReading`). The ring's phase
    /// animator plays once per change and is hidden in between.
    @State private var rippleBeat = 0
    /// Whether the forecast details card is open (`forecastDetails`).
    @State private var forecastOpen = false
    /// The forecast card is playing its close (`ForecastCardEntrance`) before the popover goes.
    @State private var forecastClosing = false
    @State private var forecastCloseTask: Task<Void, Never>?
    /// Where on the forecast it was tapped, for the point the card grows out of. Nil: opened by
    /// VoiceOver or the keyboard, which use the 30-minute point.
    @State private var forecastTapped: Date?
    /// The right edge while panned back (`ChartPan`); nil follows the newest reading.
    @State private var panEnd: Date?
    /// Where the right edge was when the current drag or scroll began. Nil between them.
    @State private var panFrom: Date??
    /// While the axis glides between two pans (or home to now), what was on screen before, kept
    /// plotted until the glide ends so the readings slide through.
    @State private var panTrail: ClosedRange<Date>?
    @State private var panGeneration = 0
    /// The end VoiceOver last read the time label for (`ChartPan.announces`), so it's read once.
    @State private var panSpokenEnd: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// The real reading nearest the pointer. Only actual readings are ever shown, never an
    /// interpolated value between two of them. Over a gap in the data (sensor warm-up, phone out
    /// of signal) nothing is shown, rather than a reading from well before or after the pointer.
    private func nearest(to date: Date?, in window: [GlucoseReading]) -> GlucoseReading? {
        guard let date else { return nil }
        let distance = { (r: GlucoseReading) in abs(r.timestamp.timeIntervalSince(date)) }
        guard let best = window.min(by: { distance($0) < distance($1) }), distance(best) <= 10 * 60 else { return nil }
        return best
    }

    /// Readings kept past the left edge so they slide off it. Only charts that move need them.
    private var lead: TimeInterval { interactive ? ChartSpan.lead : 0 }

    /// What's on screen and what's drawn, for the span currently shown.
    private var chartWindow: ChartSpan? {
        let r = range ?? ChartSpanTransition(hours: hours)
        return ChartSpan(readings: readings, domainHours: r.domainHours, dataHours: r.dataHours,
                           forecastEnd: forecast.last?.date, lead: lead, pannedTo: shownPan, keepPlotted: panTrail)
    }

    /// The pan in force, kept within bounds for the readings and span there are now.
    private var shownPan: Date? {
        guard pansBack, interactive, let newest = readings.last?.timestamp, let oldest = readings.first?.timestamp
        else { return nil }
        return ChartPan.clamped(panEnd, newest: newest, oldest: oldest, hours: (range ?? .init(hours: hours)).domainHours)
    }

    /// The glucose axis fits what's on screen at the span being shown (and the few readings just
    /// past the left edge, so they never poke out of the top or bottom as they leave). Extra data
    /// plotted only while the range changes doesn't count, so the axis rescales in the same
    /// movement as the time axis.
    private func yDomainMgdl(_ onScreen: ArraySlice<GlucoseReading>, extra: [Double]) -> ClosedRange<Double> {
        let values = onScreen.map(\.mgdl) + [lowMgdl, highMgdl] + (shownPan == nil ? forecast.map(\.mgdl) : []) + extra
        let lo = min(values.min() ?? 60, 60) - 10
        let hi = max(values.max() ?? 200, 200) + 10
        return lo...hi
    }

    private func yDomain(_ onScreen: ArraySlice<GlucoseReading>, extra: [Double] = []) -> ClosedRange<Double> {
        let mg = yDomainMgdl(onScreen, extra: extra)
        return unit.value(fromMgdl: mg.lowerBound)...unit.value(fromMgdl: mg.upperBound)
    }

    /// A new span: plot what both ends of the move need, spring the axes to it, then drop what's
    /// off screen. Under Reduce Motion nothing moves: the old span cross-fades into the new one.
    private func changeRange(from old: Double, to new: Double) {
        var r = range ?? ChartSpanTransition(hours: old)
        guard interactive else {
            r.jump(to: new)
            withTransaction(Transaction(animation: nil)) { range = r }
            return
        }
        guard !reduceMotion else {
            r.jump(to: new)
            withAnimation(Self.spanFadeAnimation) {
                range = r
                spanFade += 1
            }
            return
        }
        r.prepare(for: new)
        let generation = r.generation
        withTransaction(Transaction(animation: nil)) { range = r }
        // On the next turn, so the extra readings are already in place (unseen, past the left
        // edge) when the axis starts moving, and slide in rather than fading in.
        DispatchQueue.main.async {
            withAnimation(Self.spanSpring, completionCriteria: .logicallyComplete) {
                range?.move(to: new)
            } completion: {
                withTransaction(Transaction(animation: nil)) { range?.settle(generation: generation) }
            }
        }
    }

    /// Switching 3h / 6h / 12h / 24h: a spring, so the trace stretches or squeezes to the new
    /// scale and settles, rather than easing to a stop. `.logicallyComplete` lets the trim at the
    /// end run before the last imperceptible settle.
    static let spanSpring = DSMotion.emphasized.animation
    /// The same switch under Reduce Motion: a short cross-fade with no movement.
    static let spanFadeAnimation = Animation.easeInOut(duration: 0.25)

    /// What Charts' selection reads and writes. Lifting the finger glides the readout back to the
    /// newest reading and fades it there, rather than dropping it wherever the finger was.
    private func selection(newest: Date?, snaps: [ScrubSnap.Target], secondsPerPoint: Double) -> Binding<Date?> {
        Binding(get: { hoverDate }, set: { new in
            if let new {
                // A peek has the finger, or two fingers are picking a span: the readout stays
                // away until they lift.
                // A scrub starting while a callout is open only closes it. Not while the finger that
                // held a marker into its peek card is still down on it: lifting leaves the card open.
                if callout != nil {
                    if !pressingMarker { closeCallout() }
                    return
                }
                guard peeked == nil, span == nil, spanTouch == nil else { return }
                #if os(iOS)
                if openGap != nil { withAnimation(ReadingGapCard.animation(reduceMotion)) { openGap = nil } }
                #endif
                if !touching { touching = true; scrubbedFrom = nil; resetSnap(); snapStart = new }
                touchGeneration += 1
                moveScrub(to: new, snaps: snaps, secondsPerPoint: secondsPerPoint)
            } else {
                release(newest: newest)
            }
        })
    }

    /// The finger's off the chart. iPhone glides the readout to the newest reading, then fades it;
    /// under Reduce Motion, on the Mac (the pointer leaving), or when it's already there, it goes.
    private func release(newest: Date?) {
        touching = false
        scrubbedFrom = nil
        resetSnap()
        touchGeneration += 1
        let generation = touchGeneration
        #if os(iOS)
        let glides = !reduceMotion && newest != nil && hoverDate != nil
        #else
        let glides = false
        #endif
        guard glides, let newest else {
            withTransaction(Transaction(animation: nil)) { hoverDate = nil }
            return
        }
        withAnimation(DSMotion.standard.animation, completionCriteria: .logicallyComplete) {
            hoverDate = newest
        } completion: {
            guard touchGeneration == generation else { return }
            withAnimation(DSMotion.quick.animation) { hoverDate = nil }
        }
    }

    // MARK: Scrub snapping

    /// Moves the scrub to the finger, or onto what it's snapped to (`ScrubSnap`). Landing on
    /// something taps once on iPhone and tells VoiceOver what it is, once per touch. The jump
    /// onto it (and off again) is a quick glide, instant under Reduce Motion.
    private func moveScrub(to finger: Date, snaps: [ScrubSnap.Target], secondsPerPoint: Double) {
        guard snapsScrub else { hoverDate = finger; return }
        // A tap or a hold on a marker has its own tap: nothing snaps until the finger has moved.
        if let start = snapStart {
            guard ScrubSnap.arms(start: start, finger: finger, secondsPerPoint: secondsPerPoint) else {
                hoverDate = finger
                return
            }
            snapStart = nil
        }
        let next = ScrubSnap.snap(finger: finger, targets: snaps, current: snapped, secondsPerPoint: secondsPerPoint)
        guard next != snapped else {
            if next == nil { hoverDate = finger }
            return
        }
        let animation: Animation? = reduceMotion ? nil : DSMotion.quick.animation
        withTransaction(Transaction(animation: animation)) {
            snapped = next
            hoverDate = next?.date ?? finger
        }
        guard let next else { return }
        lastSnap = next
        #if os(iOS)
        scrubTick.fire(ScrubTickTrigger.Kind.snapped)
        #endif
        guard !spokenSnaps.contains(next) else { return }
        spokenSnaps.append(next)
        var spoken = AttributedString(ScrubSnap.spoken(next, unit: unit, now: Date()))
        spoken.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(spoken).post()
    }

    private func resetSnap() {
        snapStart = nil
        snapped = nil
        lastSnap = nil
        spokenSnaps = []
    }

    /// What the scrub can snap onto: the markers on screen with a reading near them (the readout
    /// shows only real readings), and each day's lowest and highest reading on screen.
    private func snapTargets(window: [GlucoseReading]) -> [ScrubSnap.Target] {
        guard snapsScrub, interactive, let first = window.first?.timestamp, let last = window.last?.timestamp else { return [] }
        let logged = peekable(window)
            .filter { nearest(to: $0.date, in: window) != nil }
            .map { ScrubSnap.Logged(id: $0.id, date: $0.date, label: $0.label) }
        return ScrubSnap.targets(logged: logged, readings: readings, visible: first...last)
    }

    // MARK: Span stats

    /// What Charts' range selection (two fingers on iPhone) reads and writes.
    private var spanSelection: Binding<ClosedRange<Date>?> {
        Binding(get: { rawSpan }, set: { spanChanged($0) })
    }

    /// The fingers moved, landed or lifted. A new touch waits `ChartSpanHold.holdDuration` before it
    /// can become a span; if the gap between the fingers changes much before then, it was a pinch.
    private func spanChanged(_ new: ClosedRange<Date>?) {
        guard let new else { endSpanTouch(); return }
        rawSpan = new
        let width = new.upperBound.timeIntervalSince(new.lowerBound)
        if span != nil {
            withTransaction(Transaction(animation: nil)) { span = new }
            return
        }
        if var touch = spanTouch {
            if !touch.wasPinch, ChartSpanHold.isPinch(firstWidth: touch.firstWidth, currentWidth: width) {
                touch.wasPinch = true
                spanTouch = touch
            }
            return
        }
        spanGeneration += 1
        let generation = spanGeneration
        spanTouch = SpanTouch(firstWidth: width)
        DispatchQueue.main.asyncAfter(deadline: .now() + ChartSpanHold.holdDuration) {
            armSpan(generation: generation)
        }
    }

    /// The fingers have rested long enough: if they still mean a span, show it, with a light tap.
    private func armSpan(generation: Int) {
        guard generation == spanGeneration, let touch = spanTouch, let raw = rawSpan, span == nil,
              ChartSpanHold.arms(held: ChartSpanHold.holdDuration, firstWidth: touch.firstWidth,
                                 currentWidth: raw.upperBound.timeIntervalSince(raw.lowerBound),
                                 wasPinch: touch.wasPinch)
        else { return }
        withTransaction(Transaction(animation: nil)) {
            hoverDate = nil
            touching = false
            scrubbedFrom = nil
            voSpanMinutes = nil
        }
        withAnimation(ChartSpanCard.animation(showing: true, reduceMotion: reduceMotion)) { span = raw }
        #if os(iOS)
        Haptics.play(.spanPicked)
        #endif
    }

    /// The fingers lifted: the band and card fade away.
    private func endSpanTouch() {
        spanGeneration += 1
        spanTouch = nil
        rawSpan = nil
        guard span != nil else { return }
        withAnimation(ChartSpanCard.animation(showing: false, reduceMotion: reduceMotion)) { span = nil }
    }

    /// The span VoiceOver has chosen, ending at the newest reading.
    private func voiceOverSpan(newest: Date?) -> ClosedRange<Date>? {
        guard let minutes = voSpanMinutes else { return nil }
        let end = newest ?? Date()
        return end.addingTimeInterval(-Double(minutes) * 60)...end
    }

    /// VoiceOver swiped up (a longer span) or down (a shorter one, then back to the summary).
    private func adjustVoiceOverSpan(_ direction: AccessibilityAdjustmentDirection) {
        let up: Bool
        switch direction {
        case .increment: up = true
        case .decrement: up = false
        @unknown default: return
        }
        let next = ChartSpanVoiceOver.step(voSpanMinutes, up: up, hours: hours)
        guard next != voSpanMinutes else { return }
        withAnimation(ChartSpanCard.animation(showing: next != nil, reduceMotion: reduceMotion)) { voSpanMinutes = next }
    }

    /// The band over the span and the card with its figures, while a span is shown.
    @ViewBuilder
    private func spanOverlay(proxy: ChartProxy, window: [GlucoseReading]) -> some View {
        if selectsSpans, interactive, let shown = span ?? voiceOverSpan(newest: window.last?.timestamp) {
            ChartSpanBand(proxy: proxy, range: shown)
                .transition(.opacity)
            ChartSpanCard(proxy: proxy, range: shown, unit: unit, reduceMotion: reduceMotion,
                          stats: ChartSpanStats.compute(readings: window, from: shown.lowerBound, to: shown.upperBound,
                                                        lowMgdl: lowMgdl, highMgdl: highMgdl))
                .transition(ChartSpanCard.transition(reduceMotion: reduceMotion))
        }
    }

    /// The scrub landed on another reading: tick if it crossed a range edge or something logged.
    private func scrubbed(to date: Date?, readings window: [GlucoseReading]) {
        guard touching, let date else { return }
        // A marker the scrub snapped onto already ticked when it landed; passing it on the way
        // off doesn't tick again.
        let snappedMarkers = [snapped, lastSnap].compactMap { t -> Date? in
            guard let t, case .logged = t.kind else { return nil }
            return t.date
        }
        if let from = scrubbedFrom,
           let tick = ChartScrub.tick(from: from, to: date, readings: window, lowMgdl: lowMgdl,
                                      highMgdl: highMgdl,
                                      logged: events.map(\.date).filter { !snappedMarkers.contains($0) }) {
            scrubTick.fire(tick)
        }
        scrubbedFrom = date
    }

    /// The logged markers changed: pop in the new ones and shrink out the ones that went, if they're
    /// on screen, and say so. Markers sliding off the left edge as time passes aren't deletions, and
    /// a whole logbook arriving at once changes silently (`MarkerPop.burstLimit`).
    private func markersChanged(visibleFrom start: Date) {
        guard popsMarkers, interactive, let old = seenMarkers else { return }
        seenMarkers = events
        let change = MarkerPop.change(from: old.map(\.id), to: events.map(\.id))
        LoggedElsewhere.shared.forget(change.removed)
        guard change.animates else {
            // A burst arriving at once changes silently, but an entry logged from elsewhere in it
            // still gets its highlight.
            glowLoggedElsewhere(events.filter { change.added.contains($0.id) && $0.date >= start }, pop: nil)
            return
        }
        let added = events.filter { change.added.contains($0.id) && $0.date >= start }
        let removed = old.filter { change.removed.contains($0.id) && $0.date >= start }
        guard !(added.isEmpty && removed.isEmpty) else { return }
        let pop = MarkerPop.announcement(added: added.compactMap(\.kind), removed: removed.compactMap(\.kind))
        if !glowLoggedElsewhere(added, pop: pop), let pop {
            // Low priority, so it waits for "Saved" or "Deleted" from the sheet or toast to finish.
            var spoken = AttributedString(pop)
            spoken.accessibilitySpeechAnnouncementPriority = .low
            AccessibilityNotification.Announcement(spoken).post()
        }
        guard !reduceMotion else { return }
        // Undo while it's still shrinking out (or a delete while it's still popping): the newer
        // movement takes over from where the marker is.
        let touched = Set(added.map(\.id) + removed.map(\.id))
        var next = flights.filter { !touched.contains($0.marker.id) }
        next += added.map { MarkerFlight(marker: $0, leaving: false) }
        next += removed.map { MarkerFlight(marker: $0, leaving: true) }
        withTransaction(Transaction(animation: nil)) { flights = next }
    }

    /// Starts the ring and caption on any of `markers` logged from elsewhere and not yet shown on
    /// this chart. VoiceOver hears it once, folded into the pop's own line when there is one. True
    /// when it said something, so the caller doesn't say the pop line again.
    @discardableResult
    private func glowLoggedElsewhere(_ markers: [ChartLogMarker], pop: String?) -> Bool {
        guard onScreen else { return false }
        var spoke = false
        for m in markers {
            guard let h = LoggedElsewhere.shared.take(m.id, on: .chart) else { continue }
            glows.removeAll { $0.marker.id == m.id }
            glows.append(MarkerGlow(marker: m, origin: h.origin, delay: h.delay))
            if h.announces, !spoke {
                LoggedElsewhere.announce(LoggedElsewhereMarks.chartSpoken(h.origin, pop: pop))
                spoke = true
            }
        }
        return spoke
    }

    /// Markers popping in or shrinking out, and the rings on ones logged from elsewhere. The chart
    /// leaves a popping marker out until it lands, then draws it in the same place, so the
    /// hand-over can't be seen.
    @ViewBuilder
    private func markerOverlays(proxy: ChartProxy, yd: ClosedRange<Double>) -> some View {
        ForEach(flights) { flight in
            MarkerFlightView(proxy: proxy, flight: flight, value: markerY(lane: flight.marker.lane, yd: yd)) {
                landed(flight)
            }
        }
        ForEach(glows) { glow in
            LoggedElsewhereMarkerGlow(proxy: proxy, date: glow.marker.date,
                                      value: markerY(lane: glow.marker.lane, yd: yd),
                                      tint: glow.marker.tint, origin: glow.origin, delay: glow.delay) {
                glows.removeAll { $0.id == glow.id }
            }
        }
    }

    /// Short amounts beside the markers on screen once zoomed in (`MarkerLabels`). Markers still
    /// popping in get theirs once they land.
    private func markerLabels(proxy: ChartProxy, yd: ClosedRange<Double>, window: [GlucoseReading],
                              domain: ClosedRange<Date>) -> some View {
        MarkerLabelLayer(proxy: proxy, markers: peekable(window),
                         spanHours: domain.upperBound.timeIntervalSince(domain.lowerBound) / 3600,
                         hours: hours, newest: readings.last?.timestamp, reduceMotion: reduceMotion) { lane in
            markerY(lane: lane, yd: yd)
        }
    }

    /// The markers that can be peeked at: on screen and not still popping in.
    private func peekable(_ window: [GlucoseReading]) -> [ChartLogMarker] {
        let start = window.first?.timestamp ?? .distantFuture
        let inFlight = Set(flights.map(\.marker.id))
        return events.filter { $0.date >= start && !inFlight.contains($0.id) }
    }

    /// Whether a tap on a marker opens its callout.
    private var opensCallouts: Bool { interactive && openInLogbook != nil }

    /// Whether a long hold (iPhone) or right-click (Mac) on a marker opens its peek card.
    private var opensActionCards: Bool { interactive && markerActions != nil }

    /// The layer that finds a held (iPhone) or hovered (Mac) marker, and the card over it. With
    /// callouts on, it also finds a tapped or clicked one.
    @ViewBuilder
    private func markerPeek(proxy: ChartProxy, yd: ClosedRange<Double>, window: [GlucoseReading]) -> some View {
        let markers = peekable(window)
        let placed = markers.map { (marker: $0, value: markerY(lane: $0.lane, yd: yd)) }
        if callout != nil {
            // Under the markers, over the rest of the chart: a tap anywhere else closes the
            // callout and does nothing more.
            MarkerCalloutDismissLayer(close: closeCallout)
        }
        MarkerPeekLayer(proxy: proxy, markers: placed,
                        pressing: { pressingMarker = $0 }, peek: setPeek,
                        tap: opensCallouts ? { tapMarker($0) } : nil,
                        pin: opensActionCards ? { pinMarker($0) } : nil,
                        hovering: { if hoveredMarker != $0 { hoveredMarker = $0 } })
        if peeksMarkers, let id = peeked, let marker = markers.first(where: { $0.id == id }) {
            MarkerPeekCard(proxy: proxy, marker: marker, value: markerY(lane: marker.lane, yd: yd),
                           detail: MarkerPeek.detail(date: marker.date, now: Date(), readings: window, unit: unit))
                .id(id)
                .transition(MarkerPeekCard.transition(reduceMotion: reduceMotion))
        }
    }

    /// A peek starts or ends. Starting one clears the scrub readout; on iPhone it ticks once.
    private func setPeek(_ id: UUID?) {
        guard peeksMarkers, id != peeked else { return }
        if id != nil, callout != nil {
            #if os(iOS)
            // A hold peeks as before; the open callout makes way.
            closeCallout()
            #else
            // Hovering while a callout is open shows nothing more.
            return
            #endif
        }
        if id != nil {
            withTransaction(Transaction(animation: nil)) {
                hoverDate = nil
                touching = false
                scrubbedFrom = nil
            }
            #if os(iOS)
            Haptics.play(.scrubLogged)
            #endif
        }
        withAnimation(MarkerPeekCard.animation(showing: id != nil, reduceMotion: reduceMotion)) { peeked = id }
    }

    // MARK: Marker callout

    /// A tap (iPhone) or click (Mac) on a marker: its callout opens, moves to it from another
    /// marker, or closes when it was already open (`MarkerCallout.toggled`), whichever it showed.
    private func tapMarker(_ id: UUID) {
        guard let next = MarkerCallout.toggled(open: callout, tapped: id) else { closeCallout(); return }
        openCallout(next, style: .details)
    }

    /// A hold past the peek (iPhone) or a right-click (Mac) on a marker: its peek card, with Edit
    /// and Log Again Now (`MarkerActions`). Doing it again on the open card leaves it open.
    private func pinMarker(_ id: UUID) {
        guard opensActionCards, callout != id || calloutStyle != .actions else { return }
        openCallout(id, style: .actions)
    }

    /// Opens the callout on `next` as `style`. A peek showing makes way as the card grows out of
    /// the same marker, so a held peek turns into the card rather than blinking out first.
    private func openCallout(_ next: UUID, style: MarkerActions.Style) {
        let fromPeek = peeked != nil
        closeForecast(animated: false)
        withTransaction(Transaction(animation: nil)) {
            hoverDate = nil
            touching = false
            scrubbedFrom = nil
            if !fromPeek { peeked = nil }
        }
        #if os(iOS)
        Haptics.play(style == .actions ? .choice : .scrubLogged)
        #endif
        withAnimation(MarkerCalloutMotion.animation(showing: true, reduceMotion: reduceMotion)) {
            peeked = nil
            calloutStyle = style
            callout = next
        }
        // Once it's in place, VoiceOver reads it, and on the Mac it takes the keyboard for Esc.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard callout == next else { return }
            calloutVoiceOverFocus = true
            #if os(macOS)
            calloutKeyFocus = true
            #endif
        }
    }

    /// Mac: a right-click the screen caught over a marker.
    private func pinHoveredMarker() {
        guard let id = hoveredMarker else { return }
        pinMarker(id)
    }

    /// A button on the peek card. Edit goes at once, as the log sheet opens over it; Log Again Now
    /// puts the card away and lets the new marker pop in, and VoiceOver hears it was logged.
    private func act(_ action: MarkerActions.Action, on marker: ChartLogMarker) {
        switch action {
        case .edit:
            withTransaction(Transaction(animation: nil)) { callout = nil }
            calloutVoiceOverFocus = false
            #if os(macOS)
            calloutKeyFocus = false
            #endif
        case .logAgainNow:
            closeCallout()
            var spoken = AttributedString(MarkerActions.loggedAgain(kind: marker.kind, at: Date()))
            spoken.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(spoken).post()
        }
        markerActions?(action, marker.id)
    }

    private func closeCallout() {
        guard callout != nil else { return }
        withAnimation(MarkerCalloutMotion.animation(showing: false, reduceMotion: reduceMotion)) { callout = nil }
        calloutVoiceOverFocus = false
        #if os(macOS)
        calloutKeyFocus = false
        #endif
    }

    /// Open in Logbook: the callout goes at once, without its own animation, as the Logbook opens.
    private func openCalloutEntry(_ id: UUID) {
        withTransaction(Transaction(animation: nil)) { callout = nil }
        openInLogbook?(id)
    }

    /// VoiceOver's marker buttons and the open callout. A second chart overlay, added after the
    /// chart's own single VoiceOver element, so these are elements of their own rather than folded
    /// into its summary.
    @ViewBuilder
    private func calloutLayer(proxy: ChartProxy, yd: ClosedRange<Double>, window: [GlucoseReading]) -> some View {
        if opensCallouts || opensActionCards {
            let markers = peekable(window).filter { $0.callout != nil }
            GeometryReader { geo in
                if let plotFrame = proxy.plotFrame {
                    let plot = geo[plotFrame]
                    let point = { (m: ChartLogMarker) -> CGPoint? in
                        guard let x = proxy.position(forX: m.date),
                              let y = proxy.position(forY: markerY(lane: m.lane, yd: yd)) else { return nil }
                        return CGPoint(x: plot.minX + x, y: plot.minY + y)
                    }
                    ForEach(markers) { m in
                        if let p = point(m), let content = m.callout {
                            MarkerVoiceOverButton(label: MarkerCallout.spoken(content, date: m.date),
                                                  open: callout == m.id, opensDetails: opensCallouts,
                                                  showActions: opensActionCards ? { pinMarker(m.id) } : nil) {
                                if opensCallouts { tapMarker(m.id) } else { pinMarker(m.id) }
                            }
                                .position(p)
                        }
                    }
                    if let id = callout, let m = markers.first(where: { $0.id == id }), let content = m.callout,
                       let p = point(m) {
                        calloutCard(m, content: content, marker: p, plot: plot)
                    }
                }
            }
        }
    }

    /// The card over its marker, kept inside the plot, growing out of the marker.
    @ViewBuilder
    private func calloutCard(_ m: ChartLogMarker, content: MarkerCallout.Content, marker: CGPoint, plot: CGRect) -> some View {
        let width = MarkerCalloutMotion.width
        let cx = MarkerCallout.centerX(markerX: Double(marker.x), plotMinX: Double(plot.minX),
                                       plotMaxX: Double(plot.maxX), width: Double(width))
        let grow = UnitPoint(x: MarkerCallout.anchorX(markerX: Double(marker.x), centerX: cx, width: Double(width)), y: 1)
        // Its bottom edge just above the marker, so the finger doesn't cover it.
        let bottom = max(marker.y - 14, 0)
        MarkerCalloutCard(marker: m, content: content, time: MarkerCallout.timeLine(m.date, now: Date()),
                          voiceOverFocus: $calloutVoiceOverFocus,
                          actions: calloutStyle == .actions ? MarkerActions.actions(for: m.kind) : nil,
                          open: { openCalloutEntry(m.id) }, act: { act($0, on: m) }, close: closeCallout)
            .calloutKeyFocus(calloutKeyFocusBinding)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, height: bottom, alignment: .bottom)
            .transition(MarkerCalloutMotion.transition(growingFrom: grow, reduceMotion: reduceMotion))
            .position(x: CGFloat(cx), y: bottom / 2)
            .id(m.id)
    }

    #if os(macOS)
    private var calloutKeyFocusBinding: FocusState<Bool>.Binding? { $calloutKeyFocus }
    /// On the Mac, a click elsewhere in the popover (or another window) takes focus from the open
    /// callout, which closes it. Only once it had focus: a callout that never got it stays.
    private var calloutKeyFocusChanged: Bool? { calloutKeyFocus }
    #else
    private var calloutKeyFocusBinding: FocusState<Bool>.Binding? { nil }
    private var calloutKeyFocusChanged: Bool? { nil }
    #endif

    /// The open callout's marker went (deleted, slid off the left edge, the span changed).
    private func calloutMarkersChanged(_ ids: [UUID]) {
        if let id = callout, !ids.contains(id) { closeCallout() }
    }

    private func appeared(visibleFrom start: Date) {
        if interactive, range == nil { range = ChartSpanTransition(hours: hours) }
        onScreen = true
        guard popsMarkers, interactive else { return }
        if seenMarkers == nil { seenMarkers = events }
        // What's there when the chart opens doesn't pop, but an entry logged from elsewhere while
        // it was away (the Mac's shortcut, Siri) still gets its one highlight.
        glowLoggedElsewhere(events.filter { $0.date >= start }, pop: nil)
    }

    /// A newer reading has landed: the current-reading dot ripples once if it should.
    private func newestChanged(from old: Date?, to new: Date?) {
        guard ripplesNewReading, interactive else { return }
        #if os(iOS)
        let appActive = scenePhase == .active
        #else
        // A menu bar popover can report inactive while it's open; only the background is ruled out.
        let appActive = scenePhase != .background
        #endif
        guard NewReadingRipple.plays(previous: old, newest: new, now: Date(), staleAfter: GlucoseSnapshot.staleAfter,
                                     appActive: appActive, onScreen: onScreen, reduceMotion: reduceMotion)
        else { return }
        rippleBeat &+= 1
    }

    /// What VoiceOver reads while it has a span chosen; nil otherwise.
    private func voiceOverSpanSentence(window: [GlucoseReading]) -> String? {
        guard selectsSpans, interactive, let minutes = voSpanMinutes,
              let range = voiceOverSpan(newest: window.last?.timestamp) else { return nil }
        let stats = ChartSpanStats.compute(readings: window, from: range.lowerBound, to: range.upperBound,
                                           lowMgdl: lowMgdl, highMgdl: highMgdl)
        return ChartSpanVoiceOver.spoken(stats, minutes: minutes, unit: unit)
    }

    private func disappeared() {
        voSpanMinutes = nil
        openGap = nil
        endSpanTouch()
        onScreen = false
        glows = []
        peeked = nil
        pressingMarker = false
        callout = nil
        hoveredMarker = nil
        // Opening again starts at now.
        panEnd = nil
        panFrom = nil
        panTrail = nil
        panSpokenEnd = nil
    }

    private func landed(_ flight: MarkerFlight) {
        withTransaction(Transaction(animation: nil)) { flights.removeAll { $0.id == flight.id } }
    }

    /// " Yesterday at this time: 6.2 millimoles per litre." while the line is shown and there was a
    /// reading then; otherwise nothing.
    private func yesterdaySpoken(newest: GlucoseReading?) -> String {
        guard !yesterday.isEmpty,
              let line = YesterdayLine.spoken(YesterdayLine.reading(at: newest?.timestamp ?? Date(), in: yesterday), unit: unit)
        else { return "" }
        return " " + line
    }

    /// `plotted` cut at each gap: one unbroken stretch per array (just one with no gaps).
    static func segments(_ plotted: [GlucoseReading], gaps: [ReadingGaps.Gap]) -> [[GlucoseReading]] {
        guard !gaps.isEmpty else { return [plotted] }
        let breaks = Set(gaps.map(\.end))
        var out: [[GlucoseReading]] = [[]]
        for r in plotted {
            if breaks.contains(r.timestamp), !(out.last?.isEmpty ?? true) { out.append([]) }
            out[out.count - 1].append(r)
        }
        return out
    }

    private func chartSummary(window: [GlucoseReading], stale: Bool, forecastEnd: ForecastSample?) -> String {
        let from = window.first?.timestamp ?? .distantFuture
        return ChartSummary.sentence(.init(
            readings: window, lowMgdl: lowMgdl, highMgdl: highMgdl, unit: unit, hours: hours, stale: stale,
            forecastEnd: forecastEnd, loggedCount: events.filter { $0.date >= from }.count))
    }

    /// The gaps among what's plotted, when this chart explains them.
    private func readingGaps(in plotted: [GlucoseReading]) -> [ReadingGaps.Gap] {
        guard interactive, let context = gapContext, let first = plotted.first else { return [] }
        // With the reading just before what's plotted, so a gap crossing the left edge keeps its
        // real start (its bridge runs in from off the edge).
        let i = ChartSpan.firstIndex(in: readings, atOrAfter: first.timestamp)
        let withLead = i > 0 ? [readings[i - 1]] + plotted : plotted
        return ReadingGaps.find(in: withLead, context: context)
    }

    /// Whether VoiceOver gets "Check now": the newest gap on the chart is one checking helps with.
    private func offersGapCheck(_ gaps: [ReadingGaps.Gap]) -> Bool {
        guard gapCheck != nil, let last = gaps.last else { return false }
        return ReadingGapCheck.offers(last, among: gaps)
    }

    private func gapCardShowing(_ gaps: [ReadingGaps.Gap]) -> Bool {
        guard let id = openGap else { return false }
        return gaps.contains { $0.id == id }
    }

    private func gapsSpoken(_ gaps: [ReadingGaps.Gap], visibleFrom: Date?) -> String {
        let from = visibleFrom ?? .distantFuture
        guard let line = ReadingGaps.spoken(gaps.filter { $0.end >= from }) else { return "" }
        return " " + line
    }

    /// Each stretch's gradient, stretched over that stretch, so its stops follow what's drawn.
    private func traceStyles(_ segments: [[GlucoseReading]]) -> [LinearGradient] {
        var out: [LinearGradient] = []
        for seg in segments {
            let values = seg.map(\.mgdl)
            out.append(ThresholdGradient.style(minMgdl: values.min() ?? lowMgdl, maxMgdl: values.max() ?? highMgdl,
                                               low: lowMgdl, high: highMgdl))
        }
        return out
    }

    private func color(for mgdl: Double) -> Color {
        GlucoseRange.classify(mgdl: mgdl, low: lowMgdl, high: highMgdl).color
    }

    var body: some View {
        let cw = chartWindow
        let window = Array(cw?.visible ?? [])
        let plotted = Array(cw?.plotted ?? [])
        // On screen at the span being shown, plus the lead past the left edge: not the extra
        // data plotted only while the span changes.
        let pan = shownPan
        let onScreen = ChartSpan(readings: readings, domainHours: (range ?? .init(hours: hours)).domainHours,
                                   dataHours: 0, forecastEnd: forecast.last?.date, lead: lead, pannedTo: pan)?.plotted ?? []
        // Yesterday's faint line, over what's plotted (and on under the forecast), so it moves with
        // the trace when the span changes. Its highs and lows count towards the glucose axis, so
        // it's never cut off at the top or bottom.
        let domain = cw?.domain ?? Date().addingTimeInterval(-hours * 3600)...Date()
        let ghost = yesterday.isEmpty ? [] : YesterdayLine.points(
            readings: yesterday, from: min(plotted.first?.timestamp ?? domain.lowerBound, domain.lowerBound),
            to: domain.upperBound)
        let yd = yDomain(onScreen, extra: ghost.map(\.mgdl))
        let floor = yd.lowerBound
        // Where readings stopped and started again, with why (`ReadingGaps`). The trace breaks at
        // each, so the dashed bridge over it is the only line there.
        let gaps: [ReadingGaps.Gap] = readingGaps(in: plotted)
        let segments: [[GlucoseReading]] = Self.segments(plotted, gaps: gaps)
        // A gap's card stands in for the readout while it shows.
        let gapCardOpen: Bool = gapCardShowing(gaps)
        // One line in VoiceOver's summary for the gaps that end on screen.
        let gapSpoken: String = gapsSpoken(gaps, visibleFrom: window.first?.timestamp)
        let readoutFree: Bool = interactive && peeked == nil && callout == nil && span == nil && !forecastOpen
        let hovered: GlucoseReading? = readoutFree && !gapCardOpen ? nearest(to: hoverDate ?? pinnedDate, in: window) : nil
        // The gradient is stretched over the drawn line, so its stops follow what's plotted.
        // With gaps, each unbroken stretch is its own line, with its own stops.
        let lineStyles: [LinearGradient] = traceStyles(segments)
        // The newest reading, not the newest on screen: panned back, the right edge isn't now.
        let stale = latestIsStale
            ?? (readings.last.map { Date().timeIntervalSince($0.timestamp) > GlucoseSnapshot.staleAfter } ?? true)
        let currentTint = stale ? Palette.stale : (window.last.map { color(for: $0.mgdl) } ?? Palette.stale)
        // The forecast belongs to now, so it's hidden while the chart is panned back.
        let projection = stale || pan != nil ? [] : forecast
        // What's drawn of it so far. Indexed rather than keyed by time, so the marks keep their
        // identity while a new forecast slides and bends into place (`ForecastMotion`).
        let drawn = Array(ForecastMorph.revealed(projection, progress: forecastReveal).enumerated())
        // What VoiceOver reads for the chart: a picked span, or the summary with yesterday and gaps.
        let spokenValue: String = panSpoken(pan) + (voiceOverSpanSentence(window: window)
            ?? chartSummary(window: window, stale: stale, forecastEnd: projection.last) + yesterdaySpoken(newest: window.last) + gapSpoken)
        let chart = Chart {
            // Target band, with hairline edges so it still reads in Increase Contrast.
            RectangleMark(
                yStart: .value("Low", unit.value(fromMgdl: lowMgdl)),
                yEnd: .value("High", unit.value(fromMgdl: highMgdl))
            )
            .foregroundStyle(GlucoseRange.inRange.tint.opacity(0.09))

            RuleMark(y: .value("Low", unit.value(fromMgdl: lowMgdl)))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                .foregroundStyle(GlucoseRange.inRange.tint.opacity(0.45))
            RuleMark(y: .value("High", unit.value(fromMgdl: highMgdl)))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                .foregroundStyle(GlucoseRange.inRange.tint.opacity(0.45))

            // Yesterday at the same clock time: thin, grey and behind everything, so it reads as
            // a reference and never as a reading. Broken where yesterday's readings were.
            ForEach(ghost) { p in
                LineMark(
                    x: .value("Time", p.date),
                    y: .value("Yesterday", unit.value(fromMgdl: p.mgdl)),
                    series: .value("Series", "Yesterday \(p.segment)")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Color.primary.opacity(0.2))
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }

            // The trace, its glow and its out-of-range fills, one stretch per unbroken run of readings.
            traceMarks(segments, styles: lineStyles, floor: floor, tint: currentTint)

            // The forecast: a neutral band and dashed line, so it can't be mistaken for readings.
            ForEach(drawn, id: \.offset) { _, p in
                AreaMark(
                    x: .value("Time", p.date),
                    yStart: .value("Forecast low", min(max(unit.value(fromMgdl: p.lowerMgdl), yd.lowerBound), yd.upperBound)),
                    yEnd: .value("Forecast high", min(max(unit.value(fromMgdl: p.upperMgdl), yd.lowerBound), yd.upperBound)),
                    series: .value("Series", "Forecast range")
                )
                .interpolationMethod(.monotone)
                // Fades as it reaches further ahead: the further out, the less it should be trusted.
                .foregroundStyle(
                    LinearGradient(colors: [Palette.stale.opacity(0.30), Palette.stale.opacity(0.08)],
                                   startPoint: .leading, endPoint: .trailing)
                )
            }
            ForEach(drawn, id: \.offset) { _, p in
                LineMark(
                    x: .value("Time", p.date),
                    y: .value("Forecast", unit.value(fromMgdl: p.mgdl)),
                    series: .value("Series", "Forecast")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Palette.stale)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 3]))
            }

            nowMark(last: projection.isEmpty ? nil : window.last)
            midnightMarks(plotted)
            eventMarks(plotted, yd: yd)

            // Current reading: solid dot with a soft halo. Not while panned back, where the last
            // reading on screen isn't the current one.
            if pan == nil, let last = window.last {
                PointMark(
                    x: .value("Time", last.timestamp),
                    y: .value("Glucose", unit.value(fromMgdl: last.mgdl))
                )
                .symbolSize(220)
                .foregroundStyle(currentTint.opacity(0.2))
                PointMark(
                    x: .value("Time", last.timestamp),
                    y: .value("Glucose", unit.value(fromMgdl: last.mgdl))
                )
                .symbolSize(70)
                .foregroundStyle(.white)
                PointMark(
                    x: .value("Time", last.timestamp),
                    y: .value("Glucose", unit.value(fromMgdl: last.mgdl))
                )
                .symbolSize(36)
                .foregroundStyle(currentTint)
            }

            if let h = hovered {
                RuleMark(x: .value("Time", h.timestamp))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(
                    x: .value("Time", h.timestamp),
                    y: .value("Glucose", unit.value(fromMgdl: h.mgdl))
                )
                .symbolSize(60)
                .foregroundStyle(color(for: h.mgdl))
                .annotation(position: .top, spacing: 6,
                            overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                    ChartReadout(reading: h, previous: Self.previous(to: h, in: window), unit: unit,
                                 range: GlucoseRange.classify(mgdl: h.mgdl, low: lowMgdl, high: highMgdl),
                                 yesterday: yesterday.isEmpty ? nil : YesterdayLine.reading(at: h.timestamp, in: yesterday))
                    .padding(.horizontal, DS.Space.sm)
                    .padding(.vertical, DS.Space.xs)
                    .background { DSSurface(style: .standard, radius: DS.Radius.control) }
                    .dsShadow(.medium)
                }
            }
        }
        // Both axes are set rather than worked out by Charts, so a change of span or a new
        // reading moves them (and the marks with them) instead of redrawing the chart.
        .chartXScale(domain: domain)
        .chartYScale(domain: yd)
        // Readings past the left edge (sliding in or out) are hidden; everything else keeps
        // room to overhang, as before: the newest reading's halo, the "Now" label, the readout.
        // (Charts that never move keep room on the left too, so nothing about them changes.)
        .chartPlotStyle { plot in
            plot.mask {
                Rectangle()
                    .padding(.top, -48)
                    .padding(.bottom, -12)
                    // Panned back (or gliding home), readings past the right edge are hidden too.
                    .padding(.trailing, pan != nil || panTrail != nil ? 0 : -48)
                    .padding(.leading, interactive ? 0 : -48)
            }
        }
        .chartXAxis {
            if showAxes {
                AxisMarks(values: .automatic(desiredCount: timeLabelCount)) { v in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel {
                        if let d = v.as(Date.self) {
                            // A midnight label names the day instead of "12 am".
                            Text(Self.timeAxisLabel(d))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .chartYAxis {
            if showAxes {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel {
                        if let d = v.as(Double.self) {
                            Text(String(format: "%.0f", d))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .chartOverlay { proxy in
            // The plot's width, so a snap's few points (or a pan's) can be turned into time
            // (`ScrubSnap`, `ChartPan`).
            if snapsScrub || pansBack, interactive {
                Color.clear
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .onAppear { plotWidth = proxy.plotSize.width }
                    .onChange(of: proxy.plotSize.width) { _, w in plotWidth = w }
            }
            // A slow ring breathing out of the newest reading while readings are arriving. App
            // screens only: widgets and the Live Activity don't animate, and it holds still (it
            // isn't drawn) under Reduce Motion or once the reading is stale.
            if interactive, !stale, !reduceMotion, pan == nil, let last = window.last {
                if ripplesNewReading {
                    // Once per new reading, then nothing until the next (see `newestChanged`).
                    ReadingDotRipple(proxy: proxy, date: last.timestamp, value: unit.value(fromMgdl: last.mgdl),
                                     tint: currentTint, beat: rippleBeat)
                } else {
                    TracePulse(proxy: proxy, date: last.timestamp, value: unit.value(fromMgdl: last.mgdl), tint: currentTint)
                }
            }
            if !gaps.isEmpty {
                ReadingGapLayer(proxy: proxy, gaps: gaps, unit: unit, open: $openGap, check: gapCheck)
            }
            markerOverlays(proxy: proxy, yd: yd)
            if interactive, labelsMarkers {
                markerLabels(proxy: proxy, yd: yd, window: window, domain: domain)
            }
            // Under the markers' layer, so a marker near "Now" still takes its own taps.
            if opensForecast(projection), forecastReveal >= 1 {
                ForecastTapLayer(proxy: proxy, forecast: projection, unit: unit, yd: yd) { openForecast(at: $0) }
            }
            if interactive, peeksMarkers || opensCallouts || opensActionCards {
                markerPeek(proxy: proxy, yd: yd, window: window)
            }
            spanOverlay(proxy: proxy, window: window)
        }
        .preference(key: MarkerPeekPressKey.self, value: pressingMarker)
        // While a span is shown, the pinch for hours and the yesterday-line menu stand down.
        .preference(key: ChartSpanActiveKey.self, value: span != nil)
        // Under Reduce Motion a new span replaces the chart, cross-fading (`changeRange`). Only
        // ever bumped there, so otherwise the chart keeps its identity and its axes move.
        .id(spanFade)
        .transition(.opacity)
        .onAppear { appeared(visibleFrom: window.first?.timestamp ?? .distantFuture) }
        .onDisappear { disappeared() }
        .onChange(of: events.map(\.id)) { _, _ in
            markersChanged(visibleFrom: window.first?.timestamp ?? .distantFuture)
        }
        .onChange(of: hours) { old, new in
            changeRange(from: old, to: new)
            openGap = nil
            // Hours changing under two fingers means they were pinching, not picking a span.
            if var touch = spanTouch { touch.wasPinch = true; spanTouch = touch }
            voSpanMinutes = ChartSpanVoiceOver.clamped(voSpanMinutes, hours: new)
        }
        .onChange(of: readings.last?.timestamp) { old, new in newestChanged(from: old, to: new) }
        .hoverSelection(interactive, selection(newest: window.last?.timestamp, snaps: snapTargets(window: window),
                                               secondsPerPoint: plotWidth > 0
                                                   ? domain.upperBound.timeIntervalSince(domain.lowerBound) / plotWidth : 0))
        .spanSelection(interactive && selectsSpans, spanSelection)
        .onChange(of: hovered?.timestamp) { _, new in scrubbed(to: new, readings: window) }
        .scrubFeedback(interactive, trigger: scrubTick)
        // A new reading slides the trace (and the time axis) along by one reading instead of
        // jumping it. One short movement per reading; nothing here repeats.
        .dsAnimation(.standard, value: interactive ? readings.last?.timestamp : nil)
        // A new target range glides the band, its lines and the glucose axis into place.
        .targetRangeGlide(lowMgdl: lowMgdl, highMgdl: highMgdl, enabled: interactive)
        // One VoiceOver element rather than hundreds of marks: a spoken summary, and the trace (with
        // the forecast as a second series) as an audio graph under "Chart Details" in the rotor.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(projection.isEmpty ? "Glucose chart" : "Glucose chart, with an estimated forecast")
        .accessibilityValue(spokenValue)
        .spanAdjustable(interactive && selectsSpans, adjustVoiceOverSpan)
        .forecastDetailsAction(opensForecast(projection)) { openForecast(at: nil) }
        .gapCheckAction(offersGapCheck(gaps)) { gapCheck?.run() }
        .accessibilityChartDescriptor(GlucoseAudioGraph(readings: window, forecast: projection, unit: unit,
                                                        lowMgdl: lowMgdl, highMgdl: highMgdl, yDomain: yd,
                                                        yesterday: ghost.filter { $0.date >= domain.lowerBound }))
        withPan(withForecastDetails(withCallouts(chart, window: window, yd: yd), projection: projection),
                domain: domain, pan: pan)
    }

    // MARK: Forecast details

    /// Whether the forecast details card can open: there's a forecast drawn and something to say.
    private func opensForecast(_ projection: [ForecastSample]) -> Bool {
        interactive && forecastDetails != nil && projection.count >= 2
    }

    /// A tap or click on the forecast (at `date`), VoiceOver's action or Return on the Mac (nil).
    /// Anything else showing makes way: an open callout, a peek, the scrub readout.
    private func openForecast(at date: Date?) {
        guard forecastDetails != nil, !forecastOpen || forecastClosing else { return }
        forecastCloseTask?.cancel()
        forecastClosing = false
        if callout != nil { closeCallout() }
        withTransaction(Transaction(animation: nil)) {
            peeked = nil
            hoverDate = nil
            touching = false
            scrubbedFrom = nil
            forecastTapped = date
        }
        #if os(iOS)
        Haptics.play(.scrubLogged)
        #endif
        forecastOpen = true
    }

    /// Lets the card go the app's way: its band narrows back into the line and its figures roll
    /// back (a fade under Reduce Motion), then the popover closes. `animated: false` for moments it
    /// should just go: the app leaving the screen, a marker's card taking over. A tap outside the
    /// popover still closes it the system's way.
    ///
    /// `forecastClosing` is only cleared when the card opens again, never as it goes, so the card
    /// never sees it drop and replays its entrance while the popover fades out.
    private func closeForecast(animated: Bool = true) {
        guard forecastOpen else { return }
        guard animated else {
            forecastCloseTask?.cancel()
            forecastOpen = false
            return
        }
        guard !forecastClosing else { return }
        forecastCloseTask?.cancel()
        forecastClosing = true
        let wait = ForecastCardEntrance.closeDuration(.init(reduceMotion: reduceMotion))
        forecastCloseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            forecastOpen = false
        }
    }

    /// The popover's anchor, on the forecast where it was tapped, and the moments that close it.
    /// A third overlay, after the chart's own VoiceOver element, so the card is an element of its own.
    private func withForecastDetails(_ chart: some View, projection: [ForecastSample]) -> some View {
        chart
            .chartOverlay { proxy in
                if interactive, forecastDetails != nil {
                    ForecastPopoverAnchor(proxy: proxy, unit: unit,
                                          anchor: ForecastDetails.anchor(tapped: forecastTapped, in: projection),
                                          isPresented: $forecastOpen, details: forecastDetails,
                                          closing: forecastClosing, close: { closeForecast() },
                                          dropped: { closeForecast(animated: false) })
                }
            }
            // Return on the Mac opens the card, and closes it again when it's open.
            .onChange(of: opensForecastDetails) { _, _ in
                if forecastOpen, !forecastClosing { closeForecast() }
                else if opensForecast(projection) { openForecast(at: nil) }
            }
            // The forecast went (a stale reading, the setting turned off) or the span changed.
            .onChange(of: projection.count >= 2 && forecastDetails != nil) { _, shown in
                if !shown { closeForecast() }
            }
            .onChange(of: hours) { _, _ in closeForecast() }
            .onChange(of: scenePhase) { _, phase in if phase == .background { closeForecast(animated: false) } }
            // Closed the system's way (a tap outside): nothing left to play.
            .onChange(of: forecastOpen) { _, open in
                if !open { forecastCloseTask?.cancel() }
            }
            .onDisappear { closeForecast(animated: false) }
    }

    /// The marker callout's overlay and the moments that close it, kept out of `body`'s chain so it
    /// still type-checks in reasonable time.
    private func withCallouts(_ chart: some View, window: [GlucoseReading], yd: ClosedRange<Double>) -> some View {
        chart
            // After the chart's own VoiceOver element, so its marker buttons and the callout are
            // elements of their own rather than folded into the summary.
            .chartOverlay { proxy in calloutLayer(proxy: proxy, yd: yd, window: window) }
            // The forecast details card counts too, so Esc in the Mac popover closes it first.
            .preference(key: MarkerCalloutOpenKey.self, value: callout != nil || forecastOpen)
            .preference(key: MarkerHoveredKey.self, value: opensActionCards && hoveredMarker != nil)
            .onChange(of: pinsHoveredMarker) { _, _ in pinHoveredMarker() }
            .onChange(of: peekable(window).map(\.id)) { _, ids in calloutMarkersChanged(ids) }
            .onChange(of: closesCallout) { _, _ in
                closeCallout()
                closeForecast()
            }
            .onChange(of: hours) { _, _ in closeCallout() }
            .onChange(of: calloutKeyFocusChanged) { old, new in
                if old == true, new == false { closeCallout() }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .background { closeCallout() } }
    }
}

// MARK: - Audio graph

/// The chart for VoiceOver's audio graph and data table: readings as one series, the forecast (if
/// shown) as another, with the target's edges as gridlines. Shared by every target that draws a
/// `GlucoseChart`; the Mac dashboard's own chart has `GlucoseChartDescriptor`.
struct GlucoseAudioGraph: AXChartDescriptorRepresentable {
    let readings: [GlucoseReading]
    let forecast: [ForecastSample]
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    let yDomain: ClosedRange<Double>
    /// Yesterday's line, when it's shown, as a third series at today's times.
    var yesterday: [YesterdayLine.Point] = []

    func makeChartDescriptor() -> AXChartDescriptor {
        let unit = self.unit
        // A few hundred points keep audio-graph navigation quick.
        let step = max(1, readings.count / 300)
        let sampled = stride(from: 0, to: readings.count, by: step).map { readings[$0] }
        let first = readings.first?.timestamp ?? Date()
        let last = forecast.last?.date ?? readings.last?.timestamp ?? first.addingTimeInterval(3600)
        let x = AXNumericDataAxisDescriptor(
            title: "Time",
            range: first.timeIntervalSince1970...max(last.timeIntervalSince1970, first.timeIntervalSince1970 + 60),
            gridlinePositions: []
        ) { value in
            Date(timeIntervalSince1970: value).formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        let y = AXNumericDataAxisDescriptor(
            title: "Glucose, \(unit.spokenLabel)",
            range: yDomain,
            gridlinePositions: [unit.value(fromMgdl: lowMgdl), unit.value(fromMgdl: highMgdl)]
        ) { value in
            unit == .mmol ? String(format: "%.1f", value) : String(format: "%.0f", value)
        }
        var series = [AXDataSeriesDescriptor(
            name: "Readings",
            isContinuous: true,
            dataPoints: sampled.map {
                AXDataPoint(x: $0.timestamp.timeIntervalSince1970, y: unit.value(fromMgdl: $0.mgdl),
                            label: GlucoseRange.classify(mgdl: $0.mgdl, low: lowMgdl, high: highMgdl).label)
            }
        )]
        if !forecast.isEmpty {
            series.append(AXDataSeriesDescriptor(
                name: "Forecast, an estimate",
                isContinuous: true,
                dataPoints: forecast.map { AXDataPoint(x: $0.date.timeIntervalSince1970, y: unit.value(fromMgdl: $0.mgdl)) }
            ))
        }
        if !yesterday.isEmpty {
            series.append(AXDataSeriesDescriptor(
                name: "Yesterday at the same time",
                isContinuous: true,
                dataPoints: yesterday.map { AXDataPoint(x: $0.date.timeIntervalSince1970, y: unit.value(fromMgdl: $0.mgdl)) }
            ))
        }
        return AXChartDescriptor(
            title: "Glucose",
            summary: "Target \(unit.format(mgdl: lowMgdl)) to \(unit.format(mgdl: highMgdl)) \(unit.spokenLabel).",
            xAxis: x, yAxis: y, additionalAxes: [], series: series)
    }
}

/// Something logged, shown as a marker on the chart.
struct ChartLogMarker: Identifiable {
    let id: UUID
    let date: Date
    let systemImage: String
    let tint: Color
    /// Which row of markers, from the bottom, so a dose and a meal logged together don't overlap.
    var lane: Int = 0
    /// For VoiceOver: "6 units Novorapid at 12:56 pm".
    let label: String
    /// What it is, for "Meal added to chart" (`MarkerPop`). `nil` says nothing.
    var kind: MarkerPop.Kind? = nil
    /// What a tap on it shows (`MarkerCallout`). `nil`: it can still be peeked, but not opened.
    var callout: MarkerCallout.Content? = nil
    /// The amount beside it when zoomed in (`MarkerLabels`): "45 g", "4 u". `nil`: no label.
    var shortLabel: String? = nil
}

/// A marker logged from elsewhere, glowing once.
private struct MarkerGlow: Identifiable {
    let id = UUID()
    let marker: ChartLogMarker
    let origin: LogOrigin
    let delay: TimeInterval
}

/// A marker popping in or shrinking out.
private struct MarkerFlight: Identifiable {
    /// Its own id, not the marker's, so a marker brought back while still leaving starts afresh.
    let id = UUID()
    let marker: ChartLogMarker
    let leaving: Bool
}

/// One marker popping in (a small spring, overshooting a little) or shrinking out, placed with the
/// chart's proxy exactly where the chart draws it. It moves once, then calls `landed`.
private struct MarkerFlightView: View {
    let proxy: ChartProxy
    let flight: MarkerFlight
    let value: Double
    let landed: () -> Void
    @State private var shown: Bool

    init(proxy: ChartProxy, flight: MarkerFlight, value: Double, landed: @escaping () -> Void) {
        self.proxy = proxy
        self.flight = flight
        self.value = value
        self.landed = landed
        _shown = State(initialValue: flight.leaving)
    }

    static let popIn = Animation.spring(response: 0.36, dampingFraction: 0.58)
    static let shrinkOut = Animation.easeIn(duration: 0.2)

    var body: some View {
        GeometryReader { geo in
            if let plot = proxy.plotFrame,
               let x = proxy.position(forX: flight.marker.date),
               let y = proxy.position(forY: value) {
                let origin = geo[plot].origin
                EventSymbol(event: flight.marker)
                    .scaleEffect(shown ? 1 : 0.01)
                    .opacity(shown ? 1 : 0)
                    .position(x: origin.x + x, y: origin.y + y)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(flight.leaving ? Self.shrinkOut : Self.popIn, completionCriteria: .logicallyComplete) {
                shown = !flight.leaving
            } completion: {
                landed()
            }
        }
    }
}

extension GlucoseChart {
    /// "3 pm", or the weekday at midnight instead of "12 am".
    static func timeAxisLabel(_ d: Date) -> String {
        Calendar.current.component(.hour, from: d) == 0
            ? d.formatted(.dateTime.weekday(.abbreviated))
            : d.formatted(.dateTime.hour())
    }

    /// The reading before `r`, when it's close enough (15 minutes) for a change to mean something.
    static func previous(to r: GlucoseReading, in window: [GlucoseReading]) -> GlucoseReading? {
        guard let prev = window.last(where: { $0.timestamp < r.timestamp }),
              r.timestamp.timeIntervalSince(prev.timestamp) <= 15 * 60 else { return nil }
        return prev
    }

    /// One unbroken stretch of the trace per segment (just one with no gaps): the soft glow under
    /// it, tinted with the current range, the out-of-range fills, and the line itself, which
    /// changes colour as it crosses the thresholds.
    @ChartContentBuilder
    func traceMarks(_ segments: [[GlucoseReading]], styles: [LinearGradient], floor: Double, tint: Color) -> some ChartContent {
        ForEach(Array(segments.enumerated()), id: \.offset) { index, seg in
            ForEach(seg) { r in
                AreaMark(
                    x: .value("Time", r.timestamp),
                    yStart: .value("Floor", floor),
                    yEnd: .value("Glucose", unit.value(fromMgdl: r.mgdl)),
                    series: .value("Series", "Glow \(index)")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.0)],
                                   startPoint: .top, endPoint: .bottom)
                )
            }
            // Time spent out of range, filled between the trace and the line it crossed, so a
            // high or a low reads as a shape before anyone looks at the numbers.
            outOfRangeMarks(seg, segment: index)
            ForEach(seg) { r in
                LineMark(
                    x: .value("Time", r.timestamp),
                    y: .value("Glucose", unit.value(fromMgdl: r.mgdl)),
                    series: .value("Series", "Trace \(index)")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(styles[index])
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
        }
    }

    /// Fills above the high line and below the low line wherever the trace goes past them.
    @ChartContentBuilder
    func outOfRangeMarks(_ window: [GlucoseReading], segment: Int = 0) -> some ChartContent {
        let high = unit.value(fromMgdl: highMgdl)
        let low = unit.value(fromMgdl: lowMgdl)
        let goesHigh = window.contains { $0.mgdl > highMgdl }
        let goesLow = window.contains { $0.mgdl < lowMgdl }
        if goesHigh {
            ForEach(window) { r in
                AreaMark(
                    x: .value("Time", r.timestamp),
                    yStart: .value("High", high),
                    yEnd: .value("Above", max(unit.value(fromMgdl: r.mgdl), high)),
                    series: .value("Series", "Above range \(segment)")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(colors: [GlucoseRange.high.tint.opacity(0.30), GlucoseRange.high.tint.opacity(0.10)],
                                   startPoint: .top, endPoint: .bottom)
                )
            }
        }
        if goesLow {
            ForEach(window) { r in
                AreaMark(
                    x: .value("Time", r.timestamp),
                    yStart: .value("Below", min(unit.value(fromMgdl: r.mgdl), low)),
                    yEnd: .value("Low", low),
                    series: .value("Series", "Below range \(segment)")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(colors: [GlucoseRange.low.tint.opacity(0.12), GlucoseRange.low.tint.opacity(0.34)],
                                   startPoint: .top, endPoint: .bottom)
                )
            }
        }
    }

    /// Where readings end and the forecast begins.
    @ChartContentBuilder
    func nowMark(last: GlucoseReading?) -> some ChartContent {
        if marksNow, let last {
            RuleMark(x: .value("Now", last.timestamp))
                .foregroundStyle(Color.secondary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                .annotation(position: .top, alignment: .center, spacing: 2) {
                    Text("Now").dsFont(.caption).foregroundStyle(.secondary)
                }
        }
    }

    /// A faint line at each midnight, so times either side can't be mistaken for the same day.
    @ChartContentBuilder
    func midnightMarks(_ window: [GlucoseReading]) -> some ChartContent {
        let marks: [Date] = {
            guard let first = window.first, let last = window.last else { return [] }
            return ClockLabel.midnights(from: first.timestamp, to: last.timestamp)
        }()
        ForEach(marks, id: \.self) { m in
            RuleMark(x: .value("Midnight", m))
                .foregroundStyle(Color.primary.opacity(0.14))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
    }

    /// Where a row of markers sits, from the bottom of the glucose axis.
    func markerY(lane: Int, yd: ClosedRange<Double>) -> Double {
        yd.lowerBound + (yd.upperBound - yd.lowerBound) * (0.06 + 0.08 * Double(lane))
    }

    /// Logged insulin and food, along the bottom.
    @ChartContentBuilder
    func eventMarks(_ window: [GlucoseReading], yd: ClosedRange<Double>) -> some ChartContent {
        let start = window.first?.timestamp ?? .distantFuture
        let inFlight = Set(flights.filter { !$0.leaving }.map(\.marker.id))
        let shown = events.filter { $0.date >= start && !inFlight.contains($0.id) }
        ForEach(shown) { e in
            PointMark(x: .value("Time", e.date), y: .value("Logged", markerY(lane: e.lane, yd: yd)))
                .symbol { EventSymbol(event: e) }
                .accessibilityLabel(e.label)
        }
    }
}

/// The labels beside logged markers (`MarkerLabels`), placed with the chart's proxy. Drawing only:
/// it takes no touches and VoiceOver skips it, since each marker already says what it was.
private struct MarkerLabelLayer: View {
    let proxy: ChartProxy
    let markers: [ChartLogMarker]
    /// The hours across the time axis right now, for whether there's room.
    let spanHours: Double
    /// The chosen hours and the newest reading: when either changes the axes move, and the labels
    /// glide with them rather than jumping.
    let hours: Double
    let newest: Date?
    let reduceMotion: Bool
    let laneY: (Int) -> Double

    /// The labels that could show, where each would sit, and which do.
    private struct Item: Identifiable {
        let label: MarkerLabels.Candidate
        let tint: Color
        var id: UUID { label.id }
    }

    private struct Layout {
        var candidates: [Item] = []
        var placed: [UUID: MarkerLabels.Placement] = [:]
        var shown: Set<UUID> = []
    }

    private func layout() -> Layout {
        let width = Double(proxy.plotSize.width)
        var obstacles: [(x: Double, y: Double)] = []
        var out = Layout()
        for m in markers {
            guard let px = proxy.position(forX: m.date), let py = proxy.position(forY: laneY(m.lane)) else { continue }
            let x = Double(px), y = Double(py)
            obstacles.append((x: x, y: y))
            guard let text = m.shortLabel, let priority = MarkerLabels.priority(m.kind), x >= 0, x <= width else { continue }
            out.candidates.append(Item(label: .init(id: m.id, x: x, y: y, text: text, priority: priority, date: m.date), tint: m.tint))
        }
        let labels = out.candidates.map(\.label)
        out.placed = MarkerLabels.placements(labels, plotWidth: width)
        out.shown = MarkerLabels.shown(labels, obstacles: obstacles, plotWidth: width, hours: spanHours)
        return out
    }

    var body: some View {
        GeometryReader { geo in
            if let plot = proxy.plotFrame {
                let origin = geo[plot].origin
                let l = layout()
                ForEach(l.candidates) { c in
                    if let p = l.placed[c.label.id] {
                        MarkerLabelText(text: c.label.text, tint: c.tint, shown: l.shown.contains(c.label.id),
                                        reduceMotion: reduceMotion)
                            .position(x: origin.x + p.centerX, y: origin.y + p.centerY)
                    }
                }
                // Glide with the axes when the hours change or a new reading slides them along.
                .animation(reduceMotion ? nil : DSMotion.emphasized.animation, value: hours)
                .animation(reduceMotion ? nil : DSMotion.standard.animation, value: newest)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One label: the amount in the marker's colour on a soft backing, so it reads over the trace.
private struct MarkerLabelText: View {
    let text: String
    let tint: Color
    let shown: Bool
    let reduceMotion: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(tint)
            .padding(.horizontal, 2)
            .background(Capsule().fill(.background.opacity(0.75)))
            .opacity(shown ? 1 : 0)
            .animation(reduceMotion ? nil
                       : .easeInOut(duration: MarkerLabels.fadeDuration).delay(shown ? MarkerLabels.fadeInDelay : 0),
                       value: shown)
    }
}

private struct EventSymbol: View {
    let event: ChartLogMarker

    var body: some View {
        Image(systemName: event.systemImage)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(Circle().fill(event.tint))
            .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
    }
}

/// The hover / scrub label: the reading with its range's dot, when it was, and how much it
/// changed since the reading before.
private struct ChartReadout: View {
    let reading: GlucoseReading
    let previous: GlucoseReading?
    let unit: GlucoseUnit
    let range: GlucoseRange
    /// Yesterday's reading at the same clock time, while yesterday's line is shown.
    var yesterday: GlucoseReading? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: DS.Space.xs) {
                Circle().fill(range.tint).frame(width: 7, height: 7)
                Text(unit.format(mgdl: reading.mgdl, withUnit: true))
                    .fontWeight(.semibold)
                    .dsFont(.callout)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: reading.mgdl))
                if let previous {
                    Text(unit.formatDelta(mgdl: reading.mgdl - previous.mgdl))
                        .dsFont(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Text(ClockLabel.dayTime(reading.timestamp, now: Date()))
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let yesterday {
                Text("Yesterday \(unit.format(mgdl: yesterday.mgdl))")
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// The breathing ring at the end of the trace. Placed with the chart's proxy so it sits exactly on
/// the newest reading's dot whatever the chart's size.
private struct TracePulse: View {
    let proxy: ChartProxy
    let date: Date
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            if let plot = proxy.plotFrame,
               let x = proxy.position(forX: date),
               let y = proxy.position(forY: value) {
                let origin = geo[plot].origin
                // One breath every few seconds rather than a loop (see `PulseBeat`).
                PulseBeat(every: PulseInterval.trace) { beat in
                    Circle()
                        .strokeBorder(tint, lineWidth: 1.5)
                        .frame(width: 12, height: 12)
                        .pulse(beat: beat, scale: 2.6, opacity: 0.8, duration: 1.8)
                }
                .position(x: origin.x + x, y: origin.y + y)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The current-reading dot's one soft ripple when a new reading lands (`NewReadingRipple`). Placed
/// with the chart's proxy like `TracePulse`. Not drawn until the first beat, and hidden again once
/// it has faded, so nothing sits on screen or redraws between readings.
private struct ReadingDotRipple: View {
    let proxy: ChartProxy
    let date: Date
    let value: Double
    let tint: Color
    let beat: Int

    var body: some View {
        GeometryReader { geo in
            if let plot = proxy.plotFrame,
               let x = proxy.position(forX: date),
               let y = proxy.position(forY: value) {
                let origin = geo[plot].origin
                Circle()
                    .strokeBorder(tint, lineWidth: 1.5)
                    .frame(width: 12, height: 12)
                    .pulse(beat: beat, scale: NewReadingRipple.scale, opacity: NewReadingRipple.startOpacity,
                           duration: NewReadingRipple.duration)
                    .position(x: origin.x + x, y: origin.y + y)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Changes each time a scrub tick is due, so `.haptic` fires even for two of a kind in a row.
private struct ScrubTickTrigger: Equatable {
    enum Kind: Equatable {
        case rangeEdge, logged
        /// The scrub line snapped onto something (`ScrubSnap`).
        case snapped
    }

    private(set) var count = 0
    private(set) var kind: Kind?

    mutating func fire(_ tick: ChartScrub.Tick) {
        switch tick {
        case .rangeEdge: fire(Kind.rangeEdge)
        case .logged: fire(Kind.logged)
        }
    }

    mutating func fire(_ kind: Kind) {
        count += 1
        self.kind = kind
    }
}

private extension View {
    /// A light tick when scrubbing crosses the low or high line, a lighter one on something logged
    /// (iPhone). Moving from one reading to the next doesn't tick by itself.
    @ViewBuilder
    func scrubFeedback(_ enabled: Bool, trigger: ScrubTickTrigger) -> some View {
        #if os(iOS)
        if enabled {
            haptic(trigger: trigger) { _, new in
                switch new.kind {
                case .rangeEdge: return .scrubRangeEdge
                case .logged: return .scrubLogged
                case .snapped: return .scrubSnapped
                case nil: return nil
                }
            }
        } else {
            self
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func hoverSelection(_ enabled: Bool, _ date: Binding<Date?>) -> some View {
        if enabled {
            chartXSelection(value: date)
        } else {
            self
        }
    }

    /// Charts' range selection, which on iPhone is two fingers on the chart. iPhone only: on the
    /// Mac it would be a click and drag, and the popover's pointer reads single readings.
    @ViewBuilder
    func spanSelection(_ enabled: Bool, _ range: Binding<ClosedRange<Date>?>) -> some View {
        #if os(iOS)
        if enabled {
            chartXSelection(range: range)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// VoiceOver's "Show forecast details" on the chart (`ForecastDetails`), while there's a forecast
    /// to describe. Always the same modifier, so the chart keeps its identity when it comes and goes.
    func forecastDetailsAction(_ enabled: Bool, _ open: @escaping () -> Void) -> some View {
        accessibilityActions {
            if enabled {
                Button(ForecastDetails.voiceOverActionName, action: open)
            }
        }
    }

    /// VoiceOver's "Check now" on the chart, while the newest gap says no signal or can't connect
    /// (`ReadingGapCheck`). The result is announced when it lands. Always the same modifier.
    func gapCheckAction(_ enabled: Bool, _ run: @escaping () -> Void) -> some View {
        accessibilityActions {
            if enabled {
                Button(ReadingGapCheck.voiceOverActionName, action: run)
            }
        }
    }

    /// Swipe up or down with VoiceOver for a span's figures (`ChartSpanVoiceOver`).
    @ViewBuilder
    func spanAdjustable(_ enabled: Bool, _ adjust: @escaping (AccessibilityAdjustmentDirection) -> Void) -> some View {
        if enabled {
            accessibilityAdjustableAction(adjust)
                .accessibilityHint("Swipe up or down to hear the average, range and change over a span.")
        } else {
            self
        }
    }
}

// MARK: - Marker peek

/// Whether a finger is down on a logged marker (iPhone). `yesterdayLineMenu` reads it and offers
/// nothing meanwhile, so a hold on a marker peeks instead of opening the menu (`MarkerPeek`).
struct MarkerPeekPressKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// An invisible layer that only answers over the markers themselves (a fingertip-sized circle each),
/// so touches anywhere else on the chart reach the scrub and the menu exactly as before. On iPhone
/// a finger held still on one for `MarkerPeek.holdDuration` peeks it, until it lifts; moving first
/// is a scrub. On the Mac the pointer over one peeks it. Hidden from VoiceOver, which reads each
/// marker in the chart's summary instead.
private struct MarkerPeekLayer: View {
    let proxy: ChartProxy
    let markers: [(marker: ChartLogMarker, value: Double)]
    let pressing: (Bool) -> Void
    let peek: (UUID?) -> Void
    /// A tap (iPhone) or click (Mac) on a marker, when callouts are on (`MarkerCallout`).
    var tap: ((UUID) -> Void)? = nil
    /// A hold past the peek (iPhone), when peek cards are on (`MarkerActions`).
    var pin: ((UUID) -> Void)? = nil
    /// The marker under the pointer (Mac), or nil, as it changes, for a right-click.
    var hovering: ((UUID?) -> Void)? = nil
    #if os(iOS)
    @State private var hold: Task<Void, Never>?
    /// The finger slid past the slop after the peek showed: still a peek, never the card.
    @State private var slid = false
    @State private var down: CGPoint?
    @State private var downAt: Date?
    @State private var downOn: UUID?
    @State private var peeking = false
    #endif

    var body: some View {
        GeometryReader { geo in
            let spots = self.spots(in: geo)
            Color.clear
                .contentShape(MarkerSpotsShape(spots: spots))
                .interactions(spots: spots, layer: self)
        }
        .accessibilityHidden(true)
    }

    private func spots(in geo: GeometryProxy) -> [MarkerPeek.Spot] {
        guard let plot = proxy.plotFrame else { return [] }
        let origin = geo[plot].origin
        return markers.compactMap { m in
            guard let x = proxy.position(forX: m.marker.date), let y = proxy.position(forY: m.value) else { return nil }
            return MarkerPeek.Spot(id: m.marker.id, x: Double(origin.x + x), y: Double(origin.y + y))
        }
    }

    #if os(iOS)
    /// The finger went down or moved. Down on a marker starts the hold; moving off it is a scrub.
    fileprivate func touched(_ value: DragGesture.Value, spots: [MarkerPeek.Spot]) {
        if down == nil {
            down = value.startLocation
            downAt = Date()
            guard let id = MarkerPeek.hit(x: Double(value.startLocation.x), y: Double(value.startLocation.y), in: spots)
            else { return }
            downOn = id
            pressing(true)
            hold = Task { @MainActor in
                try? await Task.sleep(for: .seconds(MarkerPeek.holdDuration))
                guard !Task.isCancelled else { return }
                peeking = true
                peek(id)
                // Held on, still, past `MarkerActions.pinAfter`: the peek turns into the card.
                guard let pin else { return }
                try? await Task.sleep(for: .seconds(MarkerActions.pinAfter - MarkerPeek.holdDuration))
                guard !Task.isCancelled, !slid else { return }
                pin(id)
            }
        } else if !MarkerPeek.isHolding(dx: Double(value.translation.width), dy: Double(value.translation.height)) {
            if peeking {
                slid = true
            } else {
                hold?.cancel()
                hold = nil
                downOn = nil
                pressing(false)
            }
        }
    }

    /// The finger lifted (or the system took the touch): any peek goes. Lifted off a marker before
    /// the peek, without sliding off it, it was a tap (`MarkerCallout.isTap`).
    fileprivate func lifted(_ value: DragGesture.Value?) {
        let tapped: UUID? = {
            guard !peeking, let id = downOn, let at = downAt, let value else { return nil }
            return MarkerCallout.isTap(heldFor: Date().timeIntervalSince(at), dx: Double(value.translation.width),
                                       dy: Double(value.translation.height)) ? id : nil
        }()
        hold?.cancel()
        hold = nil
        down = nil
        downAt = nil
        downOn = nil
        if peeking { peek(nil) }
        peeking = false
        slid = false
        pressing(false)
        if let tapped, let tap { tap(tapped) }
    }
    #endif

    #if os(macOS)
    fileprivate func hovered(_ phase: HoverPhase, spots: [MarkerPeek.Spot]) {
        switch phase {
        case .active(let p):
            let id = MarkerPeek.hit(x: Double(p.x), y: Double(p.y), in: spots)
            hovering?(id)
            peek(id)
        case .ended:
            hovering?(nil)
            peek(nil)
        }
    }

    /// A click on a marker opens its callout.
    fileprivate func clicked(_ p: CGPoint, spots: [MarkerPeek.Spot]) {
        guard let tap, let id = MarkerPeek.hit(x: Double(p.x), y: Double(p.y), in: spots) else { return }
        peek(nil)
        tap(id)
    }
    #endif
}

private extension View {
    @ViewBuilder
    func interactions(spots: [MarkerPeek.Spot], layer: MarkerPeekLayer) -> some View {
        #if os(iOS)
        // Alongside the chart's own selection, never instead of it: a finger that moves is a scrub.
        simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { layer.touched($0, spots: spots) }
                .onEnded { layer.lifted($0) }
        )
        #elseif os(macOS)
        onContinuousHover(coordinateSpace: .local) { layer.hovered($0, spots: spots) }
            .gesture(SpatialTapGesture(coordinateSpace: .local).onEnded { layer.clicked($0.location, spots: spots) })
        #else
        self
        #endif
    }
}

/// A fingertip-sized circle round each marker: the only places the peek layer answers touches.
private struct MarkerSpotsShape: Shape {
    let spots: [MarkerPeek.Spot]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = MarkerPeek.hitRadius
        for s in spots {
            p.addEllipse(in: CGRect(x: s.x - r, y: s.y - r, width: r * 2, height: r * 2))
        }
        return p
    }
}

/// The peek: the marker's own symbol, what it was ("6 units Novorapid at 12:56 pm"), and how long
/// ago with the reading then. It sits above the marker, kept inside the chart, and springs up out of
/// it on iPhone (a plain fade under Reduce Motion, and always on the Mac, where it's a tooltip).
private struct MarkerPeekCard: View {
    let proxy: ChartProxy
    let marker: ChartLogMarker
    let value: Double
    let detail: String

    static let width: CGFloat = 196

    static func animation(showing: Bool, reduceMotion: Bool) -> Animation {
        #if os(iOS)
        if !reduceMotion {
            return showing ? .spring(response: 0.32, dampingFraction: 0.68) : .easeIn(duration: 0.14)
        }
        #endif
        return showing ? .easeOut(duration: 0.16) : .easeIn(duration: 0.12)
    }

    static func transition(reduceMotion: Bool) -> AnyTransition {
        #if os(iOS)
        if !reduceMotion {
            return .scale(scale: 0.6, anchor: .bottom).combined(with: .opacity)
        }
        #endif
        return .opacity
    }

    var body: some View {
        GeometryReader { geo in
            if let plot = proxy.plotFrame,
               let x = proxy.position(forX: marker.date),
               let y = proxy.position(forY: value) {
                let frame = geo[plot]
                let half = Self.width / 2
                let cx = min(max(frame.minX + x, frame.minX + half), max(frame.minX + half, frame.maxX - half))
                // Its bottom edge just above the marker, so the finger doesn't cover it.
                let bottom = max(frame.minY + y - 14, 0)
                card
                    .frame(width: Self.width)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: Self.width, height: bottom, alignment: .bottom)
                    .position(x: cx, y: bottom / 2)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var card: some View {
        HStack(alignment: .top, spacing: DS.Space.sm) {
            EventSymbol(event: marker)
            VStack(alignment: .leading, spacing: 1) {
                Text(marker.label)
                    .dsFont(.callout)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                Text(detail)
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, DS.Space.xs + 2)
        .background { DSSurface(style: .standard, radius: DS.Radius.control) }
        .dsShadow(.medium)
    }
}

// MARK: - Marker callout

/// Mac: whether the pointer is over a logged marker that a right-click would open the peek card
/// on (`GlucoseChart.markerActions`). The popover reads it to take that right-click for the card
/// rather than the yesterday-line menu, and bumps `pinsHoveredMarker`.
struct MarkerHoveredKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// Whether a marker's callout is open (`GlucoseChart.openInLogbook`). The Mac popover reads it so
/// Esc closes the callout first, while the chart around it has focus, before it closes anything else.
struct MarkerCalloutOpenKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// How the callout comes and goes: it springs out of its marker, growing from the marker's side of
/// the card, and drops back quickly. A plain cross-fade under Reduce Motion.
enum MarkerCalloutMotion {
    static let width: CGFloat = 224

    static func animation(showing: Bool, reduceMotion: Bool) -> Animation {
        if reduceMotion { return showing ? .easeOut(duration: 0.18) : .easeIn(duration: 0.12) }
        return showing ? .spring(response: 0.34, dampingFraction: 0.7) : .easeIn(duration: 0.14)
    }

    static func transition(growingFrom anchor: UnitPoint, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.3, anchor: anchor).combined(with: .opacity)
    }
}

/// Over the chart, under the markers, while a callout is open: a tap (iPhone) or click (Mac)
/// anywhere else on the chart closes it and does nothing more. Only a tap, so the page still
/// scrolls; a scrub starting closes it too (`GlucoseChart.selection`).
private struct MarkerCalloutDismissLayer: View {
    let close: () -> Void

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { close() }
            .accessibilityHidden(true)
    }
}

/// One marker as VoiceOver sees it: a button reading what was logged ("Meal, 45 grams, Toast,
/// 12:56 pm, has a note") that opens or closes its callout. Not drawn and not touchable: the chart
/// draws the marker, and the peek layer takes touches.
private struct MarkerVoiceOverButton: View {
    let label: String
    let open: Bool
    /// Whether activating it shows the details (a tap's callout) rather than the peek card.
    var opensDetails = true
    /// The "Edit or Log Again" action, opening the peek card (`MarkerActions`). Nil: not offered.
    var showActions: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        Color.primary.opacity(0.001)
            .frame(width: 28, height: 28)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(hint)
            .accessibilityAction { action() }
            .accessibilityActions {
                if let showActions {
                    Button(MarkerActions.voiceOverActionName, action: showActions)
                }
            }
    }

    private var hint: String {
        if open { return "Closes what was logged." }
        // VoiceOver says "actions available" itself when Edit or Log Again is offered.
        return opensDetails ? "Shows what was logged, with Open in Logbook." : "Shows what was logged, with Edit and Log Again Now."
    }
}

/// The callout: the marker's own symbol, what it was, the amount, when, the note, and Open in
/// Logbook. It only repeats what was logged.
private struct MarkerCalloutCard: View {
    let marker: ChartLogMarker
    let content: MarkerCallout.Content
    let time: String
    var voiceOverFocus: AccessibilityFocusState<Bool>.Binding
    /// The peek card's buttons, in place of Open in Logbook. Nil: the details a tap opens.
    var actions: [MarkerActions.Action]? = nil
    let open: () -> Void
    var act: (MarkerActions.Action) -> Void = { _ in }
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .top, spacing: DS.Space.sm) {
                EventSymbol(event: marker)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(content.title)
                        .dsFont(.callout)
                        .fontWeight(.semibold)
                    if let amount = content.amount {
                        Text(amount)
                            .dsFont(.callout)
                            .lineLimit(2)
                            .accessibilityLabel(MarkerCallout.spokenAmount(amount))
                    }
                    Text(time)
                        .dsFont(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    if let note = content.note {
                        Text(note)
                            .dsFont(.caption)
                            .lineLimit(3)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityFocused(voiceOverFocus)
            if let actions {
                actionButtons(actions)
            } else {
                openButton
            }
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, DS.Space.xs + 2)
        .background { DSSurface(style: .standard, radius: DS.Radius.control) }
        .dsShadow(.medium)
        // A touch on the card itself stays on it, rather than reaching the chart under it.
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) { close() }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
    }

    /// Edit and Log Again Now, side by side, or one above the other when they don't fit (larger
    /// text). Each needs its own tap or click: nothing is logged by the card opening.
    private func actionButtons(_ actions: [MarkerActions.Action]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.xs) { ForEach(actions, id: \.self) { actionButton($0) } }
            VStack(alignment: .leading, spacing: DS.Space.xs) { ForEach(actions, id: \.self) { actionButton($0) } }
        }
        .padding(.leading, 16 + DS.Space.sm)
        .padding(.top, 2)
    }

    private func actionButton(_ action: MarkerActions.Action) -> some View {
        Button { act(action) } label: {
            Label(action.title, systemImage: action.systemImage)
                .dsFont(.label)
                .fontWeight(.semibold)
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel(action.title)
        .accessibilityHint(MarkerActions.hint(action, kind: marker.kind))
    }

    private var openButton: some View {
        Button(action: open) {
            HStack(spacing: 2) {
                Text("Open in Logbook")
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            .dsFont(.label)
            .fontWeight(.semibold)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .padding(.leading, 16 + DS.Space.sm)
        .accessibilityLabel("Open in Logbook")
    }
}

private extension View {
    /// On the Mac the open callout holds keyboard focus, so Esc reaches it.
    @ViewBuilder
    func calloutKeyFocus(_ focus: FocusState<Bool>.Binding?) -> some View {
        #if os(macOS)
        if let focus {
            focusable()
                .focused(focus)
                .focusEffectDisabled()
        } else {
            self
        }
        #else
        self
        #endif
    }
}

// MARK: - Span stats

/// Whether the chart is showing a span picked out with two fingers (`GlucoseChart.selectsSpans`).
/// `chartHoursPinch` and `yesterdayLineMenu` read it and stand down meanwhile, so moving the
/// fingers changes the span rather than the hours.
struct ChartSpanActiveKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// A two-finger touch that hasn't yet turned into a span (`ChartSpanHold`).
private struct SpanTouch {
    /// How far apart the fingers were, in chart time, when they landed.
    let firstWidth: TimeInterval
    /// The gap changed too much before the hold was up, or the hours changed: a pinch.
    var wasPinch = false
}

/// A soft brand-tinted band over the span, with hairline edges, drawn over the trace. Fades in and
/// out (`.opacity`), which moves nothing, so it's the same under Reduce Motion.
private struct ChartSpanBand: View {
    let proxy: ChartProxy
    let range: ClosedRange<Date>

    var body: some View {
        GeometryReader { geo in
            if let plot = proxy.plotFrame,
               let x0 = proxy.position(forX: range.lowerBound),
               let x1 = proxy.position(forX: range.upperBound) {
                let frame = geo[plot]
                let left = max(min(x0, x1), 0), right = min(max(x0, x1), frame.width)
                if right > left {
                    Rectangle()
                        .fill(Palette.brand.opacity(0.12))
                        .overlay(alignment: .leading) { Rectangle().fill(Palette.brand.opacity(0.55)).frame(width: 1) }
                        .overlay(alignment: .trailing) { Rectangle().fill(Palette.brand.opacity(0.55)).frame(width: 1) }
                        .frame(width: right - left, height: frame.height)
                        .offset(x: frame.minX + left, y: frame.minY)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The span's figures, at the top of the chart over the band: when, how long, then average,
/// lowest, highest, time in range and change. The figures roll to new values as the fingers move;
/// under Reduce Motion they just change. Hidden from VoiceOver, which reads the same figures as the
/// chart's value (`ChartSpanVoiceOver`).
private struct ChartSpanCard: View {
    let proxy: ChartProxy
    let range: ClosedRange<Date>
    let unit: GlucoseUnit
    let reduceMotion: Bool
    let stats: ChartSpanStats?

    static let maxWidth: CGFloat = 320

    static func animation(showing: Bool, reduceMotion: Bool) -> Animation {
        if reduceMotion { return .easeInOut(duration: 0.15) }
        return showing ? DSMotion.quick.animation : .easeIn(duration: 0.16)
    }

    /// Drops in a little from above and fades; under Reduce Motion it only fades.
    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.94, anchor: .top).combined(with: .opacity)
    }

    var body: some View {
        GeometryReader { geo in
            if let plot = proxy.plotFrame,
               let x0 = proxy.position(forX: range.lowerBound),
               let x1 = proxy.position(forX: range.upperBound) {
                let frame = geo[plot]
                let width = min(Self.maxWidth, frame.width)
                let mid = frame.minX + (x0 + x1) / 2
                let left = min(max(mid - width / 2, frame.minX), frame.maxX - width)
                card
                    .frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(x: left, y: frame.minY + DS.Space.xs)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(range.lowerBound.formatted(date: .omitted, time: .shortened)) – \(range.upperBound.formatted(date: .omitted, time: .shortened))")
                    .dsFont(.caption)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: DS.Space.xs)
                Text(Self.durationText(range.upperBound.timeIntervalSince(range.lowerBound)))
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            if let s = stats {
                HStack(alignment: .top, spacing: DS.Space.sm) {
                    figure("Avg", unit.format(mgdl: s.averageMgdl), value: s.averageMgdl)
                    figure("Low", unit.format(mgdl: s.lowestMgdl), value: s.lowestMgdl)
                    figure("High", unit.format(mgdl: s.highestMgdl), value: s.highestMgdl)
                    figure("In range", s.inRangeText, value: s.inRange, tint: GlucoseRange.inRange.textTint)
                    figure("Change", s.changeText(unit: unit), value: s.changeMgdl ?? 0)
                }
            } else {
                Text("No readings in this stretch")
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, DS.Space.xs + 2)
        .background { DSSurface(style: .standard, radius: DS.Radius.control) }
        .dsShadow(.medium)
    }

    private func figure(_ title: String, _ text: String, value: Double, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .dsFont(.eyebrow)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(text)
                .dsFont(.callout)
                .fontWeight(.bold)
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                // Each figure rolls to its new value as the span moves; under Reduce Motion it just
                // changes.
                .contentTransition(reduceMotion ? .identity : .numericText(value: value))
                .animation(reduceMotion ? nil : DSMotion.quick.animation, value: text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "45 min", "2 h", "2 h 5 min".
    static func durationText(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}

// MARK: - Forecast details

/// An invisible layer that only answers over the forecast's dashed line and likely range
/// (`ForecastDetails.outline`, padded so a thin range is still easy to hit). A tap or click there
/// opens the forecast details card; it's a tap gesture alongside the chart's own selection, so a
/// finger that moves is still a scrub, a hold is still the yesterday-line menu, and the page still
/// scrolls. Hidden from VoiceOver, which has "Show forecast details" on the chart instead.
private struct ForecastTapLayer: View {
    let proxy: ChartProxy
    let forecast: [ForecastSample]
    let unit: GlucoseUnit
    /// The glucose axis, in the unit shown, so a range running off the chart is cut at its edge.
    let yd: ClosedRange<Double>
    let tap: (Date) -> Void

    var body: some View {
        GeometryReader { geo in
            let origin = proxy.plotFrame.map { geo[$0].origin } ?? .zero
            let outline = ForecastDetails.outline(points(origin: origin))
            Color.clear
                .contentShape(ForecastOutlineShape(points: outline))
                .simultaneousGesture(
                    SpatialTapGesture(coordinateSpace: .local).onEnded { value in
                        guard let date = proxy.value(atX: value.location.x - origin.x, as: Date.self) else { return }
                        tap(date)
                    }
                )
        }
        .accessibilityHidden(true)
    }

    private func points(origin: CGPoint) -> [ForecastDetails.PlotPoint] {
        let clamp = { (mgdl: Double) -> Double in min(max(unit.value(fromMgdl: mgdl), yd.lowerBound), yd.upperBound) }
        return forecast.compactMap { s -> ForecastDetails.PlotPoint? in
            guard let x = proxy.position(forX: s.date),
                  let top = proxy.position(forY: clamp(s.upperMgdl)),
                  let bottom = proxy.position(forY: clamp(s.lowerMgdl)),
                  let line = proxy.position(forY: clamp(s.mgdl)) else { return nil }
            return ForecastDetails.PlotPoint(x: Double(origin.x + x), top: Double(origin.y + top),
                                             bottom: Double(origin.y + bottom), line: Double(origin.y + line))
        }
    }
}

/// The forecast's band as a closed shape: the only place the forecast tap layer answers.
private struct ForecastOutlineShape: Shape {
    let points: [(x: Double, y: Double)]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard let first = points.first else { return p }
        p.move(to: CGPoint(x: first.x, y: first.y))
        for pt in points.dropFirst() { p.addLine(to: CGPoint(x: pt.x, y: pt.y)) }
        p.closeSubpath()
        return p
    }
}

/// Where the forecast details popover points from: the forecast's line at the tapped point (or
/// the 30-minute point), opening below it when that's in the top half of the chart and above it
/// otherwise. The card is a popover kept a popover on iPhone, like the reading's details card, so
/// a tap anywhere else (or Esc on the Mac, or VoiceOver's escape gesture) closes it. Inside, the
/// card grows out of the line from its edge nearest it (`ForecastCardEntrance`), and `closing`
/// plays that backwards before the chart lets the popover go.
private struct ForecastPopoverAnchor: View {
    let proxy: ChartProxy
    let unit: GlucoseUnit
    let anchor: ForecastSample?
    @Binding var isPresented: Bool
    let details: ForecastDetails?
    let closing: Bool
    let close: () -> Void
    /// The card was dragged down and has dropped out (iPhone): let the popover go now.
    let dropped: () -> Void

    var body: some View {
        GeometryReader { geo in
            let plot = proxy.plotFrame.map { geo[$0] } ?? CGRect(origin: .zero, size: geo.size)
            let point = self.point(in: plot)
            let fromTop = ForecastCardEntrance.opensFromTop(pointY: point.y, plotMidY: plot.midY)
            Color.clear
                .frame(width: 8, height: 8)
                .allowsHitTesting(false)
                .popover(isPresented: $isPresented, arrowEdge: fromTop ? .bottom : .top) {
                    if let details {
                        ForecastDetailsCard(details: details, unit: unit, opensFromTop: fromTop,
                                            closing: closing, close: close, dropped: dropped)
                            .presentationCompactAdaptation(.popover)
                    }
                }
                .position(point)
        }
    }

    private func point(in plot: CGRect) -> CGPoint {
        guard let anchor, let x = proxy.position(forX: anchor.date),
              let y = proxy.position(forY: unit.value(fromMgdl: anchor.mgdl))
        else { return CGPoint(x: plot.midX, y: plot.midY) }
        return CGPoint(x: plot.minX + x, y: plot.minY + y)
    }
}

// MARK: Reading gaps

/// Which gaps' bridges have drawn in this launch, across every chart, so each draws in once.
@MainActor
private enum ReadingGapDrawInLog {
    static var shared = ReadingGapDrawIn()
}

/// The dashed bridges over gaps in readings (`ReadingGaps`), and the card for the one that's open.
/// The bridges are cut to the plot, as the trace is; the card may overhang it.
private struct ReadingGapLayer: View {
    let proxy: ChartProxy
    let gaps: [ReadingGaps.Gap]
    let unit: GlucoseUnit
    @Binding var open: Date?
    let check: ReadingGapCheck.Control?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Mac: where the pointer is, so moving it from a bridge onto its card (for Check Now) keeps
    /// the card up.
    @State private var overBridge = false
    @State private var overCard = false

    var body: some View {
        GeometryReader { geo in
            let plot = proxy.plotFrame.map { geo[$0] } ?? CGRect(origin: .zero, size: geo.size)
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(gaps) { gap in
                        if let a = point(gap.start, gap.startMgdl, plot: plot), let b = point(gap.end, gap.endMgdl, plot: plot) {
                            GapBridge(from: a, to: b, id: gap.id, highlighted: open == gap.id, reduceMotion: reduceMotion,
                                      tap: { toggle(gap.id) }, hover: { hovering(gap.id, $0) })
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .mask {
                    Rectangle()
                        .frame(width: plot.width, height: plot.height + 24)
                        .position(x: plot.midX, y: plot.midY)
                }
                if let id = open, let gap = gaps.first(where: { $0.id == id }),
                   let a = point(gap.start, gap.startMgdl, plot: plot), let b = point(gap.end, gap.endMgdl, plot: plot) {
                    card(gap, mid: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), plot: plot, height: geo.size.height)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .accessibilityHidden(true)
    }

    private func point(_ date: Date, _ mgdl: Double, plot: CGRect) -> CGPoint? {
        guard let x = proxy.position(forX: date), let y = proxy.position(forY: unit.value(fromMgdl: mgdl)) else { return nil }
        return CGPoint(x: plot.minX + x, y: plot.minY + y)
    }

    /// iPhone: a tap opens the card, a second tap closes it. Mac: a click does the same.
    private func toggle(_ id: Date) {
        withAnimation(ReadingGapCard.animation(reduceMotion)) { open = open == id ? nil : id }
    }

    /// Mac: the pointer resting on a bridge shows its card, and leaving it hides it, unless it
    /// went onto a card with Check Now (a moment's grace to get there).
    private func hovering(_ id: Date, _ inside: Bool) {
        overBridge = inside
        if inside {
            withAnimation(ReadingGapCard.animation(reduceMotion)) { open = id }
        } else {
            closeUnlessHovered(id)
        }
    }

    private func hoveringCard(_ id: Date, _ inside: Bool) {
        overCard = inside
        if !inside { closeUnlessHovered(id) }
    }

    private func closeUnlessHovered(_ id: Date) {
        let wait: TimeInterval = check == nil ? 0 : ReadingGapCheck.hoverGrace
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            guard !overBridge, !overCard, open == id else { return }
            withAnimation(ReadingGapCard.animation(reduceMotion)) { open = nil }
        }
    }

    /// The card above the bridge's middle (below it when that's near the top), kept inside the plot
    /// sideways. It never takes the pointer or a touch, so it can't steal the bridge's hover, except
    /// when it carries Check Now (`ReadingGapCheck`): then the card itself takes them.
    @ViewBuilder
    private func card(_ gap: ReadingGaps.Gap, mid: CGPoint, plot: CGRect, height: CGFloat) -> some View {
        let width = min(ReadingGapCard.width, plot.width)
        let cx = min(max(mid.x, plot.minX + width / 2), plot.maxX - width / 2)
        let above = mid.y > plot.minY + plot.height * 0.45
        let room = above ? max(mid.y - 10, 0) : max(height - mid.y - 10, 0)
        let offered: ReadingGapCheck.Control? = ReadingGapCheck.offers(gap, among: gaps) ? check : nil
        ReadingGapCard(gap: gap, check: offered)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            #if os(macOS)
            .onHover { hoveringCard(gap.id, $0) }
            #endif
            .frame(width: width, height: room, alignment: above ? .bottom : .top)
            .position(x: cx, y: above ? room / 2 : mid.y + 10 + room / 2)
            .allowsHitTesting(offered != nil)
            .transition(reduceMotion ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.92, anchor: above ? .bottom : .top)))
            .id(gap.id)
    }
}

/// A straight line from the last reading before a gap to the first after it.
private struct GapLine: Shape {
    let from: CGPoint
    let to: CGPoint

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: from)
        p.addLine(to: to)
        return p
    }
}

/// One gap's dashed bridge. It draws in from left to right the first time it's shown this launch
/// (`ReadingGapDrawIn`), then holds; under Reduce Motion it's simply there.
private struct GapBridge: View {
    let from: CGPoint
    let to: CGPoint
    let highlighted: Bool
    let tap: () -> Void
    let hover: (Bool) -> Void
    let id: Date
    let reduceMotion: Bool
    @State private var progress: CGFloat = 0

    init(from: CGPoint, to: CGPoint, id: Date, highlighted: Bool, reduceMotion: Bool,
         tap: @escaping () -> Void, hover: @escaping (Bool) -> Void) {
        self.from = from
        self.to = to
        self.highlighted = highlighted
        self.tap = tap
        self.hover = hover
        self.id = id
        self.reduceMotion = reduceMotion
    }

    var body: some View {
        ZStack {
            GapLine(from: from, to: to)
                .trim(from: 0, to: progress)
                .stroke(Palette.stale.opacity(highlighted ? 0.95 : 0.7),
                        style: StrokeStyle(lineWidth: highlighted ? 2 : 1.5, lineCap: .round, dash: [3, 4]))
                .allowsHitTesting(false)
            Color.clear
                .contentShape(GapLine(from: from, to: to).stroke(style: StrokeStyle(lineWidth: 24, lineCap: .round)))
                #if os(iOS)
                .simultaneousGesture(TapGesture().onEnded { tap() })
                #else
                .onTapGesture { tap() }
                .onHover { hover($0) }
                #endif
        }
        .onAppear {
            guard progress < 1 else { return }
            // Counted only once it's on screen, so a view that's made but never shown doesn't use
            // up the gap's one draw-in. Any later bridge for the gap starts whole.
            if ReadingGapDrawInLog.shared.shouldDraw(id, reduceMotion: reduceMotion) {
                withAnimation(.easeOut(duration: ReadingGaps.drawInDuration)) { progress = 1 }
            } else {
                withTransaction(Transaction(animation: nil)) { progress = 1 }
            }
        }
    }
}

/// What a gap's card says: why, when and how long, and one sentence more.
private struct ReadingGapCard: View {
    let gap: ReadingGaps.Gap
    /// Given, the card ends with Check Now and the last check's result.
    var check: ReadingGapCheck.Control? = nil

    static let width: CGFloat = 230

    static func animation(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : DSMotion.quick.animation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(gap.reason.title).fontWeight(.semibold)
            } icon: {
                Image(systemName: gap.reason.systemImage).foregroundStyle(.secondary)
            }
            .dsFont(.callout)
            Text(ReadingGaps.span(gap))
                .dsFont(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(gap.reason.detail)
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let check {
                ReadingGapCheckRow(check: check)
                    .padding(.top, DS.Space.xxs)
            }
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, DS.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { DSSurface(style: .standard, radius: DS.Radius.control) }
        .dsShadow(.medium)
    }
}

/// Check Now and what the last check found, at the foot of a gap's card (`ReadingGapCheck`). The
/// button's spinner turns into a check mark (or an alert mark) when the fetch lands; under Reduce
/// Motion it simply swaps. While the 30 seconds after a tap run out the button says how long is
/// left, ticking once a second only until then.
private struct ReadingGapCheckRow: View {
    let check: ReadingGapCheck.Control
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.explicit(tickDates(from: Date()))) { context in
            row(now: context.date)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : DSMotion.quick.animation, value: check.status)
    }

    /// One tick a second until the button works again, then none.
    private func tickDates(from now: Date) -> [Date] {
        let left = Int(check.status.wait(at: now).rounded(.up))
        guard left > 0 else { return [now] }
        return (0...left).map { now.addingTimeInterval(Double($0)) }
    }

    @ViewBuilder
    private func row(now: Date) -> some View {
        let status = check.status
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Button(action: check.run) {
                HStack(spacing: DS.Space.xs) {
                    statusIcon(status)
                    Text(status.buttonTitle(at: now)).monospacedDigit()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!status.canCheck(at: now))
            if let outcome = status.outcome {
                Text(outcome.line)
                    .dsFont(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(outcome.succeeded ? Color.primary : Palette.amberText)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: ReadingGapCheck.Status) -> some View {
        ZStack {
            if status.running {
                ProgressView().controlSize(.mini)
                    .transition(.opacity)
            } else if let outcome = status.outcome {
                Image(systemName: outcome.systemImage)
                    .foregroundStyle(outcome.succeeded ? Palette.brandText : Palette.amberText)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
            } else {
                Image(systemName: "arrow.clockwise")
                    .transition(.opacity)
            }
        }
        .frame(width: 14, height: 14)
    }
}

// MARK: - Panning back (`ChartPan`)

extension GlucoseChart {
    /// The newest and oldest readings and the span on screen, which bound a pan.
    private var panBounds: (newest: Date, oldest: Date, hours: Double)? {
        guard let newest = readings.last?.timestamp, let oldest = readings.first?.timestamp else { return nil }
        return (newest, oldest, (range ?? .init(hours: hours)).domainHours)
    }

    /// What VoiceOver hears first while panned back; nothing at now.
    private func panSpoken(_ pan: Date?) -> String {
        guard let pan, let b = panBounds else { return "" }
        return "Earlier, " + ChartPan.spoken(end: pan, newest: b.newest, hours: b.hours, clock: { ClockLabel.time($0) }) + ". "
    }

    /// A drag along the time axis, or a sideways trackpad swipe, has moved `points` since it began.
    /// The trace follows the fingers directly, with no animation.
    private func panMoved(points: Double, secondsPerPoint: Double) {
        guard pansBack, interactive, span == nil, let b = panBounds else { return }
        if panFrom == nil {
            // Panning takes over from anything else on the chart.
            panFrom = .some(shownPan)
            panGeneration += 1
            if callout != nil { closeCallout() }
            closeForecast(animated: false)
            withTransaction(Transaction(animation: nil)) {
                hoverDate = nil
                touching = false
                scrubbedFrom = nil
                peeked = nil
                openGap = nil
                panTrail = nil
            }
        }
        let next = ChartPan.moved(from: panFrom ?? nil, points: points, secondsPerPoint: secondsPerPoint,
                                  newest: b.newest, oldest: b.oldest, hours: b.hours)
        withTransaction(Transaction(animation: nil)) { panEnd = next }
    }

    /// The fingers lifted: left close to now, it springs the rest of the way back.
    private func panEnded() {
        guard panFrom != nil else { return }
        panFrom = nil
        guard let b = panBounds else { return }
        let settled = ChartPan.released(shownPan, newest: b.newest)
        if settled != shownPan { glidePan(to: settled) }
        announcePan(settled)
    }

    /// ⌥← ⌥→ or ⌘→ on the Mac: an hour either way, or straight home, gliding like Now.
    private func panKeyed(_ move: ChartPan.KeyMove) {
        guard pansBack, interactive, panFrom == nil, let b = panBounds else { return }
        let target = ChartPan.keyed(shownPan, move, newest: b.newest, oldest: b.oldest, hours: b.hours)
        guard target != shownPan else { return }
        if callout != nil { closeCallout() }
        closeForecast(animated: false)
        withTransaction(Transaction(animation: nil)) {
            hoverDate = nil
            peeked = nil
            openGap = nil
        }
        glidePan(to: target)
        announcePan(target)
    }

    /// Reads the end-time label once when a pan settles on a new end (`ChartPan.announces`).
    /// Back at now the label fades and the next pan is read again.
    private func announcePan(_ settled: Date?) {
        guard let settled else { panSpokenEnd = nil; return }
        guard ChartPan.announces(settled: settled, lastSpoken: panSpokenEnd) else { return }
        panSpokenEnd = settled
        var spoken = AttributedString(ChartPan.endSpoken(settled))
        spoken.accessibilitySpeechAnnouncementPriority = .low
        AccessibilityNotification.Announcement(spoken).post()
    }

    /// One VoiceOver swipe on the time axis: down for earlier, up for later.
    private func panStepped(earlier: Bool) {
        guard let b = panBounds else { return }
        glidePan(to: ChartPan.stepped(shownPan, earlier: earlier, newest: b.newest, oldest: b.oldest, hours: b.hours))
    }

    /// Moves the right edge to `target` (nil: now) the way the span changes: a spring, with what
    /// was on screen kept plotted on the way so the trace slides through, or a cross-fade with no
    /// movement under Reduce Motion.
    private func glidePan(to target: Date?) {
        let from = shownPan
        guard target != from, let b = panBounds else { return }
        panGeneration += 1
        let generation = panGeneration
        guard !reduceMotion else {
            withAnimation(Self.spanFadeAnimation) {
                panEnd = target
                panTrail = nil
                spanFade += 1
            }
            return
        }
        let edge = from ?? b.newest
        withTransaction(Transaction(animation: nil)) { panTrail = edge.addingTimeInterval(-b.hours * 3600)...edge }
        // On the next turn, so the readings on the way are already plotted when the axis moves.
        DispatchQueue.main.async {
            withAnimation(Self.spanSpring, completionCriteria: .logicallyComplete) {
                panEnd = target
            } completion: {
                guard generation == panGeneration else { return }
                withTransaction(Transaction(animation: nil)) { panTrail = nil }
            }
        }
    }

    /// The time-axis strip, the Now button, the trackpad's sideways scrolling and what the screen
    /// around the chart is told, kept out of `body`'s chain so it still type-checks in reasonable time.
    fileprivate func withPan(_ chart: some View, domain: ClosedRange<Date>, pan: Date?) -> some View {
        let secondsPerPoint = plotWidth > 0 ? domain.upperBound.timeIntervalSince(domain.lowerBound) / plotWidth : 0
        let b = panBounds
        return chart
            // After the chart's own VoiceOver element, so the strip and the button are elements of their own.
            .chartOverlay { proxy in
                if pansBack, interactive, let b {
                    ChartPanLayer(proxy: proxy, pan: pan,
                                  behind: pan.map { ChartPan.behindLabel($0, newest: b.newest) },
                                  endLabel: ChartPan.endLabel(pan),
                                  spoken: ChartPan.spoken(end: pan, newest: b.newest, hours: b.hours,
                                                          clock: { ClockLabel.time($0) }),
                                  canPan: ChartPan.earliestEnd(newest: b.newest, oldest: b.oldest, hours: b.hours) != nil,
                                  reduceMotion: reduceMotion,
                                  moved: { panMoved(points: $0, secondsPerPoint: secondsPerPoint) },
                                  ended: { panEnded() },
                                  now: { glidePan(to: nil); announcePan(nil) },
                                  step: { panStepped(earlier: $0) })
                }
            }
            .preference(key: ChartPanKey.self, value: pansBack ? pan : nil)
            .onChange(of: panScroll) { _, scroll in
                guard let scroll else { return }
                // The last movement can arrive in the same update as the end, so it's applied first.
                if !scroll.ended || panFrom != nil { panMoved(points: scroll.points, secondsPerPoint: secondsPerPoint) }
                if scroll.ended { panEnded() }
            }
            .onChange(of: panKey) { _, press in
                guard let press else { return }
                panKeyed(press.move)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { withTransaction(Transaction(animation: nil)) { panEnd = nil; panFrom = nil } }
            }
    }
}

/// A sideways trackpad swipe over the Mac popover's chart, passed to `GlucoseChart.panScroll`:
/// how far the content has been moved since the swipe began (positive: to the right, showing
/// earlier), or that it has ended. `id` changes with every event, so each one is seen.
struct ChartPanScroll: Equatable {
    var id = 0
    var points: Double = 0
    var ended = false
}

/// A pan key pressed on the Mac while the chart has the focus, passed to `GlucoseChart.panKey`.
/// `id` changes with every press, so pressing the same key again is seen.
struct ChartPanKeyPress: Equatable {
    var id = 0
    var move: ChartPan.KeyMove
}

/// Where a panned chart's right edge is (`GlucoseChart.pansBack`), nil while it shows now, so the
/// screen around it can follow (the Mac popover's arrow keys step through what's on screen).
struct ChartPanKey: PreferenceKey {
    static let defaultValue: Date? = nil
    static func reduce(value: inout Date?, nextValue: () -> Date?) { value = value ?? nextValue() }
}

/// The strip along the time axis that a finger (or the pointer) drags to pan, and the Now button
/// that springs back. VoiceOver reads the strip as "Chart time", swiping down for earlier hours.
private struct ChartPanLayer: View {
    let proxy: ChartProxy
    let pan: Date?
    let behind: String?
    /// "Tue 2:40 pm": the moment at the right edge, under the Now button while panned.
    let endLabel: String?
    let spoken: String
    let canPan: Bool
    let reduceMotion: Bool
    let moved: (Double) -> Void
    let ended: () -> Void
    let now: () -> Void
    let step: (Bool) -> Void

    @State private var dragging = false
    /// Decided on the first movement: sideways pans, up or down is left alone.
    @State private var sideways: Bool?

    var body: some View {
        GeometryReader { geo in
            if let frame = proxy.plotFrame {
                let plot = geo[frame]
                let height = max(22, geo.size.height - plot.maxY + 4)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(dragging ? 0.06 : 0.001))
                    .frame(width: plot.width, height: height)
                    .contentShape(Rectangle())
                    .position(x: plot.midX, y: plot.maxY + height / 2)
                    .gesture(drag, including: canPan ? .all : .none)
                    .animation(DSMotion.quick.animation, value: dragging)
                    .accessibilityElement()
                    .accessibilityLabel("Chart time")
                    .accessibilityValue(spoken)
                    .accessibilityHint("Swipe down for earlier hours, up for later.")
                    // With no earlier readings there's nothing to pan to, and nothing to say.
                    .accessibilityHidden(!canPan)
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .decrement: step(true)
                        case .increment: step(false)
                        @unknown default: break
                        }
                    }
                    #if os(macOS)
                    .help("Drag along the times, or swipe sideways on the trackpad, to see earlier hours")
                    #endif
                VStack(alignment: .trailing, spacing: 3) {
                    if let behind, pan != nil {
                        nowButton(behind)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.85, anchor: .topTrailing).combined(with: .opacity))
                    }
                    // Fades in as the chart leaves now and out as it comes back. VoiceOver hears
                    // it once as a pan settles (`ChartPan.announces`), not here as well.
                    if let endLabel, pan != nil {
                        endTime(endLabel)
                            .transition(.opacity)
                    }
                }
                .padding(6)
                .frame(width: plot.width, height: plot.height, alignment: .topTrailing)
                .position(x: plot.midX, y: plot.midY)
                .animation(reduceMotion ? GlucoseChart.spanFadeAnimation : DSMotion.quick.animation, value: pan != nil)
            }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { v in
                if sideways == nil { sideways = abs(v.translation.width) >= abs(v.translation.height) }
                guard sideways == true else { return }
                if !dragging { dragging = true }
                moved(v.translation.width)
            }
            .onEnded { _ in
                if sideways == true { ended() }
                sideways = nil
                dragging = false
            }
    }

    private func endTime(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(reduceMotion ? nil : DSMotion.quick.animation, value: text)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.thinMaterial, in: Capsule())
            .fixedSize()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func nowButton(_ behind: String) -> some View {
        Button(action: now) {
            HStack(spacing: 4) {
                Text(behind)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.forward.to.line")
                    .imageScale(.small)
                Text("Now")
                    .fontWeight(.semibold)
            }
            .font(.caption2)
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to now")
        .accessibilityValue(behind)
        #if os(macOS)
        .help("Back to the newest reading")
        #endif
    }
}
