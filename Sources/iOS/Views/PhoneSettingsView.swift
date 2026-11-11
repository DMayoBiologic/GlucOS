import SwiftUI

/// LibreLinkUp regions, as on the Mac.
struct LibreRegion: Identifiable {
    let id: String
    let name: String

    static let all: [LibreRegion] = [
        .init(id: "au", name: "Australia"), .init(id: "eu", name: "Europe"), .init(id: "eu2", name: "Europe 2"),
        .init(id: "us", name: "United States"), .init(id: "ap", name: "Asia-Pacific"), .init(id: "ca", name: "Canada"),
        .init(id: "jp", name: "Japan"), .init(id: "global", name: "Auto-detect"),
    ]
}

// MARK: - Bolus calculator

private struct PhoneBolusSettingsScreen: View {
    @EnvironmentObject var logbook: LogbookStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        BolusSettingsEditor(current: logbook.bolusSettings) { dismiss() }
            .navigationTitle("Bolus calculator")
            .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Sign in

struct PhoneSignInView: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    /// On the first run: go back and follow someone instead. Nil when shown from the follower screen.
    var onFollowInstead: (() -> Void)?
    @State private var email = ""
    @State private var password = ""
    @State private var region = "au"
    @State private var working = false
    @State private var problem: ConnectionProblem?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    Image(systemName: "drop.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Palette.brandGradient)
                    Text("Sign in with your LibreLinkUp follower account")
                        .dsFont(.sectionTitle)
                    Text("The account that accepted the invitation in the LibreLinkUp app, not your LibreLink login. Your password stays in this iPhone's Keychain (and on your push relay, if you set one up). The GlucOS sync server checks it once so your logbook can sync, and doesn't keep it.")
                        .dsFont(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, DS.Space.xs)
            }
            Section("Account") {
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Picker("Region", selection: $region) {
                    ForEach(LibreRegion.all) { Text($0.name).tag($0.id) }
                }
            }
            if let problem {
                Section { ConnectionProblemView(problem: problem, compact: true) { store.apply($0) } }
            }
            Section {
                Button {
                    working = true
                    Task {
                        problem = await store.signIn(email: email, password: password, region: region)
                        working = false
                        if problem == nil {
                            UserDefaults.standard.set(PhoneMode.sensor.rawValue, forKey: "phoneMode")
                            if onFollowInstead == nil { dismiss() }
                        }
                    }
                } label: {
                    HStack {
                        Text("Sign In")
                        Spacer()
                        if working { ProgressView() }
                    }
                }
                .disabled(working || email.isEmpty || password.isEmpty)
            }
            if let onFollowInstead {
                Section {
                    Button("I'm Following Someone Instead", systemImage: "person.2.wave.2", action: onFollowInstead)
                } footer: {
                    Text("Someone sent you a GlucOS share link? You don't need a sensor or a LibreLinkUp account to follow it.")
                }
            }
        }
        .navigationTitle("Sign In")
        .onAppear {
            email = settings.email
            region = settings.region
        }
    }
}

// MARK: - Settings

