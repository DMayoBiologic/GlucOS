import SwiftUI
import AppKit
import ServiceManagement

/// Settings, grouped by what people come to change: the account, what counts as in range, how
/// alerts behave, how logging works, and the rest.
struct SettingsView: View {
    enum Tab: String { case general, account, glucose, alerts, logging, advanced }

    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var logbook: LogbookStore

    @AppStorage("settingsTab") private var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            AccountSettingsTab()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag(Tab.account)
            GlucoseSettingsTab()
                .tabItem { Label("Glucose", systemImage: "target") }
                .tag(Tab.glucose)
            AlertSettingsTab(openGlucoseTab: { tab = .glucose })
                .tabItem { Label("Alerts", systemImage: "bell.badge") }
                .tag(Tab.alerts)
            LoggingSettingsTab()
                .tabItem { Label("Logging", systemImage: "syringe") }
                .tag(Tab.logging)
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
                .tag(Tab.advanced)
        }
        // Resizable: the window opens at a comfortable size, can grow for long lists (presets,
        // alerts) and shrink to a laptop-friendly minimum without clipping a Form.
        .frame(minWidth: 500, idealWidth: 580, maxWidth: 860, minHeight: 420, idealHeight: 600, maxHeight: .infinity)
        .onAppear {
            // Send someone with a broken connection straight to where they can fix it.
            if !settings.hasCredentials || store.connectionProblem != nil { tab = .account }
        }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Show change since last reading", isOn: $settings.showDeltaInMenuBar)
                Toggle("Colour-code the menu bar icon", isOn: $settings.colorMenuBarIcon)
                Picker("Popover chart", selection: $settings.chartHours) {
                    Text("Last 3 hours").tag(3)
                    Text("Last 6 hours").tag(6)
                    Text("Last 12 hours").tag(12)
                }
                Toggle("Show the forecast on the popover chart", isOn: $settings.showForecast)
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("Colour-coding tints the drop green, orange or red by range. Stale data always shows a plain warning sign instead.")
                    .foregroundStyle(.secondary)
            }

            Section {
                TextSizePicker()
            } header: {
                Text("Appearance")
            }

            Section {
                // A binding rather than onChange: the toggle only ever reflects the service's real
                // state, and correcting it never re-runs register/unregister.
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                if let loginError {
                    StatusBanner(severity: .warning, title: "Launch at login needs attention", message: loginError,
                                 onDismiss: { self.loginError = nil }, density: .compact)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
            } header: {
                Text("Startup")
            } footer: {
                Text("Recommended, so alerts keep working after a restart.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Desktop widget") {
                    Text("Right-click the desktop → Edit Widgets → “GlucOS”")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Setup assistant") {
                    Button("Run Setup Again…") {
                        openWindow(id: OnboardingView.windowID)
                        NSApp.activate()
                    }
                }
            } header: {
                Text("Getting Started")
            }
        }
        .formStyle(.grouped)
        // Approval for a login item happens in System Settings, so pick up the result on return.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            let enabled = SMAppService.mainApp.status == .enabled
            launchAtLogin = enabled
            if enabled { loginError = nil }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on {
                if service.status == .requiresApproval {
                    // Already registered; macOS is waiting for the user to allow it.
                    SMAppService.openSystemSettingsLoginItems()
                    loginError = "Allow GlucOS in System Settings → General → Login Items to finish turning this on."
                } else if service.status != .enabled {
                    try service.register()
                    loginError = nil
                }
            } else if service.status != .notRegistered {
                try service.unregister()
                loginError = nil
            }
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = service.status == .enabled
    }
}

// MARK: - Account

