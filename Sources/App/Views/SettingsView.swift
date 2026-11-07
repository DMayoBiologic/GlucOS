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
            displayTab.tabItem { Label("Display", systemImage: "gauge") }
            alertsTab.tabItem { Label("Alerts", systemImage: "bell") }
            advancedTab.tabItem { Label("Advanced", systemImage: "wrench") }
        }
        .frame(width: 440)
        .padding()
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
                Text("LibreLinkUp follower account")
            } footer: {
                Text("Use the *follower* account you created to accept the invitation from LibreLink — not your LibreLink login. Credentials are stored in the macOS Keychain and only ever sent to Abbott.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button("Save & Connect") {
                    settings.password = password
                    store.reconnect()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(settings.email.isEmpty || password.isEmpty)
                Spacer()
                Text(store.statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let err = store.snapshot.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Display

    private var displayTab: some View {
        Form {
            Picker("Units", selection: $settings.unit) {
                ForEach(GlucoseUnit.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            // Keep at least 1 mmol/L (18 mg/dL) between the thresholds so the target band is real.
            thresholdField("Low threshold", mgdl: $settings.lowMgdl,
                           allowed: 54...max(54, min(150, settings.highMgdl - 18)))
            thresholdField("High threshold", mgdl: $settings.highMgdl,
                           allowed: min(400, max(120, settings.lowMgdl + 18))...400)

            Toggle("Show change since last reading in menu bar", isOn: $settings.showDeltaInMenuBar)

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
            if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }

            Section {
                Text("Add the widget: right-click the desktop → Edit Widgets → search “GlucOS”. Widgets refresh each time the app fetches new data.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func thresholdField(_ label: String, mgdl: Binding<Double>, allowed: ClosedRange<Double>) -> some View {
        let unit = settings.unit
        let display = Binding<Double>(
            get: { unit.value(fromMgdl: mgdl.wrappedValue) },
            set: { mgdl.wrappedValue = min(max(unit.mgdl(fromDisplay: $0), allowed.lowerBound), allowed.upperBound) }
        )
        return HStack {
            Text(label)
            Spacer()
            TextField("", value: display, format: .number.precision(.fractionLength(unit == .mmol ? 1 : 0)))
                .frame(width: 70)
                .multilineTextAlignment(.trailing)
            Text(unit.label).foregroundStyle(.secondary)
        }
    }

    // MARK: Alerts

    private var alertsTab: some View {
        Form {
            Toggle("Enable notifications", isOn: $settings.alertsEnabled)
            Group {
                Toggle("Rising / falling quickly", isOn: $settings.alertOnRapidChange)
                Toggle("No data for more than 6 minutes", isOn: $settings.alertOnStale)
                Toggle("Sensor expiring within 24 h", isOn: $settings.alertOnSensorExpiry)
                Stepper("Repeat alerts after \(settings.alertCooldownMinutes) min", value: $settings.alertCooldownMinutes, in: 5...120, step: 5)
            }
            .disabled(!settings.alertsEnabled)
            Section {
                Text("Low/high alerts use the thresholds on the Display tab. Urgent-low (< 3.0 mmol/L) repeats every 5 minutes regardless. These supplement — never replace — the alarms on your phone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Advanced

    private var advancedTab: some View {
        Form {
            Stepper("Poll every \(settings.pollIntervalSeconds) s", value: $settings.pollIntervalSeconds, in: 30...300, step: 30)
            Stepper("Sensor lifetime \(settings.sensorLifetimeDays) days", value: $settings.sensorLifetimeDays, in: 10...15)
            TextField("Client version header", text: $settings.clientVersion)
            Section {
                Text("Abbott periodically raises the minimum LibreLinkUp client version. GlucOS adopts the version Abbott asks for automatically; edit this only if that fails.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Version", value: updater.version)
                HStack {
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheck)
                    if !updater.isConfigured {
                        Text("Updates not configured in this build (no Sparkle public key).")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("Checks every 6 h and installs automatically on relaunch.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                LabeledContent("Snapshot", value: SharedStore.snapshotURL?.path ?? "unavailable")
                    .textSelection(.enabled)
                Button("Reconnect") { store.reconnect() }
            }
        }
        .formStyle(.grouped)
    }
}
