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

    /// Where the open tab is kept; the Insights Alerts card sets it to open on Alerts.
    static let tabKey = "settingsTab"
    @AppStorage(SettingsView.tabKey) private var tab: Tab = .general
    @StateObject private var search = SettingsSearchModel(catalog: SettingsCatalog.mac)

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
        // Search (docs/SettingsSearch.md): every tab has the field; a result on another tab switches
        // to it, then that tab scrolls to the row.
        .environment(\.settingsSearch, search)
        .onChange(of: search.pendingJump) { _, item in
            if let item, let target = item.tab.flatMap(Tab.init(rawValue:)), target != tab { tab = target }
        }
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
                    .settingsAnchor(.menuBarDelta)
                Toggle("Colour the reading by range", isOn: $settings.colorMenuBarIcon)
                    .settingsAnchor(.menuBarColour)
                Toggle("Show the last hour as a sparkline", isOn: $settings.showMenuBarSparkline)
                    .settingsAnchor(.menuBarSparkline)
                Toggle("Preview the last 2 hours on hover", isOn: $settings.showMenuBarHoverPreview)
                    .help("Rest the pointer on the menu bar reading to see the last two hours, the trend and how long ago it was taken.")
                    .settingsAnchor(.menuBarHover)
                Picker("Popover chart", selection: $settings.chartHours) {
                    Text("Last 3 hours").tag(3)
                    Text("Last 6 hours").tag(6)
                    Text("Last 12 hours").tag(12)
                    Text("Last 24 hours").tag(24)
                }
                .settingsAnchor(.popoverChart)
                Toggle("Show the forecast on the popover chart", isOn: $settings.showForecast)
                    .settingsAnchor(.showForecast)
                Toggle("Show yesterday's line on the popover chart", isOn: $settings.showYesterdayLine)
                    .help("A faint grey line of yesterday's readings at the same time of day. Right-click the chart to turn it on or off.")
                    .settingsAnchor(.showYesterday)
            } header: {
                SettingsSectionHeader("Menu Bar", systemImage: "menubar.rectangle")
            } footer: {
                Text("The reading takes its range colour; urgent lows always do. A stale reading turns grey and crossed through, with an amber warning sign and how old it is.")
                    .foregroundStyle(.secondary)
            }
            .settingsSection("Menu Bar")

            Section {
                TextSizePicker()
                    .settingsAnchor(.textSize)
            } header: {
                SettingsSectionHeader("Appearance", systemImage: "textformat.size")
            }
            .settingsSection("Appearance")

            Section {
                // A binding rather than onChange: the toggle only ever reflects the service's real
                // state, and correcting it never re-runs register/unregister.
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                    .settingsAnchor(.launchAtLogin)
                if let loginError {
                    StatusBanner(severity: .warning, title: "Launch at login needs attention", message: loginError,
                                 onDismiss: { self.loginError = nil }, density: .compact)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
            } header: {
                SettingsSectionHeader("Startup", systemImage: "power")
            } footer: {
                Text("Recommended, so alerts keep working after a restart.")
                    .foregroundStyle(.secondary)
            }
            .settingsSection("Startup")

            Section {
                LabeledContent("Desktop widget") {
                    Text("Right-click the desktop → Edit Widgets → “GlucOS”")
                        .foregroundStyle(.secondary)
                }
                .settingsAnchor(.desktopWidget)
                LabeledContent("Setup assistant") {
                    Button("Run Setup Again…") {
                        openWindow(id: OnboardingView.windowID)
                        NSApp.activate()
                    }
                }
                .settingsAnchor(.setupAssistant)
            } header: {
                SettingsSectionHeader("Getting Started", systemImage: "sparkles")
            }
            .settingsSection("Getting Started")
        }
        .formStyle(.grouped)
        .settingsSearchPage(.general)
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
                    if problem.severity != .info {
                        SendReportButton(feature: ConnectionProblem.diagnosticFeature, step: "fetch",
                                         message: "\(problem.title): \(problem.advice)")
                            .id(problem.title + problem.advice)
                    }
                }
            }

            Section {
                TextField("Email", text: $email, prompt: Text("follower@example.com"))
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .settingsAnchor(.account)
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
                SettingsSectionHeader("LibreLinkUp Follower Account", systemImage: "person.crop.circle")
            } footer: {
                Text("Use the *follower* account that accepted the invitation from LibreLink, not your LibreLink login. Credentials are stored in the macOS Keychain and sent to Abbott. If logbook sync is on, they're also checked once by the GlucOS sync server to confirm the account, and not kept there.")
                    .foregroundStyle(.secondary)
            }
            .settingsSection("LibreLinkUp Follower Account")

            Section {
                FollowerAccountHelp()
            }
        }
        .formStyle(.grouped)
        .settingsSearchPage(.account)
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
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var logbook: LogbookStore

    /// The latest reading while it's fresh, for the range editor's marker.
    private var freshMgdl: Double? {
        let s = store.snapshot
        guard let cur = s.current, !s.isStale() else { return nil }
        return cur.mgdl
    }

    var body: some View {
        Form {
            Section {
                Picker("Glucose units", selection: $settings.unit) {
                    ForEach(GlucoseUnit.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .settingsAnchor(.units)
            } header: {
                SettingsSectionHeader("Units", systemImage: "ruler")
            }
            .settingsSection("Units")

            Section {
                TargetRangeEditor(settings: settings, readingMgdl: freshMgdl, previewReadings: store.archive,
                              alertRecords: logbook.alerts)
                    .padding(.vertical, 4)
                    .settingsAnchor(.targetRange)
            } header: {
                SettingsSectionHeader("Target Range", systemImage: "target")
            } footer: {
                Text("Readings from \(settings.unit.format(mgdl: settings.lowMgdl)) to \(settings.unit.format(mgdl: settings.highMgdl, withUnit: true)) count as in range. This sets the colours everywhere, time in range, and when low and high alerts fire. Urgent low (below \(settings.unit.format(mgdl: 54))) and very high (above \(settings.unit.format(mgdl: 250))) are fixed.")
                    .foregroundStyle(.secondary)
            }
            .settingsSection("Target Range")
        }
        .formStyle(.grouped)
        .settingsSearchPage(.glucose)
    }
}

// MARK: - Alerts

private struct AlertSettingsTab: View {
    let openGlucoseTab: () -> Void

    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var logbook: LogbookStore
    @Environment(\.openWindow) private var openWindow
    /// Settings › Alerts › History, in a sheet over the tab (docs/AlertHistory.md).
    @State private var showsHistory = false

    @State private var notificationsAllowed: Bool?
    @State private var permissionChecked = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The alert repeat when the tab opened, for the repeat preview's "was" (kept across alerts
    /// being switched off and on).
    @State private var openingRepeat: Int?

    private static let cooldownChoices = [5, 10, 15, 20, 30, 45, 60, 90, 120]

    var body: some View {
        let u = settings.unit
        Form {
            Section {
                // The sections below dim and undim with it, and the "can't reach you" banner
                // expands in place (DependentRows).
                Toggle("Glucose alerts", isOn: $settings.alertsEnabled.revealingRows(
                    shown: { notificationsAllowed == false && settings.alertsEnabled },
                    rows: { ["Alerts can't reach you"] },
                    reduceMotion: reduceMotion))
                    .settingsAnchor(.alerts)
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
                .settingsAnchor(.notifications)
                if notificationsAllowed == false && settings.alertsEnabled {
                    StatusBanner(severity: .critical, systemImage: "bell.slash.fill",
                                 title: "Alerts can't reach you",
                                 message: "Notifications for GlucOS are turned off in System Settings, so lows and highs won't show on this Mac.",
                                 action: BannerAction(title: "Turn On…", systemImage: "gearshape") {
                                     NSWorkspace.shared.open(AlertManager.notificationSettingsURL)
                                 },
                                 density: .compact)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .dependentRow()
                }
                AlertSoundPickerButton()
                    .disabled(!settings.alertsEnabled)
                    .settingsAnchor(.alertSound)
                LabeledContent("Check it works") {
                    TestAlertButton()
                        .disabled(notificationsAllowed != true)
                }
                .settingsAnchor(.testAlert)
            } footer: {
                Text("These supplement, never replace, the alarms on your phone.")
                    .foregroundStyle(.secondary)
            }

            Section {
                AlertRow(title: "Urgent low", detail: "Below \(u.format(mgdl: 54, withUnit: true)). Repeats every 5 minutes.",
                         tint: GlucoseRange.urgentLow.tint, isOn: nil)
                    .settingsAnchor(.lowAlerts)
                AlertRow(title: "Low", detail: "Below \(u.format(mgdl: settings.lowMgdl, withUnit: true))",
                         tint: GlucoseRange.low.tint, isOn: nil)
                AlertRow(title: "High", detail: "Above \(u.format(mgdl: settings.highMgdl, withUnit: true))",
                         tint: GlucoseRange.high.tint, isOn: $settings.alertOnHigh)
                    .settingsAnchor(.highAlert)
                AlertRow(title: "Very high", detail: "Above \(u.format(mgdl: 250, withUnit: true))",
                         tint: GlucoseRange.veryHigh.tint, isOn: nil)
            } header: {
                SettingsSectionHeader("Glucose", systemImage: "drop")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Lows and very highs always alert while glucose alerts are on.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Change Target Range…", action: openGlucoseTab)
                        .buttonStyle(.link)
                }
            }
            .settingsSection("Glucose")
            .disabled(!settings.alertsEnabled)

            Section {
                AlertRow(title: "Low predicted", detail: "When the forecast goes below \(u.format(mgdl: settings.lowMgdl, withUnit: true)), or urgent low, within the time below",
                         tint: GlucoseRange.low.tint, systemImage: "arrow.down.forward.and.arrow.up.backward",
                         isOn: $settings.alertOnPredictedLow.revealingRows(shown: { showsWarnAhead }, reduceMotion: reduceMotion))
                    .settingsAnchor(.predictedLows)
                AlertRow(title: "High predicted", detail: settings.alertOnHigh
                            ? "When the forecast goes above \(u.format(mgdl: settings.highMgdl, withUnit: true)) or very high"
                            : "When the forecast goes above \(u.format(mgdl: 250, withUnit: true)) (high alerts are off)",
                         tint: GlucoseRange.high.tint, systemImage: "arrow.up.forward",
                         isOn: $settings.alertOnPredictedHigh.revealingRows(shown: { showsWarnAhead }, reduceMotion: reduceMotion))
                    .settingsAnchor(.predictedHighs)
                Picker("Warn me up to", selection: $settings.predictiveAlertMinutes) {
                    ForEach([10, 15, 20, 30], id: \.self) { m in Text("\(m) minutes ahead").tag(m) }
                }
                .disabled(!showsWarnAhead)
                .settingsAnchor(.warnAhead)
            } header: {
                SettingsSectionHeader("Forecast", systemImage: "chart.line.uptrend.xyaxis")
            } footer: {
                Text("A heads-up from GlucOS's estimate of where glucose is heading, based on the recent trend and, once it has learnt from your logs, the insulin and carbs still acting. Forecasts can be wrong: always check your reading before acting. Only fires while glucose is falling or rising, and never replaces the alerts above.")
                    .foregroundStyle(.secondary)
            }
            .settingsSection("Forecast")
            .disabled(!settings.alertsEnabled)

            Section {
                AlertRow(title: "Rising or falling quickly", detail: "When the trend arrow points steeply up or down",
                         tint: Palette.brand, systemImage: "arrow.up.right", isOn: $settings.alertOnRapidChange)
                    .settingsAnchor(.rapidAlert)
                AlertRow(title: "No recent data", detail: "No reading for more than 6 minutes",
                         tint: Palette.stale, systemImage: "antenna.radiowaves.left.and.right.slash", isOn: $settings.alertOnStale)
                    .settingsAnchor(.staleAlert)
                AlertRow(title: "Sensor expiring", detail: "Less than 24 hours left on the sensor",
                         tint: BannerSeverity.warning.tint, systemImage: "sensor.tag.radiowaves.forward", isOn: $settings.alertOnSensorExpiry)
                    .settingsAnchor(.sensorEndingAlert)
                Picker("Repeat an ongoing alert every", selection: $settings.alertCooldownMinutes) {
                    ForEach(Self.cooldownChoices, id: \.self) { m in Text(m < 60 ? "\(m) minutes" : m == 60 ? "1 hour" : "\(LogFormat.number(Double(m) / 60)) hours").tag(m) }
                    if !Self.cooldownChoices.contains(settings.alertCooldownMinutes) {
                        Text("\(settings.alertCooldownMinutes) minutes").tag(settings.alertCooldownMinutes)
                    }
                }
                .settingsAnchor(.alertRepeat)
                AlertRepeatPreviewLine(readings: store.archive, records: logbook.alerts,
                                       prefs: settings.alertPreferences,
                                       lowMgdl: settings.lowMgdl, highMgdl: settings.highMgdl,
                                       startMinutes: openingRepeat)
            } header: {
                SettingsSectionHeader("Also Notify Me About", systemImage: "bell")
            } footer: {
                Text("Repeats apply to low, high, very high and rapid-change alerts. Urgent low always repeats every 5 minutes.")
                    .foregroundStyle(.secondary)
            }
            .settingsSection("Also Notify Me About")
            .disabled(!settings.alertsEnabled)

            Section {
                Toggle("Evening recap", isOn: $settings.eveningRecapEnabled.revealingRows(
                    shown: { settings.eveningRecapEnabled }, reduceMotion: reduceMotion))
                    .onChange(of: settings.eveningRecapEnabled) { _, on in
                        if on { store.alerts.requestAuthorization() }
                    }
                    .settingsAnchor(.eveningRecap)
                DatePicker("Time", selection: settings.eveningRecapTime, displayedComponents: .hourAndMinute)
                    .disabled(!settings.eveningRecapEnabled)
            } header: {
                SettingsSectionHeader("Daily Recap", systemImage: "moon.stars")
            } footer: {
                Text(EveningRecapText.settingsFooter(minute: settings.eveningRecapMinute) + " Click it to open Insights on today.")
                    .foregroundStyle(.secondary)
            }
            .settingsSection("Daily Recap")

            Section {
                LabeledContent("Last 7 days") {
                    Button("Alert History…") { showsHistory = true }
                }
                .settingsAnchor(.alertHistory)
            } header: {
                SettingsSectionHeader("History", systemImage: "clock.arrow.circlepath")
            } footer: {
                Text(AlertHistoryText.macFooter)
                    .foregroundStyle(.secondary)
            }
            .settingsSection("History")

            Section {
                Toggle("Sensor change reminder", isOn: $settings.sensorEndReminderEnabled)
                    .onChange(of: settings.sensorEndReminderEnabled) { _, on in
                        if on { store.alerts.requestAuthorization() }
                    }
                    .settingsAnchor(.sensorEndReminder)
            } header: {
                SettingsSectionHeader("Sensor", systemImage: "sensor.tag.radiowaves.forward")
            } footer: {
                Text(SensorEndReminder.settingsFooter)
                    .foregroundStyle(.secondary)
            }
            .settingsSection("Sensor")
        }
        .formStyle(.grouped)
        .settingsSearchPage(.alerts)
        .sheet(isPresented: $showsHistory) {
            MacAlertHistorySheet(records: logbook.alerts, readings: store.archive, unit: settings.unit,
                                 alertsOn: settings.alertsEnabled) { link in
                showsHistory = false
                // The dashboard, on the Logbook around that alert (as the "while you were away" line).
                DashboardRequest.shared.logbookLink = link
                openWindow(id: DashboardView.windowID)
                NSApp.activate()
            }
            // The rows' notes are saved to the logbook.
            .environmentObject(logbook)
        }
        // A click on the Insights Alerts card: this tab opens with Alert History up
        // (docs/InsightsAlerts.md).
        .onReceive(AlertHistoryOpenRequest.shared.$requestedAt) { _ in
            if AlertHistoryOpenRequest.shared.take() { showsHistory = true }
        }
        .task { await refreshNotificationStatus() }
        .onAppear { if openingRepeat == nil { openingRepeat = settings.alertCooldownMinutes } }
        // Pick up a change made in System Settings when the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshNotificationStatus() }
        }
    }

    /// "Warn me up to" is usable while either predicted alert is on.
    private var showsWarnAhead: Bool { settings.alertOnPredictedLow || settings.alertOnPredictedHigh }

    private func refreshNotificationStatus() async {
        notificationsAllowed = await AlertManager.notificationsAllowed()
        permissionChecked = true
        await store.checkNotificationPermission()
    }
}