private struct AccountSettingsTab: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings

    @State private var email = ""
    @State private var password = ""
    @State private var region = "au"
    @State private var revealsPassword = false
    @State private var signingIn = false
    @State private var confirmingSignOut = false

    private var edited: Bool {
        email != settings.email || password != settings.password || region != settings.region
    }

    var body: some View {
        Form {
            Section {
                ConnectionStatusRow()
                if let problem = store.connectionProblem, !signingIn {
                    ConnectionProblemView(problem: problem, compact: true) { store.apply($0) }
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
            }

            Section {
                TextField("Email", text: $email, prompt: Text("follower@example.com"))
                    .textContentType(.username)
                    .autocorrectionDisabled()
                LabeledContent("Password") {
                    HStack(spacing: 6) {
                        Group {
                            if revealsPassword {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        .labelsHidden()
                        .textContentType(.password)
                        Button {
                            revealsPassword.toggle()
                        } label: {
                            Image(systemName: revealsPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(revealsPassword ? "Hide password" : "Show password")
                    }
                }
                RegionPicker(region: $region)
                HStack(spacing: 8) {
                    if settings.hasCredentials {
                        Button("Sign Out…", role: .destructive) { confirmingSignOut = true }
                    }
                    Spacer()
                    if signingIn {
                        ProgressView().controlSize(.small)
                        Text("Signing in…").font(.callout).foregroundStyle(.secondary)
                    }
                    Button(settings.hasCredentials && !edited ? "Reconnect" : "Sign In") { signIn() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || signingIn)
                }
            } header: {
                Text("LibreLinkUp Follower Account")
            } footer: {
                Text("Use the *follower* account that accepted the invitation from LibreLink, not your LibreLink login. Credentials are stored in the macOS Keychain and sent to Abbott. If logbook sync is on, they're also checked once by the GlucOS sync server to confirm the account, and not kept there.")
                    .foregroundStyle(.secondary)
            }

            Section {
                FollowerAccountHelp()
            }
        }
        .formStyle(.grouped)
        .onAppear {
            email = settings.email
            password = settings.password
            region = settings.region
        }
        .confirmationDialog("Sign out of LibreLinkUp?", isPresented: $confirmingSignOut) {
            Button("Sign Out", role: .destructive) {
                store.signOut()
                password = ""
            }
        } message: {
            Text("GlucOS stops fetching readings and alerts until you sign in again. Your logbook and stored history are kept.")
        }
    }

    private func signIn() {
        signingIn = true
        Task {
            _ = await store.signIn(email: email, password: password, region: region)
            signingIn = false
        }
    }
}

/// Connected / not signed in / problem, with the last reading's age.
struct ConnectionStatusRow: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(color.opacity(0.16))
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol).foregroundStyle(color).font(.system(size: 15, weight: .semibold))
                }
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if settings.hasCredentials {
                Button("Refresh") { Task { await store.refresh() } }
                    .disabled(store.isRefreshing)
            }
        }
    }

    /// Green only for a connection that is actually delivering fresh readings. Signed out is
    /// neutral; old or missing readings are a warning, never a reassuring colour.
    private var color: Color {
        if !settings.hasCredentials { return Palette.stale }
        if let p = store.connectionProblem { return p.severity.tint }
        return store.snapshot.current == nil || store.snapshot.isStale() ? BannerSeverity.warning.tint : BannerSeverity.success.tint
    }

    private var symbol: String {
        if !settings.hasCredentials { return "person.crop.circle.badge.questionmark" }
        if let p = store.connectionProblem { return p.systemImage }
        return store.snapshot.current == nil || store.snapshot.isStale() ? "clock.badge.exclamationmark" : "checkmark"
    }

    private var title: String {
        if !settings.hasCredentials { return "Not signed in" }
        if let p = store.connectionProblem { return p.title }
        if store.snapshot.current == nil { return "Connecting…" }
        return store.snapshot.isStale() ? "Connected, but no recent readings" : "Connected"
    }

    private var subtitle: String {
        if !settings.hasCredentials { return "Sign in below to start receiving readings." }
        var parts = [settings.email]
        if let cur = store.snapshot.current {
            parts.append("last reading \(Format.age(cur.age()))")
        }
        return parts.joined(separator: " · ")
    }
}

