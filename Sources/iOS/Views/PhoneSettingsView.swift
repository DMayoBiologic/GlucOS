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

// MARK: - Alert history

/// Settings › Alerts › History: the last 7 days of low and high alerts by day. A row closes
/// Settings and opens the Logbook around it (`AlertHistoryRoute`); its pencil adds a note. Also
/// pushed on the home stack from the Insights Alerts card (`PhoneRoute.alertHistory`), where a row
/// pushes the Logbook on top instead (`open`).
struct PhoneAlertHistoryScreen: View {
    /// Where a row's Logbook goes; nil inside Settings, which closes first.
    var open: ((LogbookLink) -> Void)? = nil

    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var logbook: LogbookStore

    var body: some View {
        List {
            AlertHistoryContent(records: logbook.alerts, readings: store.archive, unit: settings.unit,
                                alertsOn: settings.alertsEnabled) { link in
                if let open { open(link) } else { AlertHistoryRoute.shared.open(link) }
            }
            Section {} footer: { Text(AlertHistoryText.footer) }
        }
        .alertHistoryAnnouncements(records: logbook.alerts, readings: store.archive, unit: settings.unit)
        // Each row's Add note, and "Added note · Undo" after one (docs/AlertNotes.md).
        .alertNoteEditor()
        .overlay(alignment: .bottom) { PhoneUndoToast() }
        .navigationTitle(AlertHistoryText.rowTitle)
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
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    private var canSignIn: Bool {
        !working && !email.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

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
                    .focused($focus, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { if canSignIn { signIn() } }
                Picker("Region", selection: $region) {
                    ForEach(LibreRegion.all) { Text($0.name).tag($0.id) }
                }
            }
            if let problem {
                Section { ConnectionProblemView(problem: problem, compact: true) { store.apply($0) } }
            }
            Section {
                Button(action: signIn) {
                    HStack {
                        Text(working ? "Signing In…" : "Sign In")
                        Spacer()
                        if working { ProgressView() }
                    }
                }
                .disabled(!canSignIn)
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
        .dsAnimation(.standard, value: problem)
        .onAppear {
            email = settings.email
            region = settings.region
            focus = email.isEmpty ? .email : .password
        }
    }

    private func signIn() {
        guard canSignIn else { return }
        focus = nil
        working = true
        problem = nil
        // Before the result: if the account is saved but the first fetch fails, home still
        // appears, and the setup should come with it. It only shows once home does.
        PhoneSetupView.markPendingIfNew()
        Task {
            problem = await store.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password, region: region)
            working = false
            if problem == nil {
                Haptics.play(.done)
                UserDefaults.standard.set(PhoneMode.sensor.rawValue, forKey: "phoneMode")
                if onFollowInstead == nil { dismiss() }
            }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(IslandSparkline.defaultsKey, store: SharedStore.defaults) private var islandSparkline = IslandSparkline.defaultOn
    @State private var notificationsAllowed: Bool?
    @State private var relaySecret = ""
    @State private var confirmsSignOut = false
    @StateObject private var search = SettingsSearchModel(catalog: SettingsCatalog.phone)
    @State private var searching = false
    /// Opens scrolled to this section (a banner's Set Up button lands on the relay, not the top).
    var scrollTo: Jump?

    /// `alertHistory` scrolls to Alerts and then opens Alert History (the Insights Alerts card).
    enum Jump: Hashable { case alerts, relay, alertHistory }
    @State private var opensAlertHistory = false
    /// The alert repeat when Settings opened, for the repeat preview's "was". Held here, not in the
    /// line, so turning alerts off and on or searching Settings never resets it.
    @State private var openingRepeat: Int?

    var body: some View {
        ScrollViewReader { proxy in
            form(proxy)
                .task {
                    guard let scrollTo else { return }
                    // After the sheet has finished arriving, or the scroll is lost.
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    let section = scrollTo == .alertHistory ? Jump.alerts : scrollTo
                    DS.animate(.standard, reduceMotion: reduceMotion) { proxy.scrollTo(section, anchor: .top) }
                    if scrollTo == .alertHistory { opensAlertHistory = true }
                }
                .navigationDestination(isPresented: $opensAlertHistory) { PhoneAlertHistoryScreen() }
        }
        .confirmationDialog("Sign out of LibreLinkUp?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { store.signOut() }
        } message: {
            Text("Readings, alerts and the Lock Screen card stop on this iPhone until you sign in again. Your logbook stays.")
        }
    }

    private func form(_ proxy: ScrollViewProxy) -> some View {
        Form {
            if search.isSearching {
                searchResults(proxy)
            } else {
                allSections
            }
        }
        .environment(\.settingsSearch, search)
        // Search (docs/SettingsSearch.md): titles and the words people use for them.
        .searchable(text: $search.query, isPresented: $searching,
                    placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search Settings")
        // Return goes to the best match.
        .onSubmit(of: .search) {
            if let first = search.found.first { open(first, proxy: proxy) }
        }
        // Rows a toggle reveals or hides slide in and out with the toggle, instead of popping.
        .dsAnimation(.standard, value: settings.alertsEnabled)
        .dsAnimation(.standard, value: settings.alertOnPredictedLow || settings.alertOnPredictedHigh)
        .dsAnimation(.standard, value: services.liveActivityEnabled)
        .dsAnimation(.standard, value: logbookSync.enabled)
        .dsAnimation(.standard, value: logbookSync.isProblem)
        .dsAnimation(.standard, value: settings.therapy.logsInsulin)
        .dsAnimation(.standard, value: relay.isConfigured)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .onAppear { if openingRepeat == nil { openingRepeat = settings.alertCooldownMinutes } }
        .task {
            relaySecret = relay.secret
            notificationsAllowed = await AlertManager.notificationsAllowed()
            await services.refreshRelayStatus()
        }
    }

    @ViewBuilder private var allSections: some View {
        Group {
            accountSection
            displaySection
            loggingSection
            if !logbook.presets.isEmpty { presetsSection }
            syncSection
            alertsSection
            recapSection
            sensorReminderSection
            lockScreenSection
            sharingSection
            FollowingSettingsSection()
            relaySection
            DiagnosticsSettingsSection()
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                    .settingsAnchor(.version)
                WhatsNewSettingsRow()
                    .settingsAnchor(.whatsNew)
                Text("Personal use. Not a medical device. Confirm readings and alerts with your sensor app before acting.")
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What a search found, or a plain "nothing matches".
    @ViewBuilder private func searchResults(_ proxy: ScrollViewProxy) -> some View {
        let found = search.found
        Section {
            if found.isEmpty {
                SettingsSearchEmptyView(query: search.query)
            } else {
                ForEach(found) { item in
                    SettingsSearchResultRow(item: item, query: search.query) { open(item, proxy: proxy) }
                        .settingsResultEntrance(item.anchor, search: search)
                }
            }
        } header: {
            if !found.isEmpty { Text(SettingsSearch.countLabel(found.count)) }
        }
    }

    /// Close the search, then scroll to the row (or the switch that reveals it) and light it.
    private func open(_ item: SettingsItem, proxy: ScrollViewProxy) {
        let target = SettingsSearch.target(for: item, in: SettingsCatalog.phone, isShown: isShown)
        Haptics.play(.choice)
        searching = false
        search.query = ""
        search.jump(to: target, proxy: proxy, reduceMotion: reduceMotion)
    }

    /// Rows that only appear once something else is turned on.
    private func isShown(_ anchor: SettingsAnchor) -> Bool {
        switch anchor {
        case .insulins, .bolus: return settings.therapy.logsInsulin
        case .presets: return !logbook.presets.isEmpty
        case .highAlert, .rapidAlert, .staleAlert, .sensorEndingAlert, .predictedLows, .predictedHighs, .alertRepeat, .alertSound, .testAlert:
            return settings.alertsEnabled
        case .warnAhead:
            return settings.alertsEnabled && (settings.alertOnPredictedLow || settings.alertOnPredictedHigh)
        case .islandSparkline: return services.liveActivityEnabled
        default: return true
        }
    }

    // MARK: Sections

    private var accountSection: some View {
        Section {
            LabeledContent("Account", value: settings.email)
                .settingsAnchor(.account)
            LabeledContent("Region", value: LibreRegion.all.first { $0.id == settings.region }?.name ?? settings.region)
            LabeledContent("Status", value: store.statusLine)
            Button("Sign Out…", role: .destructive) { confirmsSignOut = true }
            NavigationLink("Read sensor") { SensorScanView() }
                .settingsAnchor(.readSensor)
        } header: {
            SettingsSectionHeader("LibreLinkUp", systemImage: "person.crop.circle")
        }
        .settingsSection("LibreLinkUp")
    }

    private var displaySection: some View {
        Section {
            Picker("Units", selection: $settings.unit) {
                ForEach(GlucoseUnit.allCases) { Text($0.label).tag($0) }
            }
            .settingsAnchor(.units)
            TargetRangeEditor(settings: settings, readingMgdl: freshMgdl, previewReadings: store.archive,
                              alertRecords: logbook.alerts)
                .padding(.vertical, DS.Space.xs)
                .settingsAnchor(.targetRange)
            Toggle("Show forecast on the chart", isOn: $settings.showForecast)
                .settingsAnchor(.showForecast)
            Toggle("Show yesterday on the chart", isOn: $settings.showYesterdayLine)
                .settingsAnchor(.showYesterday)
        } header: {
            SettingsSectionHeader("Display", systemImage: "chart.xyaxis.line")
        } footer: {
            Text("The target range colours every reading, chart and alert, here and on the Lock Screen. Yesterday shows as a faint grey line at the same time of day; touch and hold the chart to turn it on or off.")
        }
        .settingsSection("Display")
    }

    private var loggingSection: some View {
        Section {
            Picker("Insulin", selection: $settings.therapy.revealingRows(
                shown: { settings.therapy.logsInsulin },
                rows: { ["Your insulins", "Bolus calculator"] },
                reduceMotion: reduceMotion)) {
                ForEach(TherapyType.allCases) { Text($0.title).tag($0) }
            }
            .settingsAnchor(.therapy)
            if settings.therapy.logsInsulin {
                Group {
                    // The two modifiers below carry into the screen: brand names, not words to correct.
                    NavigationLink {
                        PhoneInsulinsScreen()
                    } label: {
                        LabeledContent("Your insulins",
                                       value: logbook.insulins.isEmpty ? "Add" : logbook.insulins.map(\.name).joined(separator: ", "))
                    }
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .settingsAnchor(.insulins)
                    NavigationLink {
                        PhoneBolusSettingsScreen()
                    } label: {
                        BolusSettingsSummary(settings: logbook.bolusSettings, unit: settings.unit)
                    }
                    .settingsAnchor(.bolus)
                }
                .dependentRow()
            }
            Toggle("Log new sensors", isOn: $settings.logSensorStarts)
                .settingsAnchor(.sensorStartLog)
        } header: {
            SettingsSectionHeader("Logging", systemImage: "square.and.pencil")
        } footer: {
            Text(loggingFooter)
        }
        .settingsSection("Logging")
    }

    private var loggingFooter: String {
        let intro: String
        if settings.therapy == .notSet {
            intro = "Tap Log on the main screen to record insulin, food and events. GlucOS asks how you take insulin the first time."
        } else {
            intro = "\(settings.therapy.detail) GlucOS records what you enter; only the bolus calculator suggests a dose, from settings you confirm. Say \"Log in GlucOS\" to Siri, or add the Log widget to your Lock Screen, to log in one step."
        }
        let sensors = "With Log new sensors on, a new sensor adds \"Sensor started\" to your Logbook at the time it started."
        return intro + " " + sensors
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
            SettingsSectionHeader("Presets", systemImage: "star") {
                Spacer()
                EditButton().textCase(nil)
            }
            .settingsAnchor(.presets)
        } footer: {
            Text("One-tap quick adds in the log sheet. Save one by turning on Save as preset when you log.")
        }
        .settingsSection("Presets")
    }

    private var syncSection: some View {
        Section {
            Toggle("Sync logbook", isOn: $logbookSync.enabled.revealingRows(
                shown: { logbookSync.enabled },
                rows: { ["Sync status", "Sync now"] },
                reduceMotion: reduceMotion))
                .settingsAnchor(.syncLogbook)
            if logbookSync.enabled {
                Group {
                    LabeledContent("Status") {
                        Text(logbookSync.summary)
                            .foregroundStyle(logbookSync.isProblem ? Tone.warning.textColor : Color.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    Button("Sync Now") { logbookSync.requestSync() }
                        .disabled(logbookSync.status == .syncing || logbookSync.status == .needsAccount)
                    if logbookSync.isProblem {
                        SendReportButton(feature: LogbookSyncService.diagnosticFeature, step: "sync", message: logbookSync.summary)
                            .id(logbookSync.summary)
                    }
                }
                .dependentRow()
            }
        } header: {
            SettingsSectionHeader("Logbook", systemImage: "arrow.triangle.2.circlepath")
        } footer: {
            Text("Doses, food, site changes and events logged here or in GlucOS on your Mac, shared through the GlucOS sync server with the same LibreLinkUp account. The forecast and insulin on board here count them.")
        }
        .settingsSection("Logbook")
    }

    private var alertsSection: some View {
        Section {
            Toggle("Glucose alerts", isOn: $settings.alertsEnabled.revealingRows(
                shown: { settings.alertsEnabled },
                rows: { alertOptionNames },
                reduceMotion: reduceMotion))
                .settingsAnchor(.alerts)
                .onChange(of: settings.alertsEnabled) { _, on in
                    // Turning alerts on is the moment to ask, if iOS hasn't asked yet.
                    guard on else { return }
                    store.alerts.requestAuthorization()
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        notificationsAllowed = await AlertManager.notificationsAllowed()
                    }
                }
            if settings.alertsEnabled {
                Group {
                    if notificationsAllowed == false {
                        Button("Notifications are off. Turn them on in Settings") { openURL(AlertManager.notificationSettingsURL) }
                            .foregroundStyle(Tone.critical.textColor)
                    }
                    Toggle("High (above target)", isOn: $settings.alertOnHigh)
                        .settingsAnchor(.highAlert)
                    Toggle("Rising or falling quickly", isOn: $settings.alertOnRapidChange)
                        .settingsAnchor(.rapidAlert)
                    Toggle("No recent data", isOn: $settings.alertOnStale)
                        .settingsAnchor(.staleAlert)
                    Toggle("Sensor ending", isOn: $settings.alertOnSensorExpiry)
                        .settingsAnchor(.sensorEndingAlert)
                    Toggle("Predicted lows", isOn: $settings.alertOnPredictedLow.revealingRows(
                        shown: { showsWarnAhead }, rows: { ["Warn me ahead by"] }, reduceMotion: reduceMotion))
                        .settingsAnchor(.predictedLows)
                    Toggle("Predicted highs", isOn: $settings.alertOnPredictedHigh.revealingRows(
                        shown: { showsWarnAhead }, rows: { ["Warn me ahead by"] }, reduceMotion: reduceMotion))
                        .settingsAnchor(.predictedHighs)
                    if showsWarnAhead {
                        Picker("Warn me ahead by", selection: $settings.predictiveAlertMinutes) {
                            ForEach([10, 15, 20, 30], id: \.self) { Text("\($0) min").tag($0) }
                        }
                        .settingsAnchor(.warnAhead)
                        .dependentRow()
                    }
                    Picker("Repeat no more than every", selection: $settings.alertCooldownMinutes) {
                        ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .settingsAnchor(.alertRepeat)
                    AlertRepeatPreviewLine(readings: store.archive, records: logbook.alerts,
                                           prefs: settings.alertPreferences,
                                           lowMgdl: settings.lowMgdl, highMgdl: settings.highMgdl,
                                           startMinutes: openingRepeat)
                    AlertSoundPickerLink()
                        .settingsAnchor(.alertSound)
                    TestAlertButton(requestsAuthorization: true)
                        .settingsAnchor(.testAlert)
                }
                .dependentRow()
            }
            // Shown with alerts off too: what went off before still matters (docs/AlertHistory.md).
            NavigationLink {
                PhoneAlertHistoryScreen()
            } label: {
                Label(AlertHistoryText.rowTitle, systemImage: "clock.arrow.circlepath")
            }
            .settingsAnchor(.alertHistory)
        } header: {
            SettingsSectionHeader("Alerts", systemImage: "bell.badge")
        } footer: {
            Text("Lows and very highs always alert while alerts are on; urgent lows repeat every 5 minutes. \(services.relayStatus?.isDeliveringAlerts() == true ? "Your push relay is sending these, so they arrive even when GlucOS is closed." : "Without the push relay, alerts can only come while GlucOS is open or briefly refreshing in the background.")")
        }
        .settingsSection("Alerts")
        .id(Jump.alerts)
    }

    /// "Warn me ahead by" shows while either predicted alert is on.
    private var showsWarnAhead: Bool { settings.alertOnPredictedLow || settings.alertOnPredictedHigh }

    /// The rows under Glucose alerts, in screen order, for VoiceOver when they appear.
    private var alertOptionNames: [String] {
        var names = ["High", "Rising or falling quickly", "No recent data", "Sensor ending", "Predicted lows", "Predicted highs"]
        if showsWarnAhead { names.append("Warn me ahead by") }
        names += ["Repeat no more than every", AlertSound.pickerTitle, "Send a test alert"]
        return names
    }

    /// The evening recap (docs/EveningRecap.md): one notification a day, off until turned on.
    private var recapSection: some View {
        Section {
            Toggle("Evening recap", isOn: $settings.eveningRecapEnabled.revealingRows(
                shown: { settings.eveningRecapEnabled }, rows: { ["Recap time"] }, reduceMotion: reduceMotion))
                .onChange(of: settings.eveningRecapEnabled) { _, on in
                    if on { store.alerts.requestAuthorization() }
                }
                .settingsAnchor(.eveningRecap)
            if settings.eveningRecapEnabled {
                DatePicker("Time", selection: settings.eveningRecapTime, displayedComponents: .hourAndMinute)
                    .dependentRow()
            }
        } header: {
            SettingsSectionHeader("Daily recap", systemImage: "moon.stars")
        } footer: {
            Text(EveningRecapText.settingsFooter(minute: settings.eveningRecapMinute) + " Tap it to open Insights on today. It uses the readings GlucOS had when it last refreshed, and says which hours it covers.")
        }
        .settingsSection("Daily recap")
    }

    /// The evening-before sensor reminder (docs/SensorEnd.md): off until turned on.
    private var sensorReminderSection: some View {
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
        }
        .settingsSection("Sensor")
    }

    private var lockScreenSection: some View {
        Section {
            Toggle("Live Activity", isOn: $services.liveActivityEnabled.revealingRows(
                shown: { services.liveActivityEnabled },
                rows: { services.liveActivity.systemEnabled ? ["Live Activity status", "Show the last hour in the island"] : ["Live Activity status", "Allow Live Activities in Settings", "Show the last hour in the island"] },
                reduceMotion: reduceMotion))
                .settingsAnchor(.liveActivity)
            if services.liveActivityEnabled {
                Group {
                    LabeledContent("Status", value: liveActivityStatus)
                    if !services.liveActivity.systemEnabled {
                        Button("Allow Live Activities in Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                    Toggle("Show the last hour in the island", isOn: $islandSparkline)
                        .settingsAnchor(.islandSparkline)
                        .onChange(of: islandSparkline) {
                            Task { await services.liveActivity.redraw() }
                        }
                }
                .dependentRow()
            }
        } header: {
            SettingsSectionHeader("Lock Screen", systemImage: "lock")
        } footer: {
            Text("Your reading, trend, the last 3 hours and the forecast on the Lock Screen and in the Dynamic Island. With the last hour on, a small line sits beside the trend arrow in the compact Dynamic Island, in place of the change since the last reading. iOS ends a Live Activity after 8 hours; the push relay starts a fresh one automatically. Without the relay it only updates while GlucOS is open.")
        }
        .settingsSection("Lock Screen")
    }

    private var sharingSection: some View {
        Section {
            NavigationLink {
                PhoneSharingView(showsDone: false)
            } label: {
                Label("Share Live Readings", systemImage: "person.2.wave.2")
            }
            .settingsAnchor(.shareLive)
        } header: {
            SettingsSectionHeader("Sharing", systemImage: "person.2")
        } footer: {
            Text("Send family a link in Messages that shows your glucose live, and on their Lock Screen if they have GlucOS.")
        }
        .settingsSection("Sharing")
    }

    /// The latest reading while it's fresh, for the range editor's marker.
    private var freshMgdl: Double? {
        let s = store.snapshot
        guard let cur = s.current, !s.isStale() else { return nil }
        return cur.mgdl
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
                .settingsAnchor(.relay)
            SecureField("Relay secret", text: $relaySecret)
                .onSubmit { relay.secret = relaySecret }
                .onChange(of: relaySecret) { _, new in relay.secret = new }
            if relay.isConfigured {
                if let e = services.relayError {
                    Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning.textColor)
                    SendReportButton(feature: PhoneServices.relayDiagnosticFeature, step: "relay", message: e).id(e)
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
            SettingsSectionHeader("Push relay", systemImage: "antenna.radiowaves.left.and.right")
        } footer: {
            Text("A small server of your own that checks LibreLinkUp every minute and pushes alerts and Lock Screen updates to this iPhone while it's locked. It receives your LibreLinkUp login so it can fetch for you. Signed in with the same LibreLinkUp account as the relay, this iPhone connects by itself.")
        }
        .settingsSection("Push relay")
        .id(Jump.relay)
    }
}

/// Settings › Diagnostics: automatic error reports on or off. Also in follower mode's settings.
struct DiagnosticsSettingsSection: View {
    var body: some View {
        Section {
            DiagnosticsToggle()
                .settingsAnchor(.diagnostics)
        } header: {
            SettingsSectionHeader("Diagnostics", systemImage: "stethoscope")
        } footer: {
            Text(DiagnosticsToggle.privacyNote)
        }
        .settingsSection("Diagnostics")
    }
}
