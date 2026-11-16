import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Mac's Logbook export for a clinic visit, matching the iPhone's (`PhoneExportView`): pick the
/// days (14, 30 or 90, or custom), pick a PDF summary or a CSV, then save it where you like. The
/// figures, words, CSV columns and PDF pages come from the same code as the iPhone
/// (`LogbookExport`, `LogbookPDF`), so the two files are the same apart from "Made on this Mac".
/// Made from what's already stored on this Mac (`GlucoseStore.archive` and `LogbookStore.entries`),
/// so it works offline, and nothing about anyone the person follows is read. Opened from the
/// dashboard's Export menu (⇧⌘E).
struct MacExportView: View {
    let readings: [GlucoseReading]
    let entries: [LogEntry]
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    /// The file was saved, or couldn't be. The dashboard shows a toast either way.
    var onFinish: (Result<URL, ExportProblem>) -> Void = { _ in }

    struct ExportProblem: Error {
        let url: URL
    }

    @Environment(\.dismiss) private var dismiss
    /// 14, 30 or 90; 0 is a custom range. Remembered on this Mac, under the iPhone's key names.
    @AppStorage("export.presetDays") private var presetDays = LogbookExport.Preset.fortnight.rawValue
    @AppStorage("export.format") private var formatRaw = LogbookExport.Format.pdf.rawValue
    @AppStorage("export.csvReadings") private var csvReadings = false
    @State private var from = Calendar.current.date(byAdding: .day, value: -13, to: Date()) ?? Date()
    @State private var to = Date()

    private var format: LogbookExport.Format { LogbookExport.Format(rawValue: formatRaw) ?? .pdf }

    private var period: LogbookExport.Period {
        if presetDays == 0 { return .days(from: from, to: to) }
        return .last(presetDays)
    }

    /// The oldest day anything is stored for, so the custom range can't start before it.
    private var earliest: Date {
        let oldest = [readings.first?.timestamp, entries.map(\.timestamp).min()].compactMap { $0 }.min() ?? Date()
        let floor = Calendar.current.date(byAdding: .day, value: -(LogbookExport.maximumDays - 1), to: Date()) ?? oldest
        return Calendar.current.startOfDay(for: min(oldest, floor))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Export for a Clinic Visit")
                .dsFont(.title)
                .accessibilityAddTraits(.isHeader)
                .padding([.horizontal, .top], DS.Space.xl)
            Form {
                daysSection
                formatSection
                Section {
                    Text("Made on this Mac, so it works without a connection. It holds only your own readings and logbook, never anything from people you follow, and nothing is sent anywhere until you share the file.")
                        .dsFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(format == .pdf ? "Save PDF…" : "Save CSV…", action: save)
                    .buttonStyle(.ds(.primary))
                    .keyboardShortcut(.defaultAction)
                    .help("Choose where to save the file")
            }
            .padding([.horizontal, .bottom], DS.Space.xl)
        }
        // Tall enough for the custom From/To rows without scrolling.
        .frame(width: 500)
        .frame(minHeight: 470, idealHeight: 560)
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
            Text(daysFooter)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// "2 Nov – 15 Nov 2026 (14 days) · 23 entries".
    private var daysFooter: String {
        let p = period
        let count = entries.filter { p.contains($0.timestamp) }.count
        var line = "\(LogbookExport.periodLine(p)) · \(count == 1 ? "1 entry" : "\(count) entries")"
        if presetDays == 0 && p.days == LogbookExport.maximumDays {
            line += ". Up to \(LogbookExport.maximumDays) days, the most this Mac keeps."
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
                .foregroundStyle(.secondary)
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

    /// Asks where to save, then makes the file there. Drawn on the main thread: AppKit text drawing
    /// is safest there, and even 90 days of entries takes a moment.
    private func save() {
        let period = self.period, format = self.format
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .pdf ? .pdf : .commaSeparatedText]
        panel.nameFieldStringValue = LogbookExport.fileName(period, format: format)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data: Data
        switch format {
        case .pdf:
            let report = LogbookExport.report(readings: readings, entries: entries, period: period,
                                              unit: unit, low: lowMgdl, high: highMgdl, device: .mac)
            data = LogbookPDF.data(report)
        case .csv:
            let text = LogbookExport.csv(entries: entries, readings: csvReadings ? readings : [],
                                         period: period, unit: unit)
            data = Data(text.utf8)
        }
        do {
            try data.write(to: url, options: .atomic)
            dismiss()
            onFinish(.success(url))
        } catch {
            onFinish(.failure(ExportProblem(url: url)))
        }
    }
}
