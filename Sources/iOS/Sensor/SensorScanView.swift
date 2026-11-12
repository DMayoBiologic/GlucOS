import Charts
import SwiftUI

/// Settings › Read sensor: tap the phone on the sensor to see which Libre it is and, for a Libre 2
/// or 2 Plus, its current reading and last 8 hours, decoded on the phone and set against LinkUp's.
struct SensorScanView: View {
    @EnvironmentObject var store: GlucoseStore
    @EnvironmentObject var settings: AppSettings
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
                     ? "Hold the top of your iPhone against the sensor. GlucOS reads its type and, for a Libre 2 or 2 Plus, its last 8 hours of readings. Reading doesn't change anything on the sensor, so LibreLink keeps working as usual."
                     : "This iPhone can't read NFC tags.")
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }

            if let r = result {
                if r.fram != nil || !r.readings.isEmpty { readingSection(r, current: r.readings.last) }
                if let problem = r.decodeProblem {
                    Section {
                        Text(problem).foregroundStyle(.orange)
                    } footer: {
                        if let detail = r.decodeDetail {
                            Text("Details: \(detail)")
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
                if !r.readings.isEmpty { comparisonSection(r.readings) }
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
                    Text(accessText(r))
                        .dsFont(.caption)
                }
            }
        }
        .navigationTitle("Read Sensor")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Sections

    private func readingSection(_ r: SensorScanResult, current: GlucoseReading?) -> some View {
        Section {
            if let current {
                HStack(alignment: .firstTextBaseline) {
                    Text(settings.unit.format(mgdl: current.mgdl))
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                    Text(settings.unit.label).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: current.trend.systemImage)
                        .font(.title2)
                        .accessibilityLabel(current.trend.description)
                }
                // Usually the minute of the tap; older when the last 16 minutes had nothing valid.
                LabeledContent("Measured", value: current.timestamp.formatted(date: .omitted, time: .shortened))
            } else {
                Text("The sensor has no glucose to show yet (warming up, or a temporary sensor error).")
                    .foregroundStyle(.secondary)
            }
            if let fram = r.fram {
                LabeledContent("Sensor age", value: Self.days(fram.age))
                LabeledContent("Time left", value: Self.days(max(0, fram.maxLife - fram.age)))
                LabeledContent("State", value: Self.stateText(fram.state))
            }
        } header: {
            Text("From the sensor")
        } footer: {
            Text("Decoded on your phone with the open-source Libre 2 algorithm, not Abbott's. Confirm with LibreLink before treating.")
        }
    }

    private func comparisonSection(_ ours: [GlucoseReading]) -> some View {
        let reference = linkUpReadings(around: ours)
        let agreement = LibreReadings.agreement(ours, linkUp: reference)
        return Section {
            Chart {
                ForEach(reference, id: \.timestamp) { p in
                    LineMark(x: .value("Time", p.timestamp), y: .value("Glucose", settings.unit.value(fromMgdl: p.mgdl)))
                        .foregroundStyle(by: .value("Source", "LinkUp"))
                }
                ForEach(ours, id: \.timestamp) { p in
                    LineMark(x: .value("Time", p.timestamp), y: .value("Glucose", settings.unit.value(fromMgdl: p.mgdl)))
                        .foregroundStyle(by: .value("Source", "Sensor"))
                }
            }
            .chartForegroundStyleScale(["Sensor": Color.blue, "LinkUp": Color.gray])
            .frame(height: 180)
            if let a = agreement {
                LabeledContent("Matched readings", value: "\(a.pairs)")
                LabeledContent("Average difference", value: settings.unit.format(mgdl: a.meanAbsoluteDifference, withUnit: true))
                LabeledContent("Relative difference", value: a.mard.formatted(.percent.precision(.fractionLength(1))))
                LabeledContent("Sensor reads", value: a.bias >= 0
                               ? "\(settings.unit.format(mgdl: a.bias, withUnit: true)) higher"
                               : "\(settings.unit.format(mgdl: -a.bias, withUnit: true)) lower")
            } else {
                Text("No LinkUp readings from the same times to compare with yet.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Compared with LinkUp")
        } footer: {
            Text("LinkUp's numbers come from Abbott's own algorithm. A relative difference under about 10% is as close as two Libre readers usually get.")
        }
    }

    private func linkUpReadings(around ours: [GlucoseReading]) -> [GlucoseReading] {
        guard let start = ours.first?.timestamp.addingTimeInterval(-300),
              let end = ours.last?.timestamp.addingTimeInterval(300) else { return [] }
        var byTime = [Date: GlucoseReading]()
        for r in store.archive + store.snapshot.history + [store.snapshot.current].compactMap({ $0 }) {
            byTime[r.timestamp] = r
        }
        return byTime.values.filter { $0.timestamp >= start && $0.timestamp <= end }.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: Actions

    private func scan() async {
        scanning = true
        error = nil
        defer { scanning = false }
        do {
            result = try await scanner.scan(.read)
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Text

    private static func days(_ minutes: Int) -> String {
        let d = Double(minutes) / 1440
        return d >= 1 ? "\(d.formatted(.number.precision(.fractionLength(1)))) days"
                      : "\(minutes / 60) h \(minutes % 60) min"
    }

    private static func stateText(_ s: LibreFRAM.State) -> String {
        switch s {
        case .notActivated: return "Not started"
        case .warmingUp: return "Warming up"
        case .active: return "Active"
        case .expired: return "Expired"
        case .shutdown: return "Ended"
        case .failure: return "Failed"
        case .unknown(let b): return String(format: "Unknown (0x%02X)", b)
        }
    }

    private func accessText(_ r: SensorScanResult) -> String {
        switch r.patchInfo.directAccess {
        case .nfcPlain:
            return "This sensor's readings aren't encrypted, so GlucOS could read them with a tap."
        case .encryptedKnown:
            return r.fram != nil
                ? "GlucOS decoded this sensor itself. A live Bluetooth feed would take the connection from LibreLink, which stops its alarms and LinkUp sharing. GlucOS keeps using LinkUp for now."
                : "Readings are encrypted, but open-source apps can decode them. A live Bluetooth feed would take the connection from LibreLink, which stops its alarms and LinkUp sharing."
        case .none where r.patchInfo.isGen2:
            return "This sensor uses Abbott's newer Gen2 security, which locks its memory and Bluetooth to Abbott's apps. No open-source app can read it yet, so GlucOS keeps using LinkUp."
        case .none:
            return "There's no known way to read this sensor on iPhone without Abbott's app. GlucOS keeps using LinkUp."
        case .unknown:
            return "GlucOS doesn't recognise this sensor yet. The patch info bytes above identify it."
        }
    }
}