/// The Mac's alert history: the last 7 days by day, a click on a row opens the dashboard's
/// Logbook around it. Esc or Done closes it.
private struct MacAlertHistorySheet: View {
    let records: [AlertRecord]
    let readings: [GlucoseReading]
    let unit: GlucoseUnit
    let alertsOn: Bool
    let open: (LogbookLink) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(AlertHistoryText.rowTitle)
                    .dsFont(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(DS.Space.md)
            Divider()
            List {
                AlertHistoryContent(records: records, readings: readings, unit: unit, alertsOn: alertsOn, open: open)
            }
            .listStyle(.inset)
            .alertHistoryAnnouncements(records: records, readings: readings, unit: unit)
            // Each row's Add note, and "Added note · Undo" (⌘Z) after one (docs/AlertNotes.md).
            .alertNoteEditor()
            .overlay(alignment: .bottom) { LogbookUndoToast() }
            Divider()
            Text(AlertHistoryText.macFooter)
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Space.md)
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 420, idealHeight: 520)
        .onExitCommand { dismiss() }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Section {
            Toggle("Sync logbook with your other devices", isOn: $sync.enabled.revealingRows(
                shown: { sync.enabled }, rows: { ["Sync status", "Sync now"] }, reduceMotion: reduceMotion))
                .settingsAnchor(.syncLogbook)
            if sync.enabled {
                Group {
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
                    if sync.isProblem {
                        SendReportButton(feature: LogbookSyncService.diagnosticFeature, step: "sync", message: sync.summary)
                            .id(sync.summary)
                    }
                }
                .dependentRow()
            }
        } header: {
            SettingsSectionHeader("Sync", systemImage: "arrow.triangle.2.circlepath")
        } footer: {
            Text("Doses, food, site changes, tags and presets are shared with GlucOS on your iPhone, signed in with the same LibreLinkUp account. Everything is kept on this Mac too and works offline; changes sync when you're back online. If an entry is edited on two devices, the later edit is kept.")
                .foregroundStyle(.secondary)
        }
        .settingsSection("Sync")
    }
}

