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
                           forecastEnd: forecast.last?.date, lead: lead)
    }

    /// The glucose axis fits what's on screen at the span being shown (and the few readings just
    /// past the left edge, so they never poke out of the top or bottom as they leave). Extra data
    /// plotted only while the range changes doesn't count, so the axis rescales in the same
    /// movement as the time axis.
    private func yDomainMgdl(_ onScreen: ArraySlice<GlucoseReading>, extra: [Double]) -> ClosedRange<Double> {
        let values = onScreen.map(\.mgdl) + [lowMgdl, highMgdl] + forecast.map(\.mgdl) + extra
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
    private func selection(newest: Date?) -> Binding<Date?> {
        Binding(get: { hoverDate }, set: { new in
            if let new {
                // A peek has the finger, or two fingers are picking a span: the readout stays
                // away until they lift.
                // A scrub starting while a callout is open only closes it.
                if callout != nil { closeCallout(); return }
                guard peeked == nil, span == nil, spanTouch == nil else { return }
                if !touching { touching = true; scrubbedFrom = nil }
                touchGeneration += 1
                hoverDate = new
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
        if let from = scrubbedFrom,
           let tick = ChartScrub.tick(from: from, to: date, readings: window, lowMgdl: lowMgdl,
                                      highMgdl: highMgdl, logged: events.map(\.date)) {
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

    /// The markers that can be peeked at: on screen and not still popping in.
    private func peekable(_ window: [GlucoseReading]) -> [ChartLogMarker] {
        let start = window.first?.timestamp ?? .distantFuture
        let inFlight = Set(flights.map(\.marker.id))
        return events.filter { $0.date >= start && !inFlight.contains($0.id) }
    }

    /// Whether a tap on a marker opens its callout.
    private var opensCallouts: Bool { interactive && openInLogbook != nil }

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
                        tap: opensCallouts ? { tapMarker($0) } : nil)
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
    /// marker, or closes when it was already open (`MarkerCallout.toggled`).
    private func tapMarker(_ id: UUID) {
        let next = MarkerCallout.toggled(open: callout, tapped: id)
        guard next != nil else { closeCallout(); return }
        withTransaction(Transaction(animation: nil)) {
            hoverDate = nil
            touching = false
            scrubbedFrom = nil
            peeked = nil
        }
        #if os(iOS)
        Haptics.play(.scrubLogged)
        #endif
        withAnimation(MarkerCalloutMotion.animation(showing: true, reduceMotion: reduceMotion)) { callout = next }
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
        if opensCallouts {
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
                                                  open: callout == m.id) { tapMarker(m.id) }
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
                          open: { openCalloutEntry(m.id) }, close: closeCallout)
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
        endSpanTouch()
        onScreen = false
        glows = []
        peeked = nil
        pressingMarker = false
        callout = nil
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

    private func color(for mgdl: Double) -> Color {
        GlucoseRange.classify(mgdl: mgdl, low: lowMgdl, high: highMgdl).color
    }

    var body: some View {
        let cw = chartWindow
        let window = Array(cw?.visible ?? [])
        let plotted = Array(cw?.plotted ?? [])
        // On screen at the span being shown, plus the lead past the left edge: not the extra
        // data plotted only while the span changes.
        let onScreen = ChartSpan(readings: readings, domainHours: (range ?? .init(hours: hours)).domainHours,
                                   dataHours: 0, forecastEnd: forecast.last?.date, lead: lead)?.plotted ?? []
        // Yesterday's faint line, over what's plotted (and on under the forecast), so it moves with
        // the trace when the span changes. Its highs and lows count towards the glucose axis, so
        // it's never cut off at the top or bottom.
        let domain = cw?.domain ?? Date().addingTimeInterval(-hours * 3600)...Date()
        let ghost = yesterday.isEmpty ? [] : YesterdayLine.points(
            readings: yesterday, from: min(plotted.first?.timestamp ?? domain.lowerBound, domain.lowerBound),
            to: domain.upperBound)
        let yd = yDomain(onScreen, extra: ghost.map(\.mgdl))
        let floor = yd.lowerBound
        let hovered = interactive && peeked == nil && callout == nil && span == nil
            ? nearest(to: hoverDate ?? pinnedDate, in: window) : nil
        // The gradient is stretched over the drawn line, so its stops follow what's plotted.
        let lineStyle = ThresholdGradient.style(minMgdl: plotted.map(\.mgdl).min() ?? lowMgdl,
                                                maxMgdl: plotted.map(\.mgdl).max() ?? highMgdl,
                                                low: lowMgdl, high: highMgdl)
        let stale = latestIsStale
            ?? (window.last.map { Date().timeIntervalSince($0.timestamp) > GlucoseSnapshot.staleAfter } ?? true)
        let currentTint = stale ? Palette.stale : (window.last.map { color(for: $0.mgdl) } ?? Palette.stale)
        let projection = stale ? [] : forecast
        // What's drawn of it so far. Indexed rather than keyed by time, so the marks keep their
        // identity while a new forecast slides and bends into place (`ForecastMotion`).
        let drawn = Array(ForecastMorph.revealed(projection, progress: forecastReveal).enumerated())
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

            // Soft glow under the trace, tinted with the current range.
            ForEach(plotted) { r in
                AreaMark(
                    x: .value("Time", r.timestamp),
                    yStart: .value("Floor", floor),
                    yEnd: .value("Glucose", unit.value(fromMgdl: r.mgdl))
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(colors: [currentTint.opacity(0.28), currentTint.opacity(0.0)],
                                   startPoint: .top, endPoint: .bottom)
                )
            }

            // Time spent out of range, filled between the trace and the line it crossed, so a
            // high or a low reads as a shape before anyone looks at the numbers.
            outOfRangeMarks(plotted)

            // The trace changes colour as it crosses the thresholds.
            ForEach(plotted) { r in
                LineMark(
                    x: .value("Time", r.timestamp),
                    y: .value("Glucose", unit.value(fromMgdl: r.mgdl))
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(lineStyle)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }

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

            // Current reading: solid dot with a soft halo.
            if let last = window.last {
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
                    .padding(.trailing, -48)
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
            // A slow ring breathing out of the newest reading while readings are arriving. App
            // screens only: widgets and the Live Activity don't animate, and it holds still (it
            // isn't drawn) under Reduce Motion or once the reading is stale.
            if interactive, !stale, !reduceMotion, let last = window.last {
                if ripplesNewReading {
                    // Once per new reading, then nothing until the next (see `newestChanged`).
                    ReadingDotRipple(proxy: proxy, date: last.timestamp, value: unit.value(fromMgdl: last.mgdl),
                                     tint: currentTint, beat: rippleBeat)
                } else {
                    TracePulse(proxy: proxy, date: last.timestamp, value: unit.value(fromMgdl: last.mgdl), tint: currentTint)
                }
            }
            markerOverlays(proxy: proxy, yd: yd)
            if interactive, peeksMarkers || opensCallouts {
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
            // Hours changing under two fingers means they were pinching, not picking a span.
            if var touch = spanTouch { touch.wasPinch = true; spanTouch = touch }
            voSpanMinutes = ChartSpanVoiceOver.clamped(voSpanMinutes, hours: new)
        }
        .onChange(of: readings.last?.timestamp) { old, new in newestChanged(from: old, to: new) }
        .hoverSelection(interactive, selection(newest: window.last?.timestamp))
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
        .accessibilityValue(voiceOverSpanSentence(window: window) ?? (ChartSummary.sentence(.init(
            readings: window, lowMgdl: lowMgdl, highMgdl: highMgdl, unit: unit, hours: hours, stale: stale,
            forecastEnd: projection.last,
            loggedCount: events.filter { $0.date >= (window.first?.timestamp ?? .distantFuture) }.count))
            + yesterdaySpoken(newest: window.last)))
        .spanAdjustable(interactive && selectsSpans, adjustVoiceOverSpan)
        .accessibilityChartDescriptor(GlucoseAudioGraph(readings: window, forecast: projection, unit: unit,
                                                        lowMgdl: lowMgdl, highMgdl: highMgdl, yDomain: yd,
                                                        yesterday: ghost.filter { $0.date >= domain.lowerBound }))
        withCallouts(chart, window: window, yd: yd)
    }

    /// The marker callout's overlay and the moments that close it, kept out of `body`'s chain so it
    /// still type-checks in reasonable time.
    private func withCallouts(_ chart: some View, window: [GlucoseReading], yd: ClosedRange<Double>) -> some View {
        chart
            // After the chart's own VoiceOver element, so its marker buttons and the callout are
            // elements of their own rather than folded into the summary.
            .chartOverlay { proxy in calloutLayer(proxy: proxy, yd: yd, window: window) }
            .preference(key: MarkerCalloutOpenKey.self, value: callout != nil)
            .onChange(of: peekable(window).map(\.id)) { _, ids in calloutMarkersChanged(ids) }
            .onChange(of: closesCallout) { _, _ in closeCallout() }
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

    /// Fills above the high line and below the low line wherever the trace goes past them.
    @ChartContentBuilder
    func outOfRangeMarks(_ window: [GlucoseReading]) -> some ChartContent {
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
                    series: .value("Series", "Above range")
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
                    series: .value("Series", "Below range")
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
    private(set) var count = 0
    private(set) var tick: ChartScrub.Tick?

    mutating func fire(_ tick: ChartScrub.Tick) {
        count += 1
        self.tick = tick
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
                switch new.tick {
                case .rangeEdge: return .scrubRangeEdge
                case .logged: return .scrubLogged
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
    #if os(iOS)
    @State private var hold: Task<Void, Never>?
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
            }
        } else if !peeking, !MarkerPeek.isHolding(dx: Double(value.translation.width), dy: Double(value.translation.height)) {
            hold?.cancel()
            hold = nil
            downOn = nil
            pressing(false)
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
        pressing(false)
        if let tapped, let tap { tap(tapped) }
    }
    #endif

    #if os(macOS)
    fileprivate func hovered(_ phase: HoverPhase, spots: [MarkerPeek.Spot]) {
        switch phase {
        case .active(let p): peek(MarkerPeek.hit(x: Double(p.x), y: Double(p.y), in: spots))
        case .ended: peek(nil)
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
    let action: () -> Void

    var body: some View {
        Color.primary.opacity(0.001)
            .frame(width: 28, height: 28)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(open ? "Closes what was logged." : "Shows what was logged, with Open in Logbook.")
            .accessibilityAction { action() }
    }
}

/// The callout: the marker's own symbol, what it was, the amount, when, the note, and Open in
/// Logbook. It only repeats what was logged.
private struct MarkerCalloutCard: View {
    let marker: ChartLogMarker
    let content: MarkerCallout.Content
    let time: String
    var voiceOverFocus: AccessibilityFocusState<Bool>.Binding
    let open: () -> Void
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
