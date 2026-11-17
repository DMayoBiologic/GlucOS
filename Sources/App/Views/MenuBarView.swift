import SwiftUI
import AppKit

/// The menu bar popover. One question per layer, most important first:
///
/// 1. **Now**: the current reading, its trend and how fresh it is (`PopoverHero`).
/// 2. **Needs attention**: the single most urgent notice, with any others one click away.
/// 3. **Lately**: the recent trace (`PopoverChartCard`).
/// 4. **Overall**: time in range and the last dose and meal, with the full stats behind
///    "Details" (`PopoverSummaryCard`).
/// 5. **Actions** (`PopoverToolbar`) and a one-line footer.
///
/// Keyboard: ⌘L log, ⌘R refresh, ⌘D dashboard, ⌘, settings, ⌘C copy reading, ⌘1–4 or ⌘+ / ⌘− chart range,
/// ⌘I show or hide details, ⌥⌘1–3 one of "Your usual" (`PopoverUsualRow`), ⌘Q quit, ← → step through chart readings, Escape closes. Hold ⌘ to
/// see the shortcuts on the buttons; ⌘? lists them all (`ShortcutCatalog.popover`).
struct MenuBarView: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var logbook: LogbookStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var commandKey = CommandKeyMonitor()
    @AppStorage("popoverDetailsExpanded") private var detailsExpanded = false
    @AppStorage("popoverGlanceWindow") private var glanceWindowRaw = GlanceWindow.day.rawValue
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var contentHeight: CGFloat = 0
    /// False while the popover is opening, so it opens at its size; then height changes glide
    /// (`ContentResize`).
    @State private var resizeSettled = false
    /// The ⌘? list, shown over the popover.
    @State private var showsShortcutList = false
    /// False only for the moment between the popover opening and its sections starting to come
    /// in (`PopoverStagger`). Anything that goes wrong leaves it true, so content is never hidden.
    @State private var sectionsIn = true
    /// Which card, chip or button has the keyboard (docs/KeyboardNavigation.md).
    @FocusState private var keyFocus: String?
    @ObservedObject private var snoozeStore = AlertSnoozeStore.shared

    private var s: GlucoseSnapshot { store.snapshot }

    /// Why "Log treatment" shows under the reading, if it does (`LowTreatButton`).
    private var lowTreat: LowTreatButton.Reason? {
        LowTreatButton.current(store: store, logbook: logbook, settings: settings)
    }

    /// The log window for a low, as the alert's Log treatment button opens it: filled in from the
    /// "Treat a low" usual, nothing logged until Log.
    private func openLowTreatment() {
        LogWindowRequest.shared.target = .treating(.low)
        openWindow(id: LogWindow.id)
        NSApp.activate()
    }

    var body: some View {
        ScrollView(.vertical) {
            content
                // Tab and the arrow keys move a focus ring through the cards and buttons.
                .keyNavigation($keyFocus)
                // The chart has the keyboard when the popover opens, as before, so ← → step
                // through readings straight away.
                .defaultFocus($keyFocus, "popover.chart")
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(key: PopoverHeightKey.self, value: geo.size.height)
                    }
                }
        }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize)
        // MenuBarExtra sizes its window to the content's ideal size, which a ScrollView doesn't
        // have. So measure the content and ask for exactly that, capped to the screen, so the
        // popover only scrolls on a display too short to show it all.
        // When something comes or goes (the snoozed chip, a notice, Log treatment, Details) the
        // height glides there instead of jumping, and the window follows it frame by frame. A new
        // reading, the opening and Reduce Motion snap (`ContentResize`).
        .modifier(PopoverHeightFrame(width: PopoverLayout.width,
                                     height: contentHeight > 0 ? min(contentHeight, maxHeight) : 0))
        .onPreferenceChange(PopoverHeightKey.self) { height in MainActor.assumeIsolated { resize(to: height) } }
        .background(alignment: .top) {
            // A wash of the current range colour at the top of the popover.
            AmbientGlow(tint: s.displayTone().color, intensity: 0.4)
                .frame(height: 240)
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .bottom) { toastView }
        .overlay { shortcutList }
        .background { shortcuts }
        .animation(PopoverMotion.standard(reduceMotion), value: s.current)
        .animation(PopoverMotion.standard(reduceMotion), value: s.lastError)
        .animation(PopoverMotion.standard(reduceMotion), value: s.isStale())
        .animation(PopoverMotion.quick(reduceMotion), value: toast)
        .animation(PopoverMotion.quick(reduceMotion), value: showsShortcutList)
        .animation(PopoverMotion.standard(reduceMotion), value: snoozeStore.isSnoozing)
        .animation(PopoverMotion.standard(reduceMotion), value: lowTreat != nil)
        .task { await store.checkNotificationPermission() }
        .onAppear { commandKey.start(); staggerSectionsIn(); revealUnitChange(); settleResizing() }
        .onDisappear {
            commandKey.stop(); showsShortcutList = false
            resizeSettled = false
            sectionsIn = true
            // Units are changed in the Settings window, with the popover closed: hold the change
            // until the popover is open again, so its figures can be seen morphing.
            store.holdUnitChanges()
        }
        .unitMorph(store.shownUnit)
        .environment(\.dsDensity, .compact)
    }

    private var content: some View {
        let notices = PopoverNotice.current(store: store, onRefresh: refresh)
        let showsDose = PopoverDosePrompt.isRelevant(logbook: logbook)
        let showsLow = PopoverLowPrompt.isRelevant(logbook: logbook, store: store, settings: settings)
        let showsWake = PopoverWakePrompt.isRelevant(logbook: logbook)
        let showing = staggerSections(hasNotices: !notices.isEmpty, hasPrompts: showsDose || showsLow || showsWake)
        return VStack(alignment: .leading, spacing: PopoverLayout.stackSpacing) {
            // Redrawn once more when a warm-up runs out with the popover open, so the card gives way.
            // And when the sensor reaches its end, so the ended card takes over (docs/SensorEnd.md).
            TimelineView(.explicit(heroMoments)) { context in
                heroSlot(warmUp: s.warmUp(at: context.date), ended: s.sensorEnded(at: context.date), now: context.date)
            }
            .popoverEntrance(.hero, showing: showing, shown: sectionsIn)
            // While an alert is snoozed: until when, and a click turns alerts back on.
            if snoozeStore.isSnoozing {
                AlertSnoozeChipView(snoozes: snoozeStore.snoozes, countdown: snoozeStore.countdown) {
                    AlertSnoozeStore.shared.resumeAll()
                }
                .keyStop("popover.snooze", kind: .control, radius: DS.Radius.control) {
                    AlertSnoozeStore.shared.resumeAll()
                }
                .transition(AlertSnoozeChipView.transition(reduceMotion: reduceMotion))
                .popoverEntrance(.hero, showing: showing, shown: sectionsIn)
            }
            // During a low, or with one predicted: the alert's Log treatment button, inline.
            if let lowTreat {
                LowTreatButtonView(reason: lowTreat,
                                   hasUsual: LowQuestion.shared.usual(logbook: logbook) != nil,
                                   shortcut: KeyboardShortcut("l"),
                                   action: openLowTreatment)
                    .keyStop("popover.lowTreat", kind: .control, radius: DS.Radius.control, action: openLowTreatment)
                    .transition(.opacity)
                .popoverEntrance(.hero, showing: showing, shown: sectionsIn)
            }
            PopoverNotices(notices: notices)
                .accessibilitySortPriority(3)
                .popoverEntrance(.notices, showing: showing, shown: sectionsIn)
            Group {
                if showsDose { PopoverDosePrompt() }
                if showsLow { PopoverLowPrompt() }
                if showsWake { PopoverWakePrompt() }
            }
            .popoverEntrance(.prompts, showing: showing, shown: sectionsIn)
            if s.current != nil {
                PopoverChartCard(showsShortcuts: commandKey.isHeld,
                                 forecastDelay: PopoverStagger.forecastDelay(showing: showing))
                    .popoverEntrance(.chart, showing: showing, shown: sectionsIn)
                PopoverSummaryCard(expanded: detailsExpanded, showsShortcuts: commandKey.isHeld,
                                   onToggleDetails: toggleDetails, onOpenDashboard: showDashboard)
                    // Return or Space shows or hides the details, as ⌘I does.
                    .keyStop("popover.summary", radius: PopoverLayout.cardRadius, action: toggleDetails)
                    .popoverEntrance(.summary, showing: showing, shown: sectionsIn)
            }
            // One-click repeats, next to the actions: each opens the log window filled in.
            PopoverUsualRow(showsShortcuts: commandKey.isHeld)
                .popoverEntrance(.toolbar, showing: showing, shown: sectionsIn)
            PopoverToolbar(showsShortcuts: commandKey.isHeld,
                           lowTreatmentHoldsLogKey: lowTreat != nil,
                           onLog: showLogSheet, onRefresh: refresh, onDashboard: showDashboard,
                           onSettings: showSettings, onCopy: copyReading,
                           onShortcuts: toggleShortcutList)
                .padding(.top, 2)
                .popoverEntrance(.toolbar, showing: showing, shown: sectionsIn)
            PopoverFooter()
                .popoverEntrance(.footer, showing: showing, shown: sectionsIn)
        }
        .padding(PopoverLayout.outerPadding)
        // Observed here, on a view that's always present, so the first notice to appear while
        // the popover is open is spoken too. Contents already showing are read when it opens.
        .onChange(of: notices.map(\.kind)) { old, _ in
            for n in notices where !old.contains(n.kind) && n.severity <= .warning {
                VoiceOver.announce(n.severity.accessibilityPrefix + n.title)
            }
        }
    }

    /// The top card: a new sensor's warm-up countdown, the reading, or what to do with none. The
    /// first reading cross-fades in over the countdown: a fade, so it stays under Reduce Motion
    /// (`.sweep` keeps a short one there).
    private func heroSlot(warmUp: SensorWarmUp?, ended: SensorEnd.Ended?, now: Date) -> some View {
        Group {
            if let warmUp {
                PopoverWarmUpCard(warmUp: warmUp, onRefresh: refresh)
                    .accessibilitySortPriority(4)
                    .transition(.opacity)
            } else if let ended {
                PopoverSensorEndedCard(ended: ended, now: now, onRefresh: refresh)
                    .accessibilitySortPriority(4)
                    .transition(.opacity)
            } else if s.current != nil {
                PopoverHero(onCopy: copyReading, onRefresh: refresh, onOpenDashboard: showDashboard)
                    .accessibilitySortPriority(4)
                    .transition(.opacity)
            } else {
                emptyState
                    .transition(.opacity)
            }
        }
        .dsAnimation(.sweep, value: warmUp == nil)
        .dsAnimation(.sweep, value: ended == nil)
    }

    /// When the top card changes with no new data: a warm-up running out, or the sensor ending.
    private var heroMoments: [Date] {
        let now = Date()
        var out = s.warmUp().map { [$0.endsAt.addingTimeInterval(SensorWarmUp.grace)] } ?? []
        if let ends = s.sensor?.expires, ends > now { out.append(ends.addingTimeInterval(1)) }
        // A last reading from after the nominal end goes stale: the sensor has now stopped.
        if let cur = s.current, let ends = s.sensor?.expires, cur.timestamp >= ends {
            let stale = cur.timestamp.addingTimeInterval(GlucoseSnapshot.staleAfter + 1)
            if stale > now { out.append(stale) }
        }
        return out.sorted()
    }

    /// The sections taking a turn in this opening's stagger.
    private func staggerSections(hasNotices: Bool, hasPrompts: Bool) -> Set<PopoverStagger.Section> {
        var showing: Set<PopoverStagger.Section> = [.hero, .toolbar, .footer]
        if hasNotices { showing.insert(.notices) }
        if hasPrompts { showing.insert(.prompts) }
        if s.current != nil { showing.formUnion([.chart, .summary]) }
        return showing
    }

    /// Hides the sections for the popover's first frame, then lets each come in on its turn, once.
    /// Under Reduce Motion they're simply there.
    private func staggerSectionsIn() {
        guard !reduceMotion else { sectionsIn = true; return }
        var hide = Transaction(animation: nil)
        hide.disablesAnimations = true
        withTransaction(hide) { sectionsIn = false }
        // On the next turn, so the hidden first frame is drawn before they start moving. Each
        // section's own delayed animation (`popoverEntrance`) does the staggering.
        DispatchQueue.main.async { sectionsIn = true }
    }

    /// Takes a new content height: gliding to it when something came or went, otherwise at once.
    private func resize(to height: CGFloat) {
        switch ContentResize.step(from: contentHeight, to: height, settled: resizeSettled, reduceMotion: reduceMotion) {
        case .glide:
            withAnimation(PopoverMotion.standard(reduceMotion)) { contentHeight = height }
        case .snap:
            var now = Transaction(animation: nil)
            now.disablesAnimations = true
            withTransaction(now) { contentHeight = height }
        }
    }

    /// The popover opens at its size; once it's laid out, changes to it glide.
    private func settleResizing() {
        resizeSettled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + PopoverHeightFrame.settleDelay) { resizeSettled = true }
    }

    /// Shows a unit change made while the popover was closed: the sections come in with the old
    /// figures, then they morph to the new unit (`UnitSwitch`). Under Reduce Motion it's simply
    /// the new unit from the start.
    private func revealUnitChange() {
        guard !reduceMotion else { store.revealUnit(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + UnitSwitch.popoverRevealDelay) { store.revealUnit() }
    }

    /// Leaves room for the menu bar and a margin above the Dock, on the display the popover is
    /// on (it's the key window while open).
    private var maxHeight: CGFloat {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame.height ?? 800
        return max(320, visible - 24)
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Label(toast, systemImage: "checkmark.circle.fill")
                .fontWeight(.semibold).dsFont(.callout)
                .symbolRenderingMode(.hierarchical)
                .padding(.horizontal, DS.Space.md + 2)
                .padding(.vertical, DS.Space.sm)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .dsShadow(.high)
                .padding(.bottom, 60)
                .transition(DS.Transition.toast(reduceMotion: reduceMotion))
                .accessibilityHidden(true)   // announced separately
        }
    }

    /// Shortcuts without a visible button of their own.
    private var shortcuts: some View {
        ZStack {
            HiddenShortcut(key: "1") { settings.chartHours = 3 }
            HiddenShortcut(key: "2") { settings.chartHours = 6 }
            HiddenShortcut(key: "3") { settings.chartHours = 12 }
            HiddenShortcut(key: "4") { settings.chartHours = 24 }
            // ⌘+ (and ⌘= without Shift) zooms in to fewer hours, ⌘− out to more.
            HiddenShortcut(key: "=") { settings.chartHours = ChartHours.shorter(than: settings.chartHours) }
            HiddenShortcut(key: "+") { settings.chartHours = ChartHours.shorter(than: settings.chartHours) }
            HiddenShortcut(key: "-") { settings.chartHours = ChartHours.longer(than: settings.chartHours) }
            HiddenShortcut(key: "c", action: copyReading)
            HiddenShortcut(key: "i", action: toggleDetails)
            HiddenShortcut(key: "q") { NSApplication.shared.terminate(nil) }
            HiddenShortcut(key: "?", action: toggleShortcutList)
        }
        .accessibilityHidden(true)
    }

    /// The ⌘? list over the popover, scrolling if the popover is shorter than the list.
    @ViewBuilder
    private var shortcutList: some View {
        if showsShortcutList {
            ScrollView {
                ShortcutListView(groups: ShortcutCatalog.popover(globalKey: settings.activeGlobalLogShortcut),
                                 compact: true) {
                    showsShortcutList = false
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
            .transition(.opacity)
        }
    }

    private func toggleShortcutList() {
        showsShortcutList.toggle()
        if showsShortcutList { VoiceOver.announce("Keyboard shortcuts") }
    }

    // MARK: Actions

    private func refresh() {
        Task { await store.refresh() }
    }

    private func copyReading() {
        guard store.copyReadingToClipboard() else { return }
        showToast("Reading copied")
        VoiceOver.announce("Reading copied")
    }

    /// Shared by the Details button and ⌘I, so both animate and announce the same way. Does
    /// nothing while there are no stats to show.
    private func toggleDetails() {
        let window = GlanceWindow(rawValue: glanceWindowRaw) ?? .day
        guard s.current != nil, store.glanceStats(window) != nil else { return }
        withAnimation(PopoverMotion.standard(reduceMotion)) { detailsExpanded.toggle() }
        VoiceOver.announce(detailsExpanded ? "Details shown" : "Details hidden")
    }

    private func showToast(_ text: String) {
        toastTask?.cancel()
        toast = text
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        Group {
            if settings.hasCredentials, let step = noReadingsStep {
                // Signed in and connected with nothing to show: a new account, a sensor that has
                // ended, LibreLink not uploading. Says what to do next.
                ContentUnavailableView {
                    Label(step.title, systemImage: step.systemImage)
                } description: {
                    Text(step.detail)
                } actions: {
                    checkAgainButton
                }
            } else if settings.hasCredentials {
                ContentUnavailableView {
                    Label("Waiting for Data", systemImage: "drop")
                } description: {
                    Text(store.connectionProblem == nil
                         ? "Getting your latest reading from LibreLinkUp…"
                         : "Couldn't reach LibreLinkUp. The notice below says what to do.")
                } actions: {
                    checkAgainButton
                }
            } else {
                ContentUnavailableView {
                    Label("Connect LibreLinkUp", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("Sign in with the LibreLinkUp follower account that shares your sensor.")
                } actions: {
                    Button("Set Up GlucOS…") {
                        openWindow(id: OnboardingView.windowID)
                        NSApp.activate()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.sm)
        .dsCard(.standard)
    }

    private var noReadingsStep: NoReadingsStep? {
        NoReadingsStep.current(snapshot: s, hasConnectionProblem: store.connectionProblem != nil)
    }

    private var checkAgainButton: some View {
        Button(action: refresh) {
            Label(store.isRefreshing ? "Checking…" : "Check Again", systemImage: "arrow.clockwise")
        }
        .disabled(store.isRefreshing)
    }

    /// `LSUIElement` apps don't come forward on their own, so the Settings window would open
    /// behind whatever app was frontmost.
    private func showSettings() {
        openSettings()
        NSApp.activate()
    }

    private func showDashboard() {
        openWindow(id: DashboardView.windowID)
        NSApp.activate()
    }

    /// Logging opens its own small window, since a sheet can't hang off the popover.
    private func showLogSheet() {
        LogWindowRequest.shared.target = .new
        openWindow(id: LogWindow.id)
        NSApp.activate()
    }
}

/// The popover's fixed size. Its height is animatable, so a glide lays the popover out at each
/// step between the old and new heights: MenuBarExtra resizes its window to follow, rather than
/// jumping to the end size while the content moves. 0 means not measured yet: no fixed height.
private struct PopoverHeightFrame: ViewModifier, Animatable {
    /// How long after opening before height changes glide: long enough for the first layout.
    static let settleDelay: TimeInterval = 0.2

    let width: CGFloat
    var height: CGFloat

    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func body(content: Content) -> some View {
        // Whole points, so the window isn't asked for fractional sizes mid-glide.
        content.frame(width: width, height: height > 0 ? height.rounded(.up) : nil)
    }
}

private struct PopoverHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Layout and motion

/// Popover measurements, from the design system's compact density, so every card lines up.
enum PopoverLayout {
    static let width: CGFloat = 360
    static let outerPadding: CGFloat = DS.Space.md
    /// Between cards.
    static let stackSpacing: CGFloat = DSDensity.compact.gutter
    static let cardPadding: CGFloat = DSDensity.compact.cardPadding
    static let cardRadius: CGFloat = DSDensity.compact.cardRadius
    static let heroRadius: CGFloat = DS.Radius.panel
    /// One step inside a card.
    static let tileRadius: CGFloat = DS.Radius.tile
}

/// Popover animations, on the design system's curves. Every one is nil under Reduce Motion, so
/// state still changes, instantly.
enum PopoverMotion {
    static func quick(_ reduce: Bool) -> Animation? { DSMotion.quick.animation(reduceMotion: reduce) }
    static func standard(_ reduce: Bool) -> Animation? { DSMotion.standard.animation(reduceMotion: reduce) }

    /// Content revealed below a header: fades and drops in, fades out.
    static func reveal(_ reduce: Bool) -> AnyTransition {
        reduce ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: -6)),
                                        removal: .opacity)
    }

    /// Small floating things such as the toast.
    static func pop(_ reduce: Bool) -> AnyTransition {
        reduce ? .opacity : .opacity.combined(with: .scale(scale: 0.92))
    }

    /// Content replaced by the same kind of content, such as the summary for another period:
    /// the old one slides out one way as the new one slides in from the other (`direction` from
    /// `PopoverStagger.slideDirection`). Under Reduce Motion, or with no direction, it just swaps.
    static func crossSlide(_ direction: Int, reduce: Bool) -> AnyTransition {
        guard !reduce, direction != 0 else { return .identity }
        let distance = CGFloat(direction) * PopoverStagger.slideDistance
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: distance)),
                           removal: .opacity.combined(with: .offset(x: -distance)))
    }
}

extension View {
    /// One section of the popover's opening stagger (`PopoverStagger`): faded and lowered while
    /// `shown` is false, rising into place on the section's turn when it turns true. Only the
    /// opacity and offset are animated, so nothing else inside picks up the delay.
    func popoverEntrance(_ section: PopoverStagger.Section, showing: Set<PopoverStagger.Section>,
                         shown: Bool) -> some View {
        modifier(PopoverEntrance(delay: PopoverStagger.delay(of: section, showing: showing), shown: shown))
    }
}

private struct PopoverEntrance: ViewModifier {
    let delay: TimeInterval
    let shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let visible = shown || reduceMotion
        content.animation(reduceMotion ? nil : .smooth(duration: PopoverStagger.duration).delay(delay)) {
            $0.opacity(visible ? 1 : 0)
                .offset(y: visible ? 0 : PopoverStagger.rise)
        }
    }
}
