import SwiftUI

/// Settings › Live from sensor: take the sensor's Bluetooth stream over from LibreLink, after
/// saying plainly what stops working, and later hand it back.
struct DirectSensorView: View {
    @EnvironmentObject var direct: DirectSensorService
    @EnvironmentObject var settings: AppSettings
    @Environment(\.openURL) private var openURL
    @State private var scanner = SensorScanner()
    @State private var understood = false
    @State private var working = false
    @State private var error: String?
    @State private var handedBack = false
    @State private var confirmStop = false
    @State private var notificationsAllowed: Bool?

    var body: some View {
        Form {
            if let sensor = direct.sensor {
                liveSections(sensor)
            } else {
                if handedBack {
                    Section {
                        Text("GlucOS has stopped listening. Open LibreLink and scan your sensor to get its readings, alarms and LinkUp sharing back. Until you do, nothing is alerting you.")
                            .foregroundStyle(.orange)
                    }
                }
                setupSections
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Live from Sensor")
        .navigationBarTitleDisplayMode(.inline)
        .task { notificationsAllowed = await AlertManager.notificationsAllowed() }
        .confirmationDialog("Stop reading the sensor?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop", role: .destructive) {
                direct.stop()
                handedBack = true
            }
        } message: {
            Text("GlucOS stops getting readings and stops alerting. Scan the sensor with LibreLink straight after to get its alarms back.")
        }
    }

    // MARK: Before

    private var canConnect: Bool {
        understood && settings.alertsEnabled && notificationsAllowed != false && SensorScanner.isAvailable && !working
    }

    @ViewBuilder private var setupSections: some View {
        Section {
            point("antenna.radiowaves.left.and.right", "GlucOS gets a reading from your sensor every minute over Bluetooth, decoded on your phone. It doesn't need LinkUp or the internet.")
            point("bell.slash", "LibreLink stops getting readings. Its alarms stop, and so does LinkUp sharing, including anyone following you in LibreLinkUp.")
            point("bell.badge", "GlucOS's own alerts take over, plus an alert if the sensor goes quiet for 20 minutes. People following you in GlucOS keep seeing your readings.")
            point("laptopcomputer", "The Mac app reads LinkUp, so it stops updating while this is on.")
            point("function", "Readings use the open-source Libre 2 algorithm, not Abbott's, so they can differ a little. Compare them on Read sensor first.")
            point("arrow.uturn.backward", "To switch back, turn this off here and scan the sensor with LibreLink.")
        } header: {
            Text("What changes")
        }

        if !settings.alertsEnabled || notificationsAllowed == false {
            Section {
                if !settings.alertsEnabled {
                    Toggle("GlucOS alerts", isOn: $settings.alertsEnabled)
                }
                if notificationsAllowed == false {
                    Button("Turn On Notifications") { openURL(AlertManager.notificationSettingsURL) }
                }
            } header: {
                Text("Needed first")
            } footer: {
                Text("With LibreLink's alarms off, GlucOS's alerts are the only ones you'll get.")
            }
        }

        Section {
            Toggle("I understand LibreLink's alarms and LinkUp sharing stop", isOn: $understood)
            Button {
                Task { await connect() }
            } label: {
                Label(working ? "Hold the phone on the sensor…" : "Tap Sensor to Connect", systemImage: "sensor.tag.radiowaves.forward.fill")
            }
            .disabled(!canConnect)
        } footer: {
            Text(SensorScanner.isAvailable
                 ? "Works with FreeStyle Libre 2 and 2 Plus. Hold the top of your iPhone against the sensor until it buzzes."
                 : "This iPhone can't read NFC tags.")
        }
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(.tint) }
    }

    // MARK: While on

    @ViewBuilder private func liveSections(_ s: DirectSensor) -> some View {
        Section {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                LabeledContent("Status", value: statusText(at: context.date))
            }
            if let serial = s.serial { LabeledContent("Sensor", value: serial) }
            if let left = s.minutesLeft { LabeledContent("Time left", value: Self.duration(left)) }
            LabeledContent("Connected since", value: s.takenOverAt.formatted(date: .abbreviated, time: .shortened))
            if let problem = direct.problem {
                Text(problem).foregroundStyle(.orange)
            }
        } header: {
            Text("Live from sensor")
        } footer: {
            Text("LibreLink's alarms and LinkUp sharing are off while GlucOS has the sensor. Keep GlucOS alerts on and your iPhone within a few metres. If you close GlucOS from the app switcher, iOS stops waking it for readings until you open it again.")
        }

        Section {
            Button {
                Task { await connect() }
            } label: {
                Label(working ? "Hold the phone on the sensor…" : "Tap Sensor Again", systemImage: "sensor.tag.radiowaves.forward.fill")
            }
            .disabled(working || !SensorScanner.isAvailable)
            Button("Stop and Go Back to LibreLink", role: .destructive) { confirmStop = true }
        } footer: {
            Text("Tap again after starting a new sensor, or if readings stop coming. Settings › Read sensor fills in anything missed in the last 8 hours.")
        }
    }

    private func statusText(at now: Date) -> String {
        switch direct.status {
        case .bluetoothOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth isn't allowed for GlucOS"
        case .sensorEnded: return "Sensor has ended"
        case .off: return "Starting…"
        case .waiting, .receiving:
            guard let last = direct.sensor?.lastPacketAt else { return "Waiting for the sensor…" }
            let minutes = Int(now.timeIntervalSince(last) / 60)
            return minutes < 1 ? "Reading just now" : "Last reading \(minutes) min ago"
        }
    }

    // MARK: Actions

    private func connect() async {
        working = true
        error = nil
        defer { working = false }
        do {
            let scan = try await scanner.scan(.takeOverBluetooth)
            try direct.takeOver(scan)
            handedBack = false
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func duration(_ minutes: Int) -> String {
        minutes >= 1440
            ? "\((Double(minutes) / 1440).formatted(.number.precision(.fractionLength(1)))) days"
            : "\(minutes / 60) h \(minutes % 60) min"
    }
}