struct PhoneSettingsView: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var services: PhoneServices
    @EnvironmentObject var logbookSync: LogbookSyncService
    @EnvironmentObject var logbook: LogbookStore
    @ObservedObject private var relay = RelaySettings.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var notificationsAllowed: Bool?
    @State private var relaySecret = ""

    var body: some View {
        Form {
            accountSection
            displaySection
            loggingSection
            if !logbook.presets.isEmpty { presetsSection }
            syncSection
            alertsSection
            lockScreenSection
            sharingSection
            FollowingSettingsSection()
            relaySection
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                Text("Personal use. Not a medical device. Confirm readings and alerts with your sensor app before acting.")
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task {
            relaySecret = relay.secret
            notificationsAllowed = await AlertManager.notificationsAllowed()
            await services.refreshRelayStatus()
        }
    }

    // MARK: Sections

    private var accountSection: some View {
        Section("LibreLinkUp") {
            LabeledContent("Account", value: settings.email)
            LabeledContent("Region", value: LibreRegion.all.first { $0.id == settings.region }?.name ?? settings.region)
            LabeledContent("Status", value: store.statusLine)
            Button("Sign Out", role: .destructive) { store.signOut() }
        }
    }

    private var displaySection: some View {
        Section {
            Picker("Units", selection: $settings.unit) {
                ForEach(GlucoseUnit.allCases) { Text($0.label).tag($0) }
            }
            TargetRangeEditor(settings: settings)
                .padding(.vertical, DS.Space.xs)
            Toggle("Show forecast on the chart", isOn: $settings.showForecast)
        } header: {
            Text("Display")
        } footer: {
            Text("The target range colours every reading, chart and alert, here and on the Lock Screen.")
        }
    }

    private var loggingSection: some View {
        Section {
            Picker("Insulin", selection: $settings.therapy) {
                ForEach(TherapyType.allCases) { Text($0.title).tag($0) }
            }
            if settings.therapy.logsInsulin {
                Picker(settings.therapy == .pump ? "Pump insulin" : "Usual mealtime insulin", selection: $settings.bolusInsulinKind) {
                    ForEach(settings.therapy == .pump ? InsulinKind.pumpKinds : InsulinKind.allCases.filter(\.isBolus)) {
                        Text($0.title).tag($0)
                    }
                }
                TextField("Brand name", text: $settings.bolusInsulinName, prompt: Text(settings.bolusInsulinKind.examples))
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                NavigationLink {
                    PhoneBolusSettingsScreen()
                } label: {
                    BolusSettingsSummary(settings: logbook.bolusSettings, unit: settings.unit)
                }
            }
        } header: {
            Text("Logging")
        } footer: {
            Text(settings.therapy == .notSet
                 ? "Tap Log on the main screen to record insulin, food and events. GlucOS asks how you take insulin the first time."
                 : "\(settings.therapy.detail) GlucOS records what you enter; only the bolus calculator suggests a dose, from settings you confirm. Say \"Log in GlucOS\" to Siri, or add the Log widget to your Lock Screen, to log in one step.")
        }
    }

    private var presetsSection: some View {
        Section {
            ForEach(logbook.presets) { p in
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name)
                        if !p.summary.isEmpty { Text(p.summary).dsFont(.caption).foregroundStyle(.secondary) }
                    }
                } icon: {
                    Image(systemName: p.systemImage).foregroundStyle(Palette.brand)
                }
            }
            .onDelete { idx in idx.map { logbook.presets[$0].id }.forEach(logbook.deletePreset(id:)) }
            .onMove { logbook.movePresets(from: $0, to: $1) }
        } header: {
            HStack {
                Text("Presets")
                Spacer()
                EditButton().textCase(nil)
            }
        } footer: {
            Text("One-tap quick adds in the log sheet. Save one by turning on Save as preset when you log.")
        }
    }

    private var syncSection: some View {
        Section {
            Toggle("Sync logbook", isOn: $logbookSync.enabled)
            if logbookSync.enabled {
                LabeledContent("Status") {
                    Text(logbookSync.summary)
                        .foregroundStyle(logbookSync.isProblem ? Tone.warning.textColor : Color.secondary)
                        .multilineTextAlignment(.trailing)
                }
                Button("Sync Now") { logbookSync.requestSync() }
                    .disabled(logbookSync.status == .syncing || logbookSync.status == .needsAccount)
            }
        } header: {
            Text("Logbook")
        } footer: {
            Text("Doses, food, site changes and events logged here or in GlucOS on your Mac, shared through the GlucOS sync server with the same LibreLinkUp account. The forecast and insulin on board here count them.")
        }
    }

    private var alertsSection: some View {
        Section {
            Toggle("Glucose alerts", isOn: $settings.alertsEnabled)
            if settings.alertsEnabled {
                if notificationsAllowed == false {
                    Button("Notifications are off. Turn them on in Settings") { openURL(AlertManager.notificationSettingsURL) }
                        .foregroundStyle(Tone.critical.textColor)
                }
                Toggle("High (above target)", isOn: $settings.alertOnHigh)
                Toggle("Rising or falling quickly", isOn: $settings.alertOnRapidChange)
                Toggle("No recent data", isOn: $settings.alertOnStale)
                Toggle("Sensor ending", isOn: $settings.alertOnSensorExpiry)
                Toggle("Predicted lows", isOn: $settings.alertOnPredictedLow)
                Toggle("Predicted highs", isOn: $settings.alertOnPredictedHigh)
                if settings.alertOnPredictedLow || settings.alertOnPredictedHigh {
                    Picker("Warn me ahead by", selection: $settings.predictiveAlertMinutes) {
                        ForEach([10, 15, 20, 30], id: \.self) { Text("\($0) min").tag($0) }
                    }
                }
                Picker("Repeat no more than every", selection: $settings.alertCooldownMinutes) {
                    ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
                }
                Button("Send Test Alert") {
                    store.alerts.requestAuthorization()
                    store.alerts.sendTest()
                }
            }
        } header: {
            Text("Alerts")
        } footer: {
            Text("Lows and very highs always alert while alerts are on; urgent lows repeat every 5 minutes. \(services.relayStatus?.isDeliveringAlerts() == true ? "Your push relay is sending these, so they arrive even when GlucOS is closed." : "Without the push relay, alerts can only come while GlucOS is open or briefly refreshing in the background.")")
        }
    }

    private var lockScreenSection: some View {
        Section {
            Toggle("Live Activity", isOn: $services.liveActivityEnabled)
            if services.liveActivityEnabled {
                LabeledContent("Status", value: liveActivityStatus)
                if !services.liveActivity.systemEnabled {
                    Button("Allow Live Activities in Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            }
        } header: {
            Text("Lock Screen")
        } footer: {
            Text("Your reading, trend, the last 3 hours and the forecast on the Lock Screen and in the Dynamic Island. iOS ends a Live Activity after 8 hours; the push relay starts a fresh one automatically. Without the relay it only updates while GlucOS is open.")
        }
    }

    private var sharingSection: some View {
        Section {
            NavigationLink {
                PhoneSharingView(showsDone: false)
            } label: {
                Label("Share Live Readings", systemImage: "person.2.wave.2")
            }
        } header: {
            Text("Sharing")
        } footer: {
            Text("Send family a link in Messages that shows your glucose live, and on their Lock Screen if they have GlucOS.")
        }
    }

    private var liveActivityStatus: String {
        if !services.liveActivity.systemEnabled { return "Off in iOS Settings" }
        if let e = services.liveActivity.lastError { return e }
        return services.liveActivity.isRunning ? "On the Lock Screen" : "Starts when GlucOS opens"
    }

    private var relaySection: some View {
        Section {
            TextField("Relay address", text: $relay.urlString, prompt: Text("https://….supabase.co/functions/v1/relay"))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Relay secret", text: $relaySecret)
                .onSubmit { relay.secret = relaySecret }
                .onChange(of: relaySecret) { _, new in relay.secret = new }
            if relay.isConfigured {
                if let e = services.relayError {
                    Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning.textColor)
                } else if let st = services.relayStatus {
                    LabeledContent("Fetching", value: st.lastFetchAt.map { PopoverFormat.ageAgo(Date().timeIntervalSince1970 - $0) } ?? "Not yet")
                    if let err = st.lastError { LabeledContent("LibreLinkUp", value: err) }
                    LabeledContent("Alerts", value: st.isDeliveringAlerts() ? "Sent by the relay" : "From this phone")
                    LabeledContent("Lock Screen card", value: st.activityID != nil ? "Kept live by the relay" : (st.hasPushToStartToken ? "Ready" : "Waiting for iPhone"))
                    if let err = st.lastPushError { LabeledContent("Last push", value: err) }
                }
                Button("Send Test Push") { Task { await services.sendRelayTest() } }
                Button("Reconnect") { Task { await services.syncRelay(force: true) } }
            }
            if let e = services.pushRegistrationError {
                Text("Push registration failed: \(e)").dsFont(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Push relay")
        } footer: {
            Text("A small server of your own that checks LibreLinkUp every minute and pushes alerts and Lock Screen updates to this iPhone while it's locked. It receives your LibreLinkUp login so it can fetch for you. Signed in with the same LibreLinkUp account as the relay, this iPhone connects by itself. See docs/iOS.md to set one up.")
        }
    }
}