private struct LoggingSettingsTab: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var logbook: LogbookStore

    @EnvironmentObject var store: GlucoseStore

    @State private var renaming: LogPreset?
    @State private var newName = ""
    @State private var editingBolus = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Form {
            LogbookSyncSection()
            Section {
                Picker("Therapy", selection: $settings.therapy.revealingRows(
                    shown: { settings.therapy.logsInsulin },
                    rows: { ["Your insulins", "Bolus calculator"] },
                    reduceMotion: reduceMotion)) {
                    if settings.therapy == .notSet { Text("Choose…").tag(TherapyType.notSet) }
                    ForEach([TherapyType.injections, .pump, .noInsulin]) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                }
                .settingsAnchor(.therapy)
            } header: {
                SettingsSectionHeader("How You Take Insulin", systemImage: "syringe")
            } footer: {
                Text(settings.therapy == .notSet
                     ? "Decides what GlucOS asks when you log, and which patterns it shows."
                     : settings.therapy.detail)
                    .foregroundStyle(.secondary)
            }
            .settingsSection("How You Take Insulin")

            if settings.therapy.logsInsulin {
                InsulinListSection()
                    .dependentRow()
            }

            Section {
                Toggle("Log new sensors", isOn: $settings.logSensorStarts)
                    .settingsAnchor(.sensorStartLog)
            } header: {
                SettingsSectionHeader("Sensor", systemImage: "sensor.tag.radiowaves.forward")
            } footer: {
                Text("When GlucOS first sees a new sensor, it adds \"Sensor started\" to your Logbook at the time it started. Logged once, on all your devices.")
                    .foregroundStyle(.secondary)
            }
            .settingsSection("Sensor")

            KeyboardLoggingSection()

            if settings.therapy.logsInsulin {
                Section {
                    HStack {
                        BolusSettingsSummary(settings: logbook.bolusSettings, unit: settings.unit)
                        Spacer()
                        Button(logbook.bolusSettings?.isConfirmed == true ? "Edit…" : "Set Up…") { editingBolus = true }
                    }
                    .settingsAnchor(.bolus)
                } header: {
                    SettingsSectionHeader("Bolus Calculator", systemImage: "plus.forwardslash.minus")
                } footer: {
                    Text("Uses only the settings you enter and confirm. Shared with GlucOS on your iPhone. Not medical advice.")
                        .foregroundStyle(.secondary)
                }
                .settingsSection("Bolus Calculator")
                .dependentRow()
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
                SettingsSectionHeader("Quick-Add Presets", systemImage: "star")
                    .settingsAnchor(.presets)
            } footer: {
                if !logbook.presets.isEmpty {
                    Text("Drag to reorder. Presets only repeat amounts you entered yourself.")
                        .foregroundStyle(.secondary)
                }
            }
            .settingsSection("Quick-Add Presets")

            Section {
                Text("Patterns in Dashboard → Insights are observations from your own logs and readings. They aren't medical advice and never suggest a dose. Don't change your insulin, ratios or pump settings based on them without talking to your diabetes care team.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .settingsSearchPage(.logging) { anchor in
            anchor == .insulins || anchor == .bolus ? settings.therapy.logsInsulin : true
        }
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
                .settingsAnchor(.pollInterval)
                Stepper("Sensor lifetime: \(settings.sensorLifetimeDays) days", value: $settings.sensorLifetimeDays, in: 10...15)
                    .settingsAnchor(.sensorLifetime)
                LabeledContent("Client version") {
                    HStack {
                        TextField("Client version", text: $settings.clientVersion)
                            .labelsHidden()
                            .monospacedDigit()
                            .frame(width: 90)
                        Button("Apply") { store.reconnect() }
                    }
                }
                .settingsAnchor(.clientVersion)
            } header: {
                SettingsSectionHeader("Connection", systemImage: "network")
            } footer: {
                Text("Libre sensors last 14 days (Libre 2, 3) or 15 days (Libre 2 Plus, 3 Plus). Abbott periodically raises the minimum LibreLinkUp client version; GlucOS offers to switch when that happens.")
                    .foregroundStyle(.secondary)
            }
            .settingsSection("Connection")
            Section {
                LabeledContent("Version", value: updater.version)
                    .settingsAnchor(.updates)
                LabeledContent("Highlights of recent updates") {
                    WhatsNewSettingsRow()
                }
                .settingsAnchor(.whatsNew)
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
            } header: {
                SettingsSectionHeader("Updates", systemImage: "arrow.down.circle")
            }
            .settingsSection("Updates")
            Section {
                DiagnosticsToggle()
                    .settingsAnchor(.diagnostics)
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
                .settingsAnchor(.dataFolder)
                LabeledContent("Session") {
                    Button("Reconnect") { store.reconnect() }
                }
            } header: {
                SettingsSectionHeader("Diagnostics", systemImage: "stethoscope")
            } footer: {
                Text(DiagnosticsToggle.privacyNote)
                    .foregroundStyle(.secondary)
            }
            .settingsSection("Diagnostics")
        }
        .formStyle(.grouped)
        .settingsSearchPage(.advanced)
    }
}

