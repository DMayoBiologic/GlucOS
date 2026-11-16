import SwiftUI
import UIKit

/// Export the Logbook for a clinic visit: pick the days, then share a PDF summary (time in range,
/// the average, lows, the usual day and every entry) or a CSV of the entries. Made on the phone from
/// what's already stored on it, so it works with no connection, and it only ever reads the owner's
/// own readings and logbook: nothing from anyone they follow. Opened from the Logbook's toolbar.
struct PhoneExportView: View {
    let readings: [GlucoseReading]
    let entries: [LogEntry]
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double

    @Environment(\.dismiss) private var dismiss
    /// 14, 30 or 90; 0 is a custom range. Remembered on this phone.
    @AppStorage("export.presetDays") private var presetDays = LogbookExport.Preset.fortnight.rawValue
    @AppStorage("export.format") private var formatRaw = LogbookExport.Format.pdf.rawValue
    @AppStorage("export.csvReadings") private var csvReadings = false
    @State private var from = Calendar.current.date(byAdding: .day, value: -13, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var working = false
    @State private var file: ExportFile?
    @State private var problem: String?

    private var format: LogbookExport.Format { LogbookExport.Format(rawValue: formatRaw) ?? .pdf }

    private var period: LogbookExport.Period {
        if presetDays == 0 { return .days(from: from, to: to) }
        return .last(presetDays)
    }

    /// The oldest day anything is stored for, so the custom range can't start before it.
    private var earliest: Date {
        let oldest = [readings.first?.timestamp, entries.last?.timestamp].compactMap { $0 }.min() ?? Date()
        let floor = Calendar.current.date(byAdding: .day, value: -(LogbookExport.maximumDays - 1), to: Date()) ?? oldest
        return Calendar.current.startOfDay(for: min(oldest, floor))
    }

    var body: some View {
        Form {
            daysSection
            formatSection
            Section {
                Button(action: export) {
                    HStack {
                        Spacer()
                        if working { ProgressView().padding(.trailing, DS.Space.xs) }
                        Label(format == .pdf ? "Share PDF" : "Share CSV", systemImage: "square.and.arrow.up")
                            .dsFont(.headline)
                        Spacer()
                    }
                }
                .disabled(working)
                .accessibilityHint("Makes the file on this iPhone, then opens the share sheet")
            } footer: {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    if let problem { Text(problem).foregroundStyle(Tone.warning.textColor) }
                    Text("Made on this iPhone, so it works without a connection. It holds only your own readings and logbook, never anything from people you follow, and nothing is sent anywhere until you share it.")
                }
            }
        }
        .navigationTitle("Export for a clinic visit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        }
        .sheet(item: $file) { f in
            ActivitySheet(url: f.url)
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
    }

    private var daysSection: some View {
        Section {
            Picker("Days", selection: $presetDays) {
                ForEach(LogbookExport.Preset.allCases) { Text($0.label).tag($0.rawValue) }
                Text("Custom").tag(0)
            }
            .pickerStyle(.segmented)
            if presetDays == 0 {
                DatePicker("From", selection: $from, in: earliest...Date(), displayedComponents: .date)
                DatePicker("To", selection: $to, in: earliest...Date(), displayedComponents: .date)
            }
        } header: {
            Text("Days")
        } footer: {
            Text(daysFooter).monospacedDigit()
        }
    }

    /// "2 Nov – 15 Nov 2026 (14 days) · 23 entries".
    private var daysFooter: String {
        let p = period
        let count = entries.filter { p.contains($0.timestamp) }.count
        var line = "\(LogbookExport.periodLine(p)) · \(count == 1 ? "1 entry" : "\(count) entries")"
        if presetDays == 0 && p.days == LogbookExport.maximumDays {
            line += ". Up to \(LogbookExport.maximumDays) days, the most this iPhone keeps."
        }
        return line
    }

    private var formatSection: some View {
        Section {
            Picker("Format", selection: $formatRaw) {
                ForEach(LogbookExport.Format.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            if format == .csv {
                Toggle("Include glucose readings", isOn: $csvReadings)
            }
        } header: {
            Text("Format")
        } footer: {
            Text(formatFooter)
        }
    }

    private var formatFooter: String {
        switch format {
        case .pdf:
            return "Time in range, the average, lows and GMI, your usual day by time of day, then every entry by day. A4, ready to print or email."
        case .csv:
            return csvReadings
                ? "One row per entry and per reading, oldest first, for a spreadsheet or clinic software. Glucose in \(unit.label)."
                : "One row per entry, oldest first, for a spreadsheet or clinic software."
        }
    }

    private func export() {
        guard !working else { return }
        working = true
        problem = nil
        let period = self.period, format = self.format, unit = self.unit
        let low = lowMgdl, high = highMgdl, readings = self.readings, entries = self.entries
        let withReadings = csvReadings
        Task {
            let result: URL? = await Task.detached(priority: .userInitiated) {
                let data: Data
                switch format {
                case .pdf:
                    let report = LogbookExport.report(readings: readings, entries: entries, period: period,
                                                      unit: unit, low: low, high: high)
                    data = LogbookPDF.data(report)
                case .csv:
                    let text = LogbookExport.csv(entries: entries, readings: withReadings ? readings : [],
                                                 period: period, unit: unit)
                    data = Data(text.utf8)
                }
                return try? ExportFile.write(data, name: LogbookExport.fileName(period, format: format))
            }.value
            working = false
            if let result {
                Haptics.play(.done)
                file = ExportFile(url: result)
            } else {
                problem = "Couldn't make the file. Check this iPhone has some free space, then try again."
            }
        }
    }
}

/// A made export waiting to be shared. Kept in this app's temporary folder, which is cleared
/// before each new export, so old exports don't pile up.
struct ExportFile: Identifiable {
    let url: URL
    var id: URL { url }

    static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Export", isDirectory: true) }

    static func write(_ data: Data, name: String) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}

/// The system share sheet for one file: Mail, Messages, AirDrop, Save to Files, Print.
private struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
