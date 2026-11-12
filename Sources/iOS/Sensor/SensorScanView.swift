import SwiftUI

/// Settings › Identify sensor: tap the phone on the sensor to see which Libre it is.
struct SensorScanView: View {
    @State private var scanner = SensorScanner()
    @State private var result: SensorScanResult?
    @State private var error: String?
    @State private var scanning = false

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await scan() }
                } label: {
                    Label(scanning ? "Scanning…" : "Scan sensor", systemImage: "sensor.tag.radiowaves.forward.fill")
                }
                .disabled(scanning || !SensorScanner.isAvailable)
            } footer: {
                Text(SensorScanner.isAvailable
                     ? "Hold the top of your iPhone against the sensor. GlucOS only reads the sensor's type and serial. It doesn't read glucose, pair, or change anything, so LibreLink keeps working as usual."
                     : "This iPhone can't read NFC tags.")
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }

            if let r = result {
                Section("Sensor") {
                    LabeledContent("Type", value: r.patchInfo.family.rawValue)
                    LabeledContent("Region", value: r.patchInfo.region.rawValue)
                    if let serial = r.serial { LabeledContent("Serial", value: serial) }
                    if let days = r.patchInfo.lifetimeDays { LabeledContent("Wear time", value: "\(days) days") }
                    LabeledContent("Patch info", value: r.patchInfo.hex)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
                Section("Reading it without the cloud") {
                    Text(accessText(r.patchInfo.directAccess))
                        .dsFont(.caption)
                }
            }
        }
        .navigationTitle("Identify Sensor")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func scan() async {
        scanning = true
        error = nil
        defer { scanning = false }
        do {
            result = try await scanner.scan()
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func accessText(_ access: LibrePatchInfo.DirectAccess) -> String {
        switch access {
        case .nfcPlain:
            return "This sensor's readings aren't encrypted, so GlucOS could read them with a tap."
        case .encryptedKnown:
            return "Readings are encrypted, but open-source apps can decode them. A tap gives the last 8 hours. A live Bluetooth feed would take the connection from LibreLink, which stops its alarms and LinkUp sharing. GlucOS keeps using LinkUp for now."
        case .none:
            return "There's no known way to read this sensor on iPhone without Abbott's app. GlucOS keeps using LinkUp."
        case .unknown:
            return "GlucOS doesn't recognise this sensor yet. The patch info bytes above identify it."
        }
    }
}
