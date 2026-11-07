import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var updater: Updater

    @State private var password: String = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        TabView {
            accountTab.tabItem { Label("Account", systemImage: "person.crop.circle") }
            displayTab.tabItem { Label("Display", systemImage: "chart.xyaxis.line") }
            alertsTab.tabItem { Label("Alerts", systemImage: "bell.badge") }
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

            Section("Menu Bar") {
                Toggle("Show change since last reading", isOn: $settings.showDeltaInMenuBar)
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
                        Text("Checks every 6 hours and installs on relaunch.")
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