// MARK: - Keyboard

/// Settings → Logging → Keyboard: the optional shortcut that opens the log window from any app
/// (off by default; docs/KeyboardLogging.md).
private struct KeyboardLoggingSection: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var hotKey = GlobalLogShortcut.shared
    /// Every shortcut, and how Tab and the arrow keys move round (docs/KeyboardNavigation.md).
    @State private var showsShortcuts = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Section {
            Toggle("Open the log window from any app", isOn: $settings.globalLogShortcutEnabled.revealingRows(
                shown: { settings.globalLogShortcutEnabled && hotKey.failure != nil },
                rows: { hotKey.failure.map { [$0] } ?? [] },
                reduceMotion: reduceMotion))
                .settingsAnchor(.keyboardShortcut)
            LabeledContent("Shortcut") {
                ShortcutRecorder(key: $settings.globalLogShortcut)
            }
            .disabled(!settings.globalLogShortcutEnabled)
            if settings.globalLogShortcutEnabled, let failure = hotKey.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .dependentRow()
            }
            LabeledContent("Keyboard shortcuts") {
                Button("Show All…") { showsShortcuts = true }
            }
            .settingsAnchor(.shortcutList)
            .sheet(isPresented: $showsShortcuts) {
                ScrollView {
                    ShortcutListView(groups: ShortcutCatalog.all(
                        momentCount: LogFlow.moments(logsInsulin: settings.therapy.logsInsulin,
                                                     pump: settings.therapy == .pump).count,
                        globalKey: settings.activeGlobalLogShortcut)) { showsShortcuts = false }
                }
                .frame(width: 520, height: 560)
            }
        } header: {
            SettingsSectionHeader("Keyboard", systemImage: "keyboard")
        } footer: {
            Text("In GlucOS, ⌘L logs (during a low, it opens Log treatment) and ⌘? lists every shortcut. Tab and the arrow keys move a focus ring through the menu bar, Insights and the Logbook; Return or Space does what a click would, and Esc closes. In the log window, the arrow keys move between moments, Return picks one and moves on, and Space picks several.")
                .foregroundStyle(.secondary)
        }
        .settingsSection("Keyboard")
    }
}

