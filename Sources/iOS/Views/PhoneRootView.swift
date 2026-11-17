import SwiftUI

/// How this phone uses GlucOS, chosen on the welcome screen.
enum PhoneMode: String {
    /// Not chosen yet: the welcome screen.
    case unset = ""
    /// Wears a sensor: signs in with LibreLinkUp and gets the whole app.
    case sensor
    /// Only follows other people's shared readings: no account, no logging, no alerts of its own.
    case follower
}

/// The welcome screen first (I wear a sensor / I'm following someone); then the glucose screen
/// once signed in, or the people this phone follows.
struct PhoneRootView: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var follows: FollowStore
    @AppStorage("phoneMode") private var mode: PhoneMode = .unset

    var body: some View {
        Group {
            if settings.hasCredentials {
                PhoneHomeView()
            } else if mode == .follower || (mode == .unset && follows.isFollowing) {
                // Opening a share link before choosing counts as choosing to follow.
                FollowingHomeView()
            } else if mode == .sensor {
                NavigationStack { PhoneSignInView(onFollowInstead: { mode = .follower }) }
            } else {
                PhoneWelcomeView(mode: $mode)
            }
        }
        .animation(.default, value: mode)
        // A low or high alert firing while the app is open slides in here (docs/AlertActions.md).
        .alertBannerHost()
        .alert(follows.notice ?? "", isPresented: Binding(get: { follows.notice != nil },
                                                          set: { if !$0 { follows.notice = nil } })) {
            Button("OK") { follows.notice = nil }
        }
    }
}

/// The first screen of a new install: wearing a sensor, or following someone who does.
struct PhoneWelcomeView: View {
    @Binding var mode: PhoneMode

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    Image(systemName: "drop.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(Palette.brandGradient)
                    Text("Welcome to GlucOS").dsFont(.title)
                    Text("Live glucose on your Lock Screen, with alerts that reach you even when the app is closed.")
                        .dsFont(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, DS.Space.xxxl)

                choice(title: "I wear a sensor",
                       detail: "Sign in with your LibreLinkUp follower account to see your readings, log insulin and food, get alerts, and share live with family.",
                       systemImage: "sensor.tag.radiowaves.forward.fill") { mode = .sensor }
                    .dsEntrance(1)
                choice(title: "I'm following someone",
                       detail: "No sensor or account needed. Open the GlucOS link someone sent you to see their glucose live, on your Lock Screen, with their alerts.",
                       systemImage: "person.2.wave.2.fill") { mode = .follower }
                    .dsEntrance(2)

                Text("Not a medical device. Confirm readings and alerts with the sensor app before acting.")
                    .dsFont(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.bottom, DS.Space.xxl)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background { PhoneBackdrop(tone: .glucose(.inRange)) }
    }

