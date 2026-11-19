import SwiftUI
import AppKit

/// The recent-history chart. Hover to inspect a reading, or click the chart and step through
/// readings with the arrow keys (Home / End jump to the ends, Escape clears).
struct PopoverChartCard: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var logbook: LogbookStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow

    var showsShortcuts: Bool
    /// When the forecast starts drawing in after the popover opens, so it follows the card's own
    /// entrance (`PopoverStagger.forecastDelay`).
    var forecastDelay: TimeInterval = 0

    @FocusState private var chartFocused: Bool
    @State private var pinned: Date?
    /// Whether a marker's callout is open on the chart (`MarkerCalloutOpenKey`), and a counter that
    /// closes it, so Esc closes the callout before anything else.
    @State private var calloutOpen = false
    @State private var closeCallout = 0
    /// A right-click over a marker opens its peek card (`MarkerActions`) instead of the
    /// yesterday-line menu: the monitor takes it while the chart says the pointer is on one.
    @State private var rightClicks = MarkerRightClickMonitor()
    @State private var pinHovered = 0
    /// Bumped by Return on the chart, to open the forecast details card (`ForecastDetails`).
    @State private var forecastKey = 0
    /// Where the chart's right edge is while it's panned back (`ChartPanKey`), nil at now, so the
    /// arrow keys, the header and VoiceOver follow what's on screen.
    @State private var panEnd: Date?
    /// Sideways trackpad swipes over the chart pan it back (`ChartPan`).
    @State private var scrollPan = ChartScrollPanMonitor()
    @State private var panScroll: ChartPanScroll?
    /// ⌥← ⌥→ pan an hour, ⌘→ goes back to now, while the chart has the focus.
    @State private var panKey: ChartPanKeyPress?

    private var s: GlucoseSnapshot { store.snapshot }

    /// What the chart is handed whatever span is picked: the longest (24 hours), its lead and the
    /// day it can pan back (`ChartPan`), from the archive as well as the live snapshot
    /// (LibreLinkUp only sends 12 hours), so switching span glides rather than waiting on data.
    private var plotted: [GlucoseReading] { store.readings(lastHours: ChartPan.hoursHanded) }

    /// Readings back to a day before the longest span, for yesterday's line, while it's on.
    private var yesterday: [GlucoseReading] {
        settings.showYesterdayLine ? store.readings(lastHours: YesterdayLine.hoursNeeded(forSpan: ChartPan.hoursHanded)) : []
    }

    /// The readings the chart is showing, oldest → newest: back from the newest reading, or from
    /// the right edge while the chart is panned back.
    private func window(in plotted: [GlucoseReading]) -> [GlucoseReading] {
        guard let last = plotted.last else { return [] }
        let end = min(panEnd ?? last.timestamp, last.timestamp)
        let cutoff = end.addingTimeInterval(-Double(settings.chartHours) * 3600)
        let upper = PeriodSpan.firstIndex(in: plotted, after: end)
        let lower = min(ChartSpan.firstIndex(in: plotted, atOrAfter: cutoff), upper)
        return Array(plotted[lower..<upper])
    }

    var body: some View {
        let plotted = self.plotted
        let window = self.window(in: plotted)
        VStack(alignment: .leading, spacing: 10) {
            // While a reading is pinned, it takes the header's place rather than pushing the
            // chart down, so the popover doesn't change height under the pointer.
            ZStack(alignment: .leading) {
                if let date = pinned, let r = window.first(where: { $0.timestamp == date }) {
                    readout(r, in: window)
                        .transition(.opacity)
                } else {
                    header
                        .transition(.opacity)
                }
            }
            .frame(height: 24)
            .animation(PopoverMotion.quick(reduceMotion), value: pinned)
            let outlook = s.currentOutlook()
            // The forecast draws in as the popover opens, once its card is most of the way in, and
            // bends into each new one.
            ForecastMotion(forecast: settings.showForecast ? (outlook?.forecast ?? []) : [],
                           drawInDelay: forecastDelay) { forecast, reveal in
                GlucoseChart(readings: plotted, unit: store.shownUnit, lowMgdl: s.lowMgdl, highMgdl: s.highMgdl,
                             hours: Double(settings.chartHours), interactive: true, pinnedDate: pinned,
                             forecast: forecast, forecastReveal: reveal, events: markers, popsMarkers: true, ripplesNewReading: true,
                             yesterday: yesterday, peeksMarkers: true,
                             openInLogbook: openInLogbook, closesCallout: closeCallout, snapsScrub: true,
                             markerActions: markerAction, pinsHoveredMarker: pinHovered,
                             forecastDetails: details(outlook), opensForecastDetails: forecastKey,
                             gapContext: store.gapContext, gapCheck: store.gapCheckControl,
                             pansBack: true, panScroll: panScroll, panKey: panKey)
            }
                .onPreferenceChange(MarkerCalloutOpenKey.self) { calloutOpen = $0 }
                // Panned back: a pinned reading that's gone off screen is let go.
                .onPreferenceChange(ChartPanKey.self) { end in
                    guard end != panEnd else { return }
                    panEnd = end
                    pinned = nil
                }
                // Two fingers sideways on the trackpad pan the chart back; up and down still scroll.
                .onHover { scrollPan.over = $0 }
                .onAppear { scrollPan.start { panScroll = $0 } }
                .onDisappear { scrollPan.stop() }
                .onPreferenceChange(MarkerHoveredKey.self) { rightClicks.armed = $0 }
                .onAppear { rightClicks.start { pinHovered += 1 } }
                .onDisappear { rightClicks.stop() }
                .frame(height: 136)
                .focusable()
                .focused($chartFocused)
                .focusEffectDisabled()
                // In the popover's arrow-key order: ↑ ↓ leave the chart, ← → still step readings.
                // Return opens the forecast details card while a forecast is drawn.
                .keyStop("popover.chart", kind: .native,
                         action: details(outlook) == nil ? nil : { forecastKey += 1 })
                .overlay {
                    if chartFocused && pinned != nil {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1.5)
                            .padding(-4)
                            .allowsHitTesting(false)
                    }
                }
                // ← → step readings; ⌥← ⌥→ pan an hour and ⌘→ goes back to now (`ChartPan.KeyMove`).
                .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                    let left = press.key == .leftArrow
                    if let move = ChartPanKeys.move(left: left, modifiers: press.modifiers) {
                        guard let next = ChartPanKeys.press(move, after: panKey, pannedBack: panEnd != nil) else { return .ignored }
                        panKey = next
                        return .handled
                    }
                    guard press.modifiers.intersection([.command, .option, .control]).isEmpty else { return .ignored }
                    return step(left ? -1 : 1, in: window)
                }
                .onKeyPress(.home) { jump(to: window.first) }
                .onKeyPress(.end) { jump(to: window.last) }
                .onKeyPress(.escape) {
                    // A marker's callout first, then a pinned reading, then the popover itself.
                    if calloutOpen {
                        closeCallout += 1
                        return .handled
                    }
                    guard pinned != nil else { return .ignored }   // let Escape close the popover
                    pinned = nil
                    return .handled
                }
                .onChange(of: chartFocused) { _, focused in if !focused { pinned = nil } }
                // The chart glides to the new span itself.
                .onChange(of: settings.chartHours) { _, _ in pinned = nil }
                // Pinch on the trackpad steps through the spans, as on iPhone.
                .chartHoursPinch($settings.chartHours)
                // Right-click for yesterday's faint line (also in Settings → Menu Bar); right-click a
                // marker for its Edit / Log Again Now card instead.
                .yesterdayLineMenu($settings.showYesterdayLine)
                .help("Hover to see readings, click a marker for what was logged, right-click it to edit or log it again, click the forecast for its details, swipe sideways for earlier hours, or click and use ← → (⌥← ⌥→ for an hour earlier or later, ⌘→ for now)")
                // A group, so its name doesn't land on the marker buttons inside it.
                .accessibilityElement(children: .contain)
                .accessibilityLabel(panEnd == nil ? "Glucose chart, last \(settings.chartHours) hours"
                                    : "Glucose chart, \(settings.chartHours) hours to \(ClockLabel.time(panEnd ?? Date()))")
                .accessibilityValue(chartSummary(window))
                .accessibilityHint("Use the left and right arrow keys to step through readings. Option with an arrow moves an hour earlier or later, Command right arrow goes back to now.")
            // "Meal 1 h 40 m ago · 45 g": the last thing logged in 12 hours, opening in the Logbook.
            LastLoggedLine(entries: logbook.entries, open: openInLogbook)
            if let outlook, outlook.showsInsulin || (settings.showForecast && !outlook.forecast.isEmpty) {
                OutlookSummaryRow(outlook: settings.showForecast ? outlook : withoutForecast(outlook),
                                  unit: store.shownUnit, lowMgdl: s.lowMgdl)
            }
            // Above range only, never with a low expected, and only while this Mac's own checks
            // of the estimate stay within 15 minutes (`GlucoseSnapshot.backInRange`).
            if settings.showForecast, let back = s.backInRange() {
                BackInRangeNote(minutes: back.minutes)
                    .dsFont(.label)
                    .foregroundStyle(.secondary)
                    .help("Forecast, not a reading: when the forecast comes back down to \(store.shownUnit.format(mgdl: s.highMgdl, withUnit: true)). Shown only while this Mac's past estimates were typically within 15 minutes.")
                    .transition(.opacity)
            }
        }
        .dsCard(.standard)
    }

    /// Doses, meals, wake-ups and notes over the longest range (24 hours), whatever's on screen, so
    /// switching range doesn't count as markers arriving. Something just logged pops in.
    private var markers: [ChartLogMarker] {
        ChartLogMarker.logbook(doses: logbook.doses, meals: logbook.meals, contexts: logbook.contexts,
                               since: Date().addingTimeInterval(-ChartPan.hoursHanded * 3600))
    }

    /// The dashboard, on the Logbook with this entry selected (`DashboardRequest`).
    private func openInLogbook(_ id: UUID) {
        DashboardRequest.shared.logbookEntry = id
        openWindow(id: DashboardView.windowID)
        NSApp.activate()
    }

    /// Edit or Log Again Now on a marker's peek card. Edit opens the log window on the entry;
    /// Log Again Now logs the same entry at the current time (`LogEntry.copied`), as the Logbook's
    /// right-click menu does, and its marker pops in. Gone meanwhile (deleted on the iPhone): nothing.
    private func markerAction(_ action: MarkerActions.Action, _ id: UUID) {
        guard let entry = logbook.entry(id: id) else { return }
        switch action {
        case .edit:
            LogWindowRequest.shared.target = .edit(entry)
            openWindow(id: LogWindow.id)
            NSApp.activate()
        case .logAgainNow:
            _ = DS.animate(.standard, reduceMotion: reduceMotion) { logbook.duplicate(entry) }
        }
    }

    /// The forecast details card's contents, while a forecast is drawn: its 30 and 60 minute
    /// figures, how often this Mac's range held there (the scorecard's checks), what it's based on.
    private func details(_ outlook: OutlookSnapshot?) -> ForecastDetails? {
        guard settings.showForecast, let outlook, !outlook.forecast.isEmpty else { return nil }
        return ForecastDetails(outlook: outlook, held: ForecastDetails.held(store.outlook.ledger.scorecard))
    }

    private func withoutForecast(_ o: OutlookSnapshot) -> OutlookSnapshot {
        var copy = o
        copy.forecast = []
        return copy
    }

    private var header: some View {
        HStack(spacing: 8) {
            // Panned back, it says how far: "3 h earlier", with the Now button on the chart.
            Eyebrow(title: panEnd.flatMap { end in plotted.last.map { ChartPan.behindLabel(end, newest: $0.timestamp) } }
                        .map { "\(settings.chartHours) hours, \($0)" } ?? "Last \(settings.chartHours) hours",
                    systemImage: "waveform.path.ecg")
                .accessibilityAddTraits(.isHeader)
            SlidingSegments(selection: $settings.chartHours, options: ChartHours.choices) { "\($0)h" }
                .fixedSize()
                .accessibilityLabel("Chart range")
            .help("Chart range (⌘1 to ⌘4, or ⌘+ and ⌘− for fewer or more hours; pinch the chart on a trackpad)")
            .overlay(alignment: .bottom) {
                if showsShortcuts {
                    ShortcutBadge(text: "⌘1–⌘4").offset(y: 16)
                }
            }
        }
    }

    private func readout(_ r: GlucoseReading, in window: [GlucoseReading]) -> some View {
        let range = GlucoseRange.classify(mgdl: r.mgdl, low: s.lowMgdl, high: s.highMgdl)
        let index = window.firstIndex(where: { $0.timestamp == r.timestamp }) ?? 0
        return HStack(spacing: 8) {
            Capsule().fill(range.tint.gradient).frame(width: 4, height: 16)
            Text(store.shownUnit.format(mgdl: r.mgdl, withUnit: true))
                .dsFont(.sectionTitle)
                .monospacedDigit()
            Text(range.label)
                .dsFont(.label)
                .foregroundStyle(range.textTint)
            Spacer(minLength: 4)
            Text(r.timestamp.formatted(date: .omitted, time: .shortened))
                .dsFont(.label)
                .foregroundStyle(.secondary)
            Text("\(index + 1)/\(window.count)")
                .dsFont(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background { DSSurface(style: .inset, radius: DS.Radius.control) }
        .accessibilityElement(children: .combine)
    }

    // MARK: Keyboard stepping

    private func step(_ delta: Int, in window: [GlucoseReading]) -> KeyPress.Result {
        guard !window.isEmpty else { return .ignored }
        let target: GlucoseReading
        if let pinned, let i = window.firstIndex(where: { $0.timestamp == pinned }) {
            let j = min(window.count - 1, max(0, i + delta))
            target = window[j]
        } else {
            // First press starts from the newest reading, which is what's being compared against.
            target = window[window.count - 1]
        }
        return jump(to: target)
    }

    @discardableResult
    private func jump(to reading: GlucoseReading?) -> KeyPress.Result {
        guard let reading else { return .ignored }
        pinned = reading.timestamp
        let range = GlucoseRange.classify(mgdl: reading.mgdl, low: s.lowMgdl, high: s.highMgdl)
        VoiceOver.announce("\(store.shownUnit.format(mgdl: reading.mgdl)) \(store.shownUnit.spokenLabel), \(range.label), at \(reading.timestamp.formatted(date: .omitted, time: .shortened))")
        return .handled
    }

    /// The pinned reading while stepping through with the arrow keys, so VoiceOver reads each one;
    /// otherwise the whole chart in a sentence (`ChartSummary`).
    private func chartSummary(_ window: [GlucoseReading]) -> String {
        if let date = pinned, let r = window.first(where: { $0.timestamp == date }) {
            let range = GlucoseRange.classify(mgdl: r.mgdl, low: s.lowMgdl, high: s.highMgdl)
            return "\(store.shownUnit.format(mgdl: r.mgdl)) \(store.shownUnit.spokenLabel) at \(ClockLabel.time(r.timestamp)), \(range.spokenLabel)"
        }
        let outlook = settings.showForecast && !s.isStale() ? s.currentOutlook() : nil
        let cutoff = (panEnd ?? window.last?.timestamp ?? Date()).addingTimeInterval(-Double(settings.chartHours) * 3600)
        let sentence = ChartSummary.sentence(.init(readings: window.filter { $0.timestamp >= cutoff }, lowMgdl: s.lowMgdl,
                                                   highMgdl: s.highMgdl, unit: store.shownUnit, hours: Double(settings.chartHours),
                                                   stale: s.isStale(), forecastEnd: outlook?.forecast.last))
        guard settings.showYesterdayLine,
              let line = YesterdayLine.spoken(YesterdayLine.reading(at: window.last?.timestamp ?? Date(), in: yesterday), unit: store.shownUnit)
        else { return sentence }
        return sentence + " " + line
    }
}

/// The Mac's pan keys on a focused chart (popover and Outlook): ⌥← an hour earlier, ⌥→ an hour
/// later, ⌘→ back to now. Plain ← → are left to the chart's reading steps.
enum ChartPanKeys {
    static func move(left: Bool, modifiers: EventModifiers) -> ChartPan.KeyMove? {
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        if mods == .option { return left ? .earlier : .later }
        if mods == .command, !left { return .now }
        return nil
    }

    /// The press to hand the chart for `move`, or nil when there's nowhere for it to go: later or
    /// now while already at now falls through to whatever else wants the key.
    static func press(_ move: ChartPan.KeyMove, after last: ChartPanKeyPress?, pannedBack: Bool) -> ChartPanKeyPress? {
        guard move == .earlier || pannedBack else { return nil }
        return ChartPanKeyPress(id: (last?.id ?? 0) + 1, move: move)
    }
}

/// Takes a right-click (or Control-click) over a chart marker for its peek card, before it reaches
/// the chart's yesterday-line menu. Only while `armed` (the pointer is on a marker, from
/// `MarkerHoveredKey`); every other click goes through untouched.
@MainActor
final class MarkerRightClickMonitor {
    /// Set as the pointer comes onto a marker, with the window it's over (the popover's), so a
    /// right-click in any other window (the dashboard, after the popover closed) is never taken.
    var armed = false {
        didSet {
            guard armed != oldValue else { return }
            window = armed ? Self.windowUnderPointer() : nil
        }
    }
    private var window: NSWindow?
    private var monitor: Any?

    nonisolated init() {}

    private static func windowUnderPointer() -> NSWindow? {
        let number = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        return NSApp.window(withWindowNumber: number)
    }

    func start(_ pin: @escaping () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, self.armed, let window = self.window, event.window === window else { return event }
            if event.type == .leftMouseDown, !event.modifierFlags.contains(.control) { return event }
            pin()
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        armed = false
    }
}

/// Little key-cap label shown under a control while ⌘ is held.
struct ShortcutBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .fixedSize()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

@MainActor
enum VoiceOver {
    /// Speaks `text` if VoiceOver is running. Does nothing otherwise.
    static func announce(_ text: String) {
        guard let element = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

/// Sideways two-finger swipes on the trackpad over the popover's chart, passed to the chart as
/// `ChartPanScroll` (`GlucoseChart.panScroll`) and taken, so they never scroll anything else. A
/// swipe decides on its first movement: mostly sideways pans the chart, mostly up or down is left
/// alone. Momentum after the fingers lift is taken too, but doesn't move the chart: it stays
/// where the fingers left it. Mouse wheels (no scroll phases) are left alone.
@MainActor
final class ChartScrollPanMonitor {
    /// Whether the pointer is over the chart.
    var over = false
    private var monitor: Any?
    /// Decided on a swipe's first movement; kept through its momentum.
    private var sideways: Bool?
    private var total: Double = 0
    private var id = 0

    nonisolated init() {}

    func start(_ send: @escaping (ChartPanScroll) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handle(event, send) ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        sideways = nil
        total = 0
        over = false
    }

    /// True when the event was taken.
    private func handle(_ e: NSEvent, _ send: (ChartPanScroll) -> Void) -> Bool {
        if !e.momentumPhase.isEmpty { return sideways == true }
        guard !e.phase.isEmpty else { return false }
        if e.phase.contains(.mayBegin) || e.phase.contains(.began) {
            sideways = nil
            total = 0
        }
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
            guard sideways == true else { sideways = nil; return false }
            id += 1
            send(ChartPanScroll(id: id, points: total, ended: true))
            return true
        }
        if sideways == nil {
            let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
            guard over, dx != 0 || dy != 0 else { return false }
            sideways = abs(dx) > abs(dy)
        }
        guard sideways == true else { return false }
        total += e.scrollingDeltaX
        id += 1
        send(ChartPanScroll(id: id, points: total))
        return true
    }
}