/// Click, then press the new combination. Escape cancels. A combination that would take keys
/// other apps need is refused with the reason (`LogHotKey.problem`).
private struct ShortcutRecorder: View {
    @Binding var key: LogHotKey
    @State private var recording = false
    @State private var monitor: Any?
    @State private var refusal: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button { recording ? stop() : start() } label: {
                    Text(recording ? "Type a shortcut…" : key.display)
                        .font(recording ? .callout : .callout.monospaced())
                        .frame(minWidth: 110)
                }
                .accessibilityLabel(recording ? "Recording. Type a shortcut, or Escape to cancel." : "Shortcut \(key.spoken)")
                .accessibilityHint("Click to record a new shortcut")
                if key != .suggested && !recording {
                    Button("Reset") { key = .suggested; refusal = nil }
                        .buttonStyle(.borderless)
                        .help("Back to \(LogHotKey.suggested.display)")
                }
            }
            if let refusal {
                Text(refusal)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        refusal = nil
        recording = true
        // Pressing the current shortcut here should record it, not open the log window.
        GlobalLogShortcut.shared.setPaused(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local monitors are called on the main thread. Every key goes to the recorder.
            MainActor.assumeIsolated { record(event) }
            return nil
        }
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == 53 { stop(); return }   // Escape
        guard let new = LogHotKey(event: event) else {
            refusal = "Hold ⌘ or ⌃ (plus another modifier) while you press the key."
            return
        }
        if let problem = new.problem {
            refusal = problem
        } else {
            key = new
            stop()
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        GlobalLogShortcut.shared.setPaused(false)
    }
}