    private func choice(title: String, detail: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: DS.Space.md) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Palette.brandGradient)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(title).dsFont(.headline).foregroundStyle(.primary)
                    Text(detail).dsFont(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(DS.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { DSSurface(style: .standard, radius: DS.Radius.card) }
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// The main screen: the same cards as the Mac popover, stacked for a phone.
struct PhoneHomeView: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var services: PhoneServices
    @EnvironmentObject var follows: FollowStore
    @EnvironmentObject var router: PhoneLogRouter
    @EnvironmentObject var logbook: LogbookStore
    @State private var showsSettings = false
    @State private var settingsAnchor: PhoneSettingsView.Jump?
    @State private var showsSharing = false
    /// Taps on the nav bar icons, so each tap plays one bounce.
    @State private var sharingTaps = 0
    @State private var settingsTaps = 0
    /// How far the stage has folded into the navigation bar (`HeaderCollapse`, round 46).
    @State private var collapse = TodayHeaderCollapse()
    @Namespace private var routes
    /// The stack's screens, so a card further in (Insights → Logbook) can push one.
    @State private var path = NavigationPath()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PhoneSetupView.pendingKey) private var setupPending = false
    @ObservedObject private var snoozeStore = AlertSnoozeStore.shared

    /// Why "Log treatment" shows under the reading, if it does (`LowTreatButton`).
    private var lowTreat: LowTreatButton.Reason? {
        LowTreatButton.current(store: store, logbook: logbook, settings: settings)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: DS.Space.lg) {
                    PhoneBanners { anchor in
                        settingsAnchor = anchor
                        showsSettings = true
                    }
                    // Someone's asking if they're okay: above everything, until they answer.
                    PhoneCheckInBanner()
                    // Cards assemble top to bottom on launch rather than popping in at once.
                    PhoneHeroCard()
                        .onGeometryChange(for: Double.self) {
                            Double($0.frame(in: .named(TodayHeaderCollapse.space)).minY)
                        } action: { collapse.update(stageTop: $0) }
                        .dsEntrance(0)
                    // While an alert is snoozed: until when, and a tap turns alerts back on.
                    if snoozeStore.isSnoozing {
                        AlertSnoozeChipView(snoozes: snoozeStore.snoozes, countdown: snoozeStore.countdown,
                                            error: services.snoozeResumeError) {
                            Task { await services.resumeAlerts() }
                        }
                        .transition(AlertSnoozeChipView.transition(reduceMotion: reduceMotion))
                    }
                    // During a low, or with one predicted: the alert's Log treatment button, inline.
                    // It opens the log sheet filled in from the "Treat a low" usual; nothing is logged
                    // until Log.
                    if let lowTreat {
                        LowTreatButtonView(reason: lowTreat,
                                           hasUsual: LowQuestion.shared.usual(logbook: logbook) != nil) {
                            router.treat(.low)
                        }
                        .transition(.opacity)
                    }
                    ForEach(follows.follows) { PhoneFollowingCard(follow: $0).dsEntrance(1) }
                    PhoneOnBoardCard().dsEntrance(1)
                    PhoneChartCard().dsEntrance(2)
                    PhoneLogbookCard()
                        .matchedTransitionSource(id: PhoneRoute.logbook.zoomSource, in: routes)
                        .dsEntrance(3)
                    // Today against the same hours on a usual day; hidden until today has an
                    // hour of readings. Below the logbook, so logging stays near the top.
                    TodaySoFarView(readings: store.archive, unit: store.shownUnit,
                                   lowMgdl: store.snapshot.lowMgdl, highMgdl: store.snapshot.highMgdl,
                                   padding: DS.Space.lg)
                        .dsEntrance(4)
                    // Time in range, mornings and forecast accuracy live one tap away, so the
                    // logbook isn't pushed below three cards of statistics.
                    PhoneInsightsRow()
                        .matchedTransitionSource(id: PhoneRoute.insights.zoomSource, in: routes)
                        .dsEntrance(5)
                    if let sensor = store.snapshot.sensor {
                        PhoneSensorCard(sensor: sensor).dsEntrance(6)
                    }
                    Text("Not a medical device. Confirm readings and alerts with your sensor app before acting.")
                        .dsFont(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, DS.Space.xs)
                }
                .padding(.horizontal, DS.Space.lg)
                .padding(.bottom, DS.Space.lg)
                .coordinateSpace(.named(TodayHeaderCollapse.space))
                .environment(collapse)
                // The snoozed chip fades in and out once; instant under Reduce Motion.
                .animation(DSMotion.standard.animation(reduceMotion: reduceMotion), value: snoozeStore.isSnoozing)
                .animation(DSMotion.standard.animation(reduceMotion: reduceMotion), value: lowTreat != nil)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background {
                PhoneBackdrop(tone: store.snapshot.displayTone(),
                              rapid: !store.snapshot.isStale() && (store.snapshot.current?.trend.isRapid ?? false),
                              range: store.snapshot.isStale() ? nil : store.snapshot.range)
            }
            // As the stage scrolls towards the bar its figure shrinks into the bar's title, and grows
            // back on the way down: tied to the scroll position, so it never jumps or plays on its
            // own. Whole points only; the fold itself moves in `HeaderCollapse.steps` steps.
            .onScrollGeometryChange(for: Double.self) { geo in
                Double(geo.contentOffset.y + geo.contentInsets.top).rounded()
            } action: { _, scrolled in
                collapse.update(scrolled: scrolled)
            }
            // The same fetches as opening the app (relay readings, then LibreLinkUp), never extra
            // polling: a pull joins a fetch in flight and skips one that has just finished.
            .phonePullToRefresh(steps: services.relaySettings.isConfigured ? 2 : 1,
                                tint: store.snapshot.displayTone().color) { stepDone in
                let before = store.pullMarker
                if services.relaySettings.isConfigured {
                    await services.fillHistoryFromRelay()
                    stepDone()
                }
                let failed = await store.refreshForPull()
                stepDone()
                return PullRefresh.outcome(before: before, after: store.pullMarker, failed: failed)
            }
            // After a logbook delete: Undo, just above the log bar.
            .overlay(alignment: .bottom) { PhoneUndoToast() }
            // The one place to start logging. A bar under the content rather than a button over
            // it, so it never covers a logbook row.
            .safeAreaInset(edge: .bottom, spacing: 0) { PhoneLogBar() }
            .navigationTitle("GlucOS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    PhoneCollapsingTitle(collapse: collapse,
                                         showsReading: store.snapshot.current != nil && store.snapshot.warmUp() == nil) {
                        PhoneTitleReading()
                    }
                }
                // Each icon bounces once when tapped (round 48); still under Reduce Motion.
                ToolbarItem(placement: .topBarLeading) {
                    Button { sharingTaps += 1; showsSharing = true } label: {
                        Image(systemName: "person.2.wave.2").symbolBounce(on: sharingTaps)
                    }
                    .accessibilityLabel("Share live readings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settingsTaps += 1; settingsAnchor = nil; showsSettings = true } label: {
                        Image(systemName: "gearshape").symbolBounce(on: settingsTaps)
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(for: PhoneRoute.self) { route in
                // The card grows into its screen, and shrinks back into it on Back. A plain push
                // under Reduce Motion.
                let screen = Group {
                    switch route {
                    case .logbook: PhoneLogbookView()
                    case .insights: PhoneInsightsView()
                    case .logbookLink(let link): PhoneLogbookView(link: link)
                    case .logbookEntry(let id): PhoneLogbookView(opening: id)
                    case .insightsToday(let firedAt): PhoneInsightsView(recapFiredAt: firedAt)
                    }
                }
                if reduceMotion {
                    screen
                } else {
                    screen.navigationTransition(.zoom(sourceID: route.zoomSource, in: routes))
                }
            }
            .navigationDestination(for: FollowRoute.self) { FollowRouteView(route: $0) }
        }
        .environment(\.phoneNavigator, PhoneNavigator(push: { path.append($0) }, zoom: routes))
        // One countdown for the undo toast, whichever screen it's showing on.
        .phoneUndoCountdown()
        // A unit picked in Settings is held while the sheet covers Today and Insights, then their
        // figures and chart axes morph to it once the sheet has gone (`UnitSwitch`).
        .unitMorph(store.shownUnit)
        .onChange(of: showsSettings) { _, open in if open { store.holdUnitChanges() } }
        // On the stack rather than its root, so the log sheet also opens over a pushed screen
        // (editing a row in the full logbook).
        .sheet(isPresented: $showsSettings, onDismiss: { store.revealUnit() }) {
            NavigationStack { PhoneSettingsView(scrollTo: settingsAnchor) }
        }
        .sheet(isPresented: $showsSharing) {
            NavigationStack { PhoneSharingView() }
        }
        // The Glucose control in Control Center (iOS 18) opens Today: back to the top of the stack,
        // out of Settings or Sharing. An open log sheet stays, so nothing being typed is lost.
        .onChange(of: router.todayRequest) { _, request in
            guard request != nil else { return }
            path = NavigationPath()
            showsSettings = false
            showsSharing = false
        }
        // A tap on the evening recap: Insights on today, from the top of the stack, out of
        // Settings or Sharing (docs/EveningRecap.md). Also catches the tap that launched the app.
        .onReceive(EveningRecapRoute.shared.$request) { request in
            guard request != nil, let firedAt = EveningRecapRoute.shared.take() else { return }
            showsSettings = false
            showsSharing = false
            var stack = NavigationPath()
            stack.append(PhoneRoute.insightsToday(firedAt))
            path = stack
        }
        .onChange(of: router.request?.id) { _, id in
            // A log link arriving while Settings or Sharing is open: show the log sheet instead.
            if id != nil { showsSettings = false; showsSharing = false }
        }
        // Right after the first sign-in: range, alerts and insulin, then home.
        .sheet(isPresented: $setupPending) { PhoneSetupView() }
        .sheet(item: $router.request) { request in
            PhoneLogSheet(target: request.target, origin: request.origin)
                .presentationDragIndicator(.visible)
        }
    }
}

