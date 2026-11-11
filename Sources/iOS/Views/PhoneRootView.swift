import SwiftUI

/// Sign in first; after that, the glucose screen. A phone that only follows other people's
/// shared readings shows those instead.
struct PhoneRootView: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var follows: FollowStore

    var body: some View {
        Group {
            if settings.hasCredentials {
                PhoneHomeView()
            } else if follows.isFollowing {
                FollowingHomeView()
            } else {
                NavigationStack { PhoneSignInView() }
            }
        }
        .alert(follows.notice ?? "", isPresented: Binding(get: { follows.notice != nil },
                                                          set: { if !$0 { follows.notice = nil } })) {
            Button("OK") { follows.notice = nil }
        }
    }
}

/// The main screen: the same cards as the Mac popover, stacked for a phone.
struct PhoneHomeView: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var services: PhoneServices
    @EnvironmentObject var follows: FollowStore
    @State private var showsSettings = false
    @State private var showsSharing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Space.lg) {
                    PhoneBanners(showsSettings: $showsSettings)
                    PhoneHeroCard()
                    ForEach(follows.follows) { PhoneFollowingCard(follow: $0) }
                    PhoneChartCard()
                    if let outlook = store.snapshot.currentOutlook() {
                        PhoneOutlookCard(outlook: outlook)
                    }
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
                .padding(.bottom, DS.Space.xxl)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background { PhoneBackdrop(tone: store.snapshot.displayTone()) }
            .refreshable { await store.refresh() }
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