// MARK: - Search

private extension View {
    /// The search field above a Settings tab, its results over the tab while typing, and the
    /// scroll to a picked row once this tab is showing (docs/SettingsSearch.md). `isShown` names
    /// rows this tab can hide, so a jump lands on the switch that reveals them instead.
    func settingsSearchPage(_ tab: SettingsView.Tab, isShown: @escaping (SettingsAnchor) -> Bool = { _ in true }) -> some View {
        modifier(SettingsSearchPage(tab: tab, isShown: isShown))
    }
}

private struct SettingsSearchPage: ViewModifier {
    let tab: SettingsView.Tab
    let isShown: (SettingsAnchor) -> Bool
    @Environment(\.settingsSearch) private var search

    func body(content: Content) -> some View {
        if let search {
            content.modifier(SettingsSearchPageBody(tab: tab, isShown: isShown, search: search))
        } else {
            content
        }
    }
}

private struct SettingsSearchPageBody: ViewModifier {
    let tab: SettingsView.Tab
    let isShown: (SettingsAnchor) -> Bool
    @ObservedObject var search: SettingsSearchModel
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .overlay {
                    if search.isSearching {
                        results
                            .transition(DS.Transition.swap(reduceMotion: reduceMotion))
                    }
                }
                .dsAnimation(.quick, value: search.isSearching)
                .safeAreaInset(edge: .top, spacing: 0) { field }
                .onAppear { takeJump(proxy) }
                .onChange(of: search.pendingJump) { _, _ in takeJump(proxy) }
        }
    }

    private var found: [SettingsItem] { search.found }

    private var field: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search Settings", text: $search.query, prompt: Text("Search Settings (⌘F)"))
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .onExitCommand { search.query = "" }
                // Return goes to the best match.
                .onSubmit { if let first = found.first { pick(first) } }
            if !search.query.isEmpty {
                Button { search.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear the search")
                    .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, DS.Space.xs + 1)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DS.Space.lg)
        .padding(.top, DS.Space.sm + 2)
        .padding(.bottom, DS.Space.xs)
        .background(Color(nsColor: .windowBackgroundColor))
        // ⌘F focuses the field on whichever tab is showing.
        .background {
            Button("Search Settings") { fieldFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var results: some View {
        let items = found
        return Form {
            Section {
                if items.isEmpty {
                    SettingsSearchEmptyView(query: search.query)
                } else {
                    ForEach(items) { item in
                        SettingsSearchResultRow(item: item, query: search.query) { pick(item) }
                            .settingsResultEntrance(item.anchor, search: search)
                    }
                }
            } header: {
                if !items.isEmpty { Text(SettingsSearch.countLabel(items.count)) }
            }
        }
        .formStyle(.grouped)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Clear the search and send the jump; `SettingsView` switches tab if it's elsewhere.
    private func pick(_ item: SettingsItem) {
        search.query = ""
        fieldFocused = false
        search.pendingJump = item
    }

    /// A jump for this tab: scroll to the row (or the switch that reveals it) and light it.
    private func takeJump(_ proxy: ScrollViewProxy) {
        guard let item = search.pendingJump, item.tab == tab.rawValue else { return }
        search.pendingJump = nil
        let target = SettingsSearch.target(for: item, in: SettingsCatalog.mac, isShown: isShown)
        search.jump(to: target, proxy: proxy, reduceMotion: reduceMotion)
    }
}