/// The screen background: the grouped background with a faint wash of the reading's colour at the
/// top, like the glow behind the Mac popover's hero.
struct PhoneBackdrop: View {
    let tone: Tone
    /// The trend is rapid: the field drifts a little faster.
    var rapid: Bool = false
    /// The current range, so a range change sweeps the new colour in from the side it came from
    /// (docs/Redesign.md §4.2). Nil when stale or on screens that aren't about the reading.
    var range: GlucoseRange? = nil

    var body: some View {
        ZStack(alignment: .top) {
            Color(uiColor: .systemGroupedBackground)
            // The range field the stage sits on (docs/Redesign.md §5.1), fading into the page.
            RangeField(tone: tone, rapid: rapid, live: true, range: range)
                .frame(height: 520)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.45),
                                             .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
        }
        .ignoresSafeArea()
    }
}

/// The reading in the navigation bar while the stage is scrolled away: value and arrow in the
/// range's colour, grey when stale. Hidden from VoiceOver (`PhoneCollapsingTitle`): the stage
/// already reads the reading, so it is heard once.
private struct PhoneTitleReading: View {
    @EnvironmentObject var store: GlucoseStore

    var body: some View {
        let s = store.snapshot
        let stale = s.isStale()
        let tone = s.displayTone()
        // Right after launch: the saved reading, dimmed, until the first fetch (like the stage).
        let launch = store.launchPhase()
        HStack(spacing: DS.Space.xs) {
            if let cur = s.current {
                // The octagon marks an urgent low here too, not just the colour.
                if !stale, s.range == .urgentLow {
                    Image(systemName: "exclamationmark.octagon.fill").font(.subheadline.weight(.bold))
                }
                // Rolls and cross-fades like the stage's figure; just changes under Reduce Motion.
                // The saved reading cross-fades to the first live one once.
                LaunchFigure(phase: launch) {
                    Text(store.shownUnit.format(mgdl: cur.mgdl))
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(stale ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(tone.color))
                        .readingChange(mgdl: cur.mgdl, tone: tone, instantUnderReduceMotion: true)
                        .staleStrike(stale, thickness: 2)
                }
                TrendArrow(trend: cur.trend, stale: stale)
                    .font(.subheadline.weight(.bold))
            }
        }
        .foregroundStyle(stale ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(tone.color))
        .dsAnimation(.sweep, value: tone)
        .launchDim(launch, stale: stale)
    }
}

