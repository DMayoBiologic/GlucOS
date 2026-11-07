import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var updater: Updater

    @State private var password: String = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var notificationsAllowed: Bool?
    @State private var permissionChecked = false

    var body: some View {
        TabView {
            accountTab.tabItem { Label("Account", systemImage: "person.crop.circle") }
            displayTab.tabItem { Label("Display", systemImage: "chart.xyaxis.line") }
            alertsTab.tabItem { Label("Alerts", systemImage: "bell.badge") }
            insulinTab.tabItem { Label("Insulin", systemImage: "syringe") }
            advancedTab.tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(width: 480)
        .onAppear { password = settings.password }
    }

    // MARK: Account

    private var accountTab: some View {
        Form {
            Section {
                TextField("LibreLinkUp email", text: $settings.email)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Picker("Region", selection: $settings.region) {
                    Text("Australia (api-au)").tag("au")
                    Text("Europe (api-eu)").tag("eu")
                    Text("Europe 2 (api-eu2)").tag("eu2")
                    Text("US (api-us)").tag("us")
                    Text("Asia-Pacific (api-ap)").tag("ap")
                    Text("Canada (api-ca)").tag("ca")
                    Text("Japan (api-jp)").tag("jp")
                    Text("Auto-detect (global)").tag("global")
                }
            } header: {
                Text("LibreLinkUp Follower Account")
            } footer: {
                Text("Use the *follower* account you created to accept the invitation from LibreLink, not your LibreLink login. Credentials are stored in the macOS Keychain and only ever sent to Abbott.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        if store.isRefreshing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Circle().fill(connectionColor).frame(width: 8, height: 8)
                        }
                        Text(store.statusLine).lineLimit(2).multilineTextAlignment(.trailing)
                    }
                    .foregroundStyle(.secondary)
                }
                if let err = store.snapshot.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("Save & Connect") {
                        settings.password = password
                        store.reconnect()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(settings.email.isEmpty || password.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var connectionColor: Color {
        if store.snapshot.lastError != nil { return .orange }
        if !settings.hasCredentials { return .secondary }
        return store.snapshot.current == nil || store.snapshot.isStale() ? .yellow : .green
    }

    // MARK: Display

    private var displayTab: some View {
        Form {
            Section("Units") {
                Picker("Glucose units", selection: $settings.unit) {
                    ForEach(GlucoseUnit.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                thresholdField("Low", mgdl: $settings.lowMgdl)
                thresholdField("High", mgdl: $settings.highMgdl)
            } header: {
                Text("Target Range")
            } footer: {
                if settings.lowMgdl >= settings.highMgdl {
                    Label("Low must be below high.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Text("Readings between \(settings.unit.format(mgdl: settings.lowMgdl)) and \(settings.unit.format(mgdl: settings.highMgdl, withUnit: true)) count as in range.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Show change since last reading", isOn: $settings.showDeltaInMenuBar)
                Toggle("Colour-code the menu bar icon", isOn: $settings.colorMenuBarIcon)
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("Tints the drop green, orange or red by range. Stale data always shows a plain warning sign instead.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError { Text(loginError).font(.callout).foregroundStyle(.red) }
            } header: {
                Text("General")
            } footer: {
                Text("Add the widget: right-click the desktop → Edit Widgets → search “GlucOS”. Widgets refresh each time the app fetches new data.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func thresholdField(_ label: String, mgdl: Binding<Double>) -> some View {
        let unit = settings.unit
        let display = Binding<Double>(
            get: { unit.value(fromMgdl: mgdl.wrappedValue) },
            set: { mgdl.wrappedValue = unit.mgdl(fromDisplay: $0) }
        )
        return LabeledContent(label) {
            HStack(spacing: 6) {
                TextField(label, value: display, format: .number.precision(.fractionLength(unit == .mmol ? 1 : 0)))
                    .labelsHidden()
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                Text(unit.label).foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)
            }
        }
    }

    // MARK: Alerts

    private var alertsTab: some View {
        Form {
            Section {
                Toggle("Enable notifications", isOn: $settings.alertsEnabled)
                LabeledContent("macOS permission") {
                    HStack(spacing: 6) {
                        switch notificationsAllowed {
                        case .some(true):
                            Label("Allowed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .some(false):
                            Label("Off", systemImage: "bell.slash.fill")
                                .foregroundStyle(.red)
                            Button("Open Notification Settings…") {
                                NSWorkspace.shared.open(AlertManager.notificationSettingsURL)
                            }
                        case .none where permissionChecked:
                            Text("Not asked yet").foregroundStyle(.secondary)
                        case .none:
                            ProgressView().controlSize(.mini)
                        }
                    }
                }
                LabeledContent("Test") {
                    Button("Send Test Alert") { store.alerts.sendTest() }
                        .disabled(notificationsAllowed != true)
                }
            }
            Section {
                Toggle("Rising or falling quickly", isOn: $settings.alertOnRapidChange)
                Toggle("No data for more than 6 minutes", isOn: $settings.alertOnStale)
                Toggle("Sensor expiring within 24 hours", isOn: $settings.alertOnSensorExpiry)
                Stepper("Repeat after \(settings.alertCooldownMinutes) min", value: $settings.alertCooldownMinutes, in: 5...120, step: 5)
            } header: {
                Text("Also Notify Me About")
            } footer: {
                Text("Low and high alerts use your target range on the Display tab. Urgent low (below 3.0 mmol/L) repeats every 5 minutes regardless. These supplement, never replace, the alarms on your phone.")
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

    // MARK: Insulin

    private var insulinTab: some View {
        Form {
            Section {
                Picker("Therapy", selection: $settings.therapy) {
                    if settings.therapy == .notSet { Text("Choose…").tag(TherapyType.notSet) }
                    ForEach([TherapyType.injections, .pump, .noInsulin]) { Text($0.title).tag($0) }
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
                } header: {
                    Text(settings.therapy == .pump ? "Insulin in Your Pump" : "Mealtime Insulin")
                } footer: {
                    Text("Pre-filled when you log a dose.").foregroundStyle(.secondary)
                }
            }
            if settings.therapy == .injections {
                Section("Long-Acting Insulin") {
                    TextField("Name", text: $settings.basalInsulinName, prompt: Text(InsulinKind.long.examples))
                }
            }

            Section {
                Text("Patterns in Dashboard → Insights are observations from your own logs and readings. They aren't medical advice and GlucOS never suggests a dose. Don't change your insulin, ratios or pump settings based on them without talking to your diabetes care team.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Advanced

    private var advancedTab: some View {
        Form {
            Section {
                Stepper("Poll every \(settings.pollIntervalSeconds) s", value: $settings.pollIntervalSeconds, in: 30...300, step: 30)
                Stepper("Sensor lifetime \(settings.sensorLifetimeDays) days", value: $settings.sensorLifetimeDays, in: 10...15)
                TextField("Client version header", text: $settings.clientVersion)
                    .monospacedDigit()
            } header: {
                Text("Connection")
            } footer: {
                Text("Abbott periodically raises the minimum LibreLinkUp client version. If you see a “requires version” error, set this to the number in the error and reconnect.")
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
                            .foregroundStyle(.orange)
                    } else {
                        Text("Checks hourly; installs and relaunches automatically.")
                    }
                }
            }
            Section("Diagnostics") {
                LabeledContent("Snapshot") {
                    Text(SharedStore.snapshotURL?.path ?? "unavailable")
                        .font(.callout.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                LabeledContent("Session") {
                    Button("Reconnect") { store.reconnect() }
                }
            }
        }
        .formStyle(.grouped)
    }
}