struct RegionPicker: View {
    @Binding var region: String

    var body: some View {
        Picker("Region", selection: $region) {
            Text("Australia").tag("au")
            Text("Europe").tag("eu")
            Text("Europe 2").tag("eu2")
            Text("United States").tag("us")
            Text("Asia-Pacific").tag("ap")
            Text("Canada").tag("ca")
            Text("Japan").tag("jp")
            Divider()
            Text("Auto-detect").tag("global")
        }
        .help("Where the LibreLinkUp account was created. Auto-detect works for most people but takes an extra step at sign-in.")
    }
}

/// How to get a LibreLinkUp follower account, step by step.
struct FollowerAccountHelp: View {
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                step(1, "On the phone that reads the sensor, open **LibreLink** → Menu → Connected Apps → LibreLinkUp → Connect.")
                step(2, "Invite an email address you'll use only for following (it can't be your LibreLink email).")
                step(3, "Install **LibreLinkUp** (on any phone), create an account with that email, and accept the invitation.")
                step(4, "Sign in to GlucOS with that LibreLinkUp email and password.")
            }
            .padding(.top, 6)
        } label: {
            Label("How do I get a follower account?", systemImage: "questionmark.circle")
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Palette.brand))
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Glucose

private struct GlucoseSettingsTab: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Units") {
                Picker("Glucose units", selection: $settings.unit) {
                    ForEach(GlucoseUnit.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                TargetRangeEditor(settings: settings)
                    .padding(.vertical, 4)
            } header: {
                Text("Target Range")
            } footer: {
                Text("Readings from \(settings.unit.format(mgdl: settings.lowMgdl)) to \(settings.unit.format(mgdl: settings.highMgdl, withUnit: true)) count as in range. This sets the colours everywhere, time in range, and when low and high alerts fire. Urgent low (below \(settings.unit.format(mgdl: 54))) and very high (above \(settings.unit.format(mgdl: 250))) are fixed.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Alerts

private struct AlertSettingsTab: View {
    let openGlucoseTab: () -> Void

    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings

    @State private var notificationsAllowed: Bool?
    @State private var permissionChecked = false

    private static let cooldownChoices = [5, 10, 15, 20, 30, 45, 60, 90, 120]

    var body: some View {
        let u = settings.unit
        Form {
            Section {
                Toggle("Glucose alerts", isOn: $settings.alertsEnabled)
                LabeledContent("macOS notifications") {
                    HStack(spacing: 6) {
                        switch notificationsAllowed {
                        case .some(true):
                            Label("Allowed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Tone.success.textColor)
                        case .some(false):
                            Label("Off", systemImage: "bell.slash.fill")
                                .foregroundStyle(Tone.critical.textColor)
                        case .none where permissionChecked:
                            Button("Allow Notifications…") {
                                store.alerts.requestAuthorization()
                                Task {
                                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                                    await refreshNotificationStatus()
                                }
                            }
                        case .none:
                            ProgressView().controlSize(.mini)
                        }
                    }
                }
                if notificationsAllowed == false && settings.alertsEnabled {
                    StatusBanner(severity: .critical, systemImage: "bell.slash.fill",
                                 title: "Alerts can't reach you",
                                 message: "Notifications for GlucOS are turned off in System Settings, so lows and highs won't show on this Mac.",
                                 action: BannerAction(title: "Turn On…", systemImage: "gearshape") {
                                     NSWorkspace.shared.open(AlertManager.notificationSettingsURL)
                                 },
                                 density: .compact)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
                LabeledContent("Check it works") {
                    Button("Send Test Alert") { store.alerts.sendTest() }
                        .disabled(notificationsAllowed != true)
                }
            } footer: {
                Text("These supplement, never replace, the alarms on your phone.")
                    .foregroundStyle(.secondary)
            }

            Section {
                AlertRow(title: "Urgent low", detail: "Below \(u.format(mgdl: 54, withUnit: true)). Repeats every 5 minutes.",
                         tint: GlucoseRange.urgentLow.tint, isOn: nil)
                AlertRow(title: "Low", detail: "Below \(u.format(mgdl: settings.lowMgdl, withUnit: true))",
                         tint: GlucoseRange.low.tint, isOn: nil)
                AlertRow(title: "High", detail: "Above \(u.format(mgdl: settings.highMgdl, withUnit: true))",
                         tint: GlucoseRange.high.tint, isOn: $settings.alertOnHigh)
                AlertRow(title: "Very high", detail: "Above \(u.format(mgdl: 250, withUnit: true))",
                         tint: GlucoseRange.veryHigh.tint, isOn: nil)
            } header: {
                Text("Glucose")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Lows and very highs always alert while glucose alerts are on.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Change Target Range…", action: openGlucoseTab)
                        .buttonStyle(.link)
                }
            }
            .disabled(!settings.alertsEnabled)

            Section {
                AlertRow(title: "Low predicted", detail: "When the forecast goes below \(u.format(mgdl: settings.lowMgdl, withUnit: true)), or urgent low, within the time below",
                         tint: GlucoseRange.low.tint, systemImage: "arrow.down.forward.and.arrow.up.backward", isOn: $settings.alertOnPredictedLow)
                AlertRow(title: "High predicted", detail: settings.alertOnHigh
                            ? "When the forecast goes above \(u.format(mgdl: settings.highMgdl, withUnit: true)) or very high"
                            : "When the forecast goes above \(u.format(mgdl: 250, withUnit: true)) (high alerts are off)",
                         tint: GlucoseRange.high.tint, systemImage: "arrow.up.forward", isOn: $settings.alertOnPredictedHigh)
                Picker("Warn me up to", selection: $settings.predictiveAlertMinutes) {
                    ForEach([10, 15, 20, 30], id: \.self) { m in Text("\(m) minutes ahead").tag(m) }
                }
                .disabled(!settings.alertOnPredictedLow && !settings.alertOnPredictedHigh)
            } header: {
                Text("Forecast")
            } footer: {
                Text("A heads-up from GlucOS's estimate of where glucose is heading, based on the recent trend and, once it has learnt from your logs, the insulin and carbs still acting. Forecasts can be wrong: always check your reading before acting. Only fires while glucose is falling or rising, and never replaces the alerts above.")
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.alertsEnabled)

            Section {
                AlertRow(title: "Rising or falling quickly", detail: "When the trend arrow points steeply up or down",
                         tint: Palette.brand, systemImage: "arrow.up.right", isOn: $settings.alertOnRapidChange)
                AlertRow(title: "No recent data", detail: "No reading for more than 6 minutes",
                         tint: Palette.stale, systemImage: "antenna.radiowaves.left.and.right.slash", isOn: $settings.alertOnStale)
                AlertRow(title: "Sensor expiring", detail: "Less than 24 hours left on the sensor",
                         tint: BannerSeverity.warning.tint, systemImage: "sensor.tag.radiowaves.forward", isOn: $settings.alertOnSensorExpiry)
                Picker("Repeat an ongoing alert every", selection: $settings.alertCooldownMinutes) {
                    ForEach(Self.cooldownChoices, id: \.self) { m in Text(m < 60 ? "\(m) minutes" : m == 60 ? "1 hour" : "\(LogFormat.number(Double(m) / 60)) hours").tag(m) }
                    if !Self.cooldownChoices.contains(settings.alertCooldownMinutes) {
                        Text("\(settings.alertCooldownMinutes) minutes").tag(settings.alertCooldownMinutes)
                    }
                }
            } header: {
                Text("Also Notify Me About")
            } footer: {
                Text("Repeats apply to low, high, very high and rapid-change alerts. Urgent low always repeats every 5 minutes.")
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.alertsEnabled)
        }
        .formStyle(.grouped)
        .task { await refreshNotificationStatus() }
        // Pick up a change made in System Settings when the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshNotificationStatus() }
        }
    }

    private func refreshNotificationStatus() async {
        notificationsAllowed = await AlertManager.notificationsAllowed()
        permissionChecked = true
        await store.checkNotificationPermission()
    }
}

/// One alert: what it is, when it fires, and a switch (or "Always on").
private struct AlertRow: View {
    let title: String
    let detail: String
    let tint: Color
    var systemImage: String?
    let isOn: Binding<Bool>?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(tint)
                        .frame(width: 20, height: 20)
                        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    Capsule().fill(tint.gradient).frame(width: 5, height: 20)
                        .frame(width: 20)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            if let isOn {
                Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
            } else {
                Label("Always on", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Logging

/// Logbook sync on or off, and how it's going.
private struct LogbookSyncSection: View {
    @EnvironmentObject var sync: LogbookSyncService

    var body: some View {
        Section {
            Toggle("Sync logbook with your other devices", isOn: $sync.enabled)
            if sync.enabled {
                LabeledContent("Status") {
                    HStack(spacing: DS.Space.xs) {
                        if sync.status == .syncing { ProgressView().controlSize(.small) }
                        Text(sync.summary)
                            .foregroundStyle(sync.isProblem ? Tone.warning.textColor : Color.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Button("Sync Now") { sync.requestSync() }
                    .disabled(sync.status == .syncing || sync.status == .needsAccount)
            }
        } header: {
            Text("Sync")
        } footer: {
            Text("Doses, food, site changes, tags and presets are shared with GlucOS on your iPhone, signed in with the same LibreLinkUp account. Everything is kept on this Mac too and works offline; changes sync when you're back online. If an entry is edited on two devices, the later edit is kept.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct LoggingSettingsTab: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var logbook: LogbookStore

    @EnvironmentObject var store: GlucoseStore

    @State private var renaming: LogPreset?
    @State private var newName = ""
    @State private var editingBolus = false

    var body: some View {
        Form {
            LogbookSyncSection()
            Section {
                Picker("Therapy", selection: $settings.therapy) {
                    if settings.therapy == .notSet { Text("Choose…").tag(TherapyType.notSet) }
                    ForEach([TherapyType.injections, .pump, .noInsulin]) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                }
            } header: {
                Text("How You Take Insulin")
            } footer: {
                Text(settings.therapy == .notSet
                     ? "Decides what GlucOS asks when you log, and which patterns it shows."
                     : settings.therapy.detail)
                    .foregroundStyle(.secondary)
            }

            if settings.therapy.logsInsulin {
                Section {
                    Picker("Type", selection: $settings.bolusInsulinKind) {
                        ForEach(settings.therapy == .pump ? InsulinKind.pumpKinds : InsulinKind.allCases.filter(\.isBolus)) {
                            Text($0.title).tag($0)
                        }
                    }
                    TextField("Name", text: $settings.bolusInsulinName, prompt: Text(settings.bolusInsulinKind.examples))
                    if settings.therapy == .injections {
                        TextField("Long-acting", text: $settings.basalInsulinName, prompt: Text(InsulinKind.long.examples))
                    }
                } header: {
                    Text(settings.therapy == .pump ? "Insulin in Your Pump" : "Your Insulins")
                } footer: {
                    Text("Pre-filled when you log a dose.").foregroundStyle(.secondary)
                }
            }

            if settings.therapy.logsInsulin {
                Section {
                    HStack {
                        BolusSettingsSummary(settings: logbook.bolusSettings, unit: settings.unit)
                        Spacer()
                        Button(logbook.bolusSettings?.isConfirmed == true ? "Edit…" : "Set Up…") { editingBolus = true }
                    }
                } header: {
                    Text("Bolus Calculator")
                } footer: {
                    Text("Uses only the settings you enter and confirm. Shared with GlucOS on your iPhone. Not medical advice.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if logbook.presets.isEmpty {
                    Text("Tick “Save as preset” when you log something you log often, like a usual breakfast or a hypo treatment. It then appears under Quick add for one-tap logging.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(logbook.presets) { p in
                        HStack(spacing: 10) {
                            Image(systemName: p.systemImage)
                                .foregroundStyle(Palette.brand)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name)
                                Text(p.summary).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                newName = p.name
                                renaming = p
                            } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless)
                                .help("Rename")
                            Button {
                                logbook.deletePreset(id: p.id)
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Delete preset")
                        }
                    }
                    .onMove { logbook.movePresets(from: $0, to: $1) }
                }
            } header: {
                Text("Quick-Add Presets")
            } footer: {
                if !logbook.presets.isEmpty {
                    Text("Drag to reorder. Presets only repeat amounts you entered yourself.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text("Patterns in Dashboard → Insights are observations from your own logs and readings. They aren't medical advice and never suggest a dose. Don't change your insulin, ratios or pump settings based on them without talking to your diabetes care team.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $editingBolus) {
            BolusSettingsEditor(current: logbook.bolusSettings) { editingBolus = false }
                .frame(minWidth: 480, idealWidth: 540, minHeight: 520, idealHeight: 640)
                .environmentObject(logbook)
                .environmentObject(store)
                .environmentObject(settings)
        }
        .alert("Rename Preset", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if var p = renaming, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                    p.name = newName.trimmingCharacters(in: .whitespaces)
                    logbook.savePreset(p)
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

// MARK: - Advanced

private struct AdvancedSettingsTab: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var updater: Updater

    var body: some View {
        Form {
            Section {
                Picker("Check for new readings", selection: $settings.pollIntervalSeconds) {
                    Text("Every 30 seconds").tag(30)
                    Text("Every minute").tag(60)
                    Text("Every 2 minutes").tag(120)
                    Text("Every 5 minutes").tag(300)
                    if ![30, 60, 120, 300].contains(settings.pollIntervalSeconds) {
                        Text("Every \(settings.pollIntervalSeconds) seconds").tag(settings.pollIntervalSeconds)
                    }
                }
                Stepper("Sensor lifetime: \(settings.sensorLifetimeDays) days", value: $settings.sensorLifetimeDays, in: 10...15)
                LabeledContent("Client version") {
                    HStack {
                        TextField("Client version", text: $settings.clientVersion)
                            .labelsHidden()
                            .monospacedDigit()
                            .frame(width: 90)
                        Button("Apply") { store.reconnect() }
                    }
                }
            } header: {
                Text("Connection")
            } footer: {
                Text("Libre sensors last 14 days (Libre 2, 3) or 15 days (Libre 2 Plus, 3 Plus). Abbott periodically raises the minimum LibreLinkUp client version; GlucOS offers to switch when that happens.")
                    .foregroundStyle(.secondary)
            }
            Section("Updates") {
                LabeledContent("Version", value: updater.version)
                LabeledContent {
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheck)
                } label: {
                    if !updater.isConfigured {
                        Label("Not configured in this build (no Sparkle public key).", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Tone.warning.textColor)
                    } else {
                        Text("Checks hourly; installs and relaunches automatically.")
                    }
                }
            }
            Section("Diagnostics") {
                LabeledContent("Status", value: store.statusLine)
                LabeledContent("Data folder") {
                    HStack {
                        Text(SharedStore.containerURL?.path ?? "unavailable")
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        if let url = SharedStore.containerURL {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                    }
                }
                LabeledContent("Session") {
                    Button("Reconnect") { store.reconnect() }
                }
            }
        }
        .formStyle(.grouped)
    }
}