/// Problems that need attention, most serious first.
struct PhoneBanners: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var services: PhoneServices
    @Environment(\.openURL) private var openURL
    /// Opens Settings at the section that fixes the problem.
    let openSettings: (PhoneSettingsView.Jump?) -> Void

    var body: some View {
        VStack(spacing: DS.Space.sm) {
            if let problem = store.connectionProblem {
                ConnectionProblemView(problem: problem, compact: true) { store.apply($0) }
            }
            if store.notificationsBlocked {
                StatusBanner(severity: .critical, title: "Notifications are off for GlucOS",
                             message: "Glucose alerts can't reach you.",
                             action: BannerAction(title: "Turn On") { openURL(AlertManager.notificationSettingsURL) },
                             density: .compact)
            }
            if services.liveActivityEnabled && !services.liveActivity.systemEnabled {
                StatusBanner(severity: .warning, title: "Live Activities are off for GlucOS",
                             message: "Turn them on in Settings to see your glucose on the Lock Screen.",
                             action: BannerAction(title: "Open Settings") {
                                 if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                             },
                             density: .compact)
            }
            if !services.relaySettings.isConfigured && settings.alertsEnabled {
                StatusBanner(severity: .info, title: "Alerts only while GlucOS is open",
                             message: "iPhone apps can't check in the background reliably. Connect the push relay for alerts and a live Lock Screen card at all times.",
                             action: BannerAction(title: "Set Up") { openSettings(.relay) },
                             density: .compact)
            } else if let error = services.relayError {
                StatusBanner(severity: .warning, title: "Can't reach the push relay",
                             message: "\(error) Alerts come from this phone while GlucOS is open.",
                             density: .compact)
            }
        }
    }
}
