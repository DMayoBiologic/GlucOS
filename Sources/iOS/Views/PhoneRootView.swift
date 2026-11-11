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
                choice(title: "I'm following someone",
                       detail: "No sensor or account needed. Open the GlucOS link someone sent you to see their glucose live, on your Lock Screen, with their alerts.",
                       systemImage: "person.2.wave.2.fill") { mode = .follower }

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
    @State private var showsSettings = false
    @State private var showsSharing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Space.lg) {
                    PhoneBanners(showsSettings: $showsSettings)
                    PhoneHeroCard()
                    ForEach(follows.follows) { PhoneFollowingCard(follow: $0) }
                    PhoneOnBoardCard()
                    PhoneChartCard()
                    PhoneLogbookCard()
                    PhoneGlanceCard()
                    if let sensor = store.snapshot.sensor {
                        PhoneSensorCard(sensor: sensor)
                    }
                    Text("Not a medical device. Confirm readings and alerts with your sensor app before acting.")
                        .dsFont(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, DS.Space.xs)
                }
                .padding(.horizontal, DS.Space.lg)
                .padding(.bottom, DS.Space.lg)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background { PhoneBackdrop(tone: store.snapshot.displayTone()) }
            .refreshable { await store.refresh() }
            // The one place to start logging. A bar under the content rather than a button over
            // it, so it never covers a logbook row.
            .safeAreaInset(edge: .bottom, spacing: 0) { PhoneLogBar() }
            .navigationTitle("GlucOS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showsSharing = true } label: { Image(systemName: "person.2.wave.2") }
                        .accessibilityLabel("Share live readings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showsSettings) {
                NavigationStack { PhoneSettingsView() }
            }
            .sheet(isPresented: $showsSharing) {
                NavigationStack { PhoneSharingView() }
            }
            .onChange(of: router.request?.id) { _, id in
                // A log link arriving while Settings or Sharing is open: show the log sheet instead.
                if id != nil { showsSettings = false; showsSharing = false }
            }
            .sheet(item: $router.request) { request in
                PhoneLogSheet(target: request.target)
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

/// The screen background: the grouped background with a faint wash of the reading's colour at the
/// top, like the glow behind the Mac popover's hero.
struct PhoneBackdrop: View {
    let tone: Tone

    var body: some View {
        ZStack(alignment: .top) {
            Color(uiColor: .systemGroupedBackground)
            AmbientGlow(tint: tone.color, intensity: 0.45)
                .frame(height: 360)
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
        }
        .ignoresSafeArea()
    }
}

/// Problems that need attention, most serious first.
struct PhoneBanners: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var services: PhoneServices
    @Environment(\.openURL) private var openURL
    @Binding var showsSettings: Bool

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
                             action: BannerAction(title: "Set Up") { showsSettings = true },
                             density: .compact)
            } else if let error = services.relayError {
                StatusBanner(severity: .warning, title: "Can't reach the push relay",
                             message: "\(error) Alerts come from this phone while GlucOS is open.",
                             density: .compact)
            }
        }
    }
}
