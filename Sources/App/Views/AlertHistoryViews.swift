import Charts
import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

// Settings › Alerts › History on the iPhone and the Mac (docs/AlertHistory.md): the last 7 days of
// low and high alerts, grouped by day. Tapping a row opens it in place into a small chart of the
// two hours around the alert, with Open in Logbook under it (docs/AlertHistory.md, "Chart in a
// row"). The rules and words are in `AlertHistory` / `AlertHistoryText`
// (Sources/Engine/AlertHistory.swift) and `AlertHistoryChart` (AlertHistoryChart.swift). Each row
// also has Add note (docs/AlertNotes.md): a short Logbook note at the alert's time, with Undo.

extension AlertHistory.Item {
    /// The range the alert was about, for its bell's colour (as the Logbook's alert rows).
    var range: GlucoseRange {
        switch kind {
        case .urgentLow, .predictedUrgentLow: return .urgentLow
        case .low, .predictedLow: return .low
        case .veryHigh, .predictedVeryHigh: return .veryHigh
        default: return .high
        }
    }
}

extension AlertHistory.Outcome {
    /// The status chip's colour: a tap on "Log treatment" reads as done, a snooze as noted, the
    /// rest as plain.
    var tone: Tone {
        switch self {
        case .treating: return .success
        case .snoozed: return .info
        case .dismissed, .noResponse: return .neutral
        }
    }
}

/// The days and their alerts, worked out from the logbook's alert records and the stored readings.
/// Recomputed as records arrive (a new alert, a tap synced from the other device), so the list
/// keeps up while it's open: a new alert slides in at the top and a row's status chip morphs to
/// its new outcome (docs/AlertHistory.md, "Live while open"). Instant under Reduce Motion.
///
/// VoiceOver hears each change once through `alertHistoryAnnouncements`, which the screen around
/// the list applies (a `List`'s sections come and go, so they can't watch for it themselves).
struct AlertHistoryContent: View {
    let records: [AlertRecord]
    let readings: [GlucoseReading]
    let unit: GlucoseUnit
    let alertsOn: Bool
    /// Open in Logbook was picked under a row's chart: the Logbook around it.
    let open: (LogbookLink) -> Void

    /// For the alerts' notes: the Logbook's plain notes.
    @EnvironmentObject private var logbook: LogbookStore
    /// For the open row's chart: the target band.
    @EnvironmentObject private var settings: AppSettings
    /// Set by `alertNoteEditor()` on the list; without it the rows have no note button.
    @Environment(AlertNoteEditor.self) private var editor: AlertNoteEditor?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The chips picked (docs/AlertHistory.md, "Filters"). Kept while the screen is open only.
    @State private var pick = AlertHistory.FilterPick.all
    /// The chips the rows are showing. It follows `pick` a moment behind, so the old rows fade out
    /// while the highlight slides to the new chip (`settleFilter`), as in the Logbook.
    @State private var listed = AlertHistory.FilterPick.all
    /// The rows' opacity, dipped while the list switches to a new pick's rows.
    @State private var rowsFade = 1.0
    /// The row opened into its chart, if any. One at a time; kept while the screen is open only.
    @State private var openRow: UUID?

    var body: some View {
        let now = Date()
        let items = AlertHistory.items(records: records, readings: readings, now: now)
        let shown = listed.apply(items)
        let days = AlertHistory.days(shown)
        Group {
            if !items.isEmpty {
                Section {
                    // On the bar, not the Group: a Group hands its modifiers to every section.
                    AlertHistoryFilterBar(pick: $pick)
                        .task(id: pick) { await settleFilter() }
                    // Export what the chips show (docs/AlertHistory.md, "Export").
                    AlertHistoryExportRow(records: records, readings: readings, notes: logbook.contexts,
                                          unit: unit, pick: pick,
                                          shown: pick.apply(items).count, total: items.count)
                }
            }
            if items.isEmpty {
                Section {
                    EmptyStateView(systemImage: alertsOn ? "bell" : "bell.slash",
                                   title: AlertHistoryText.emptyTitle,
                                   message: AlertHistoryText.emptyMessage(alertsOn: alertsOn))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Space.lg)
                        .accessibilityElement(children: .combine)
                }
            } else if days.isEmpty {
                // Alerts there are, just none the chips let through: say which, and clear them.
                Section {
                    EmptyStateView(systemImage: "line.3.horizontal.decrease.circle",
                                   title: AlertHistoryText.filteredEmptyTitle,
                                   message: AlertHistoryText.filteredEmptyMessage(listed),
                                   actionTitle: AlertHistoryText.showAllButton,
                                   action: { pick = .all })
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Space.lg)
                        .opacity(rowsFade)
                }
            } else {
                ForEach(days) { day in
                    Section {
                        ForEach(day.items) { item in
                            AlertHistoryRow(item: item, unit: unit,
                                            note: AlertNote.existing(near: item.firedAt, in: logbook.contexts)?.note,
                                            chart: openRow == item.id ? chart(for: item, now: now) : nil,
                                            lowMgdl: settings.lowMgdl, highMgdl: settings.highMgdl,
                                            toggle: { toggle(item) },
                                            open: { open(AlertHistory.link(for: item, records: records, now: Date())) },
                                            editNote: editor.map { e -> () -> Void in { e.start(item, in: logbook.contexts) } })
                            .transition(DS.Transition.banner(reduceMotion: reduceMotion))
                            .opacity(rowsFade)
                        }
                    } header: {
                        HStack {
                            Text(ClockLabel.dayTitle(ClockLabel.day(of: day.start, now: now)))
                            Spacer()
                            Text(AlertHistoryText.count(day.items.count))
                                .monospacedDigit()
                                .contentTransition(reduceMotion ? .identity : .numericText())
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                        .opacity(rowsFade)
                    }
                }
            }
        }
        // A new alert slides in at the top; instant under Reduce Motion. A chip switch doesn't
        // slide rows: it fades them over (`settleFilter`).
        .dsAnimation(.standard, value: items.map(\.id))
        // A note appearing under its row, or going, fades in place; instant under Reduce Motion.
        .dsAnimation(.standard, value: noteTexts(items))
        // A chip switch or an alert ageing out can take the open row away: nothing is open then.
        .onChange(of: shown.map(\.id)) { _, ids in
            let still = AlertHistoryChart.stillOpen(openRow, among: ids)
            if still != openRow { openRow = still }
        }
    }

    /// The open row's chart: its trace, what was logged, and the line VoiceOver reads.
    private func chart(for item: AlertHistory.Item, now: Date) -> AlertHistoryRowChart {
        AlertHistoryRowChart(item: item, readings: readings, entries: logbook.entries, unit: unit, now: now)
    }

    /// A row was tapped: it opens into its chart (closing any other), or closes. The row's height
    /// springs open on the `.emphasized` spring; under Reduce Motion the chart cross-fades in place.
    /// VoiceOver hears the chart's one-line summary as it opens.
    private func toggle(_ item: AlertHistory.Item) {
        let next = AlertHistoryChart.toggled(open: openRow, tapped: item.id)
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : DSMotion.emphasized.animation) {
            openRow = next
        }
        #if os(iOS)
        Haptics.play(.choice)
        #endif
        if next == item.id {
            AccessibilityNotification.Announcement(chart(for: item, now: Date()).spoken).post()
        }
    }

    /// The chips changed (a tap, Show All Alerts): the old rows fade out, the list switches to the
    /// new pick's rows without sliding them, and those fade in. VoiceOver then says how many alerts
    /// are showing, once; a quick run of taps only speaks for the last. Under Reduce Motion the
    /// list just switches.
    private func settleFilter() async {
        let target = pick
        guard target != listed else {
            if rowsFade < 1 { withAnimation(.easeOut(duration: AlertHistory.FilterPick.fadeIn)) { rowsFade = 1 } }
            return
        }
        if !reduceMotion {
            withAnimation(.easeIn(duration: AlertHistory.FilterPick.fadeOut)) { rowsFade = 0 }
            try? await Task.sleep(for: .seconds(AlertHistory.FilterPick.fadeOut))
            guard !Task.isCancelled else { return }
        }
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) { listed = target }
        if !reduceMotion {
            withAnimation(.easeOut(duration: AlertHistory.FilterPick.fadeIn)) { rowsFade = 1 }
        } else {
            rowsFade = 1
        }
        let count = target.apply(AlertHistory.items(records: records, readings: readings, now: Date())).count
        AccessibilityNotification.Announcement(AlertHistoryText.filterAnnouncement(count: count)).post()
    }

    private func noteTexts(_ items: [AlertHistory.Item]) -> [String] {
        items.map { AlertNote.existing(near: $0.firedAt, in: logbook.contexts)?.note ?? "" }
    }
}

/// The history's chips: what kind of alert (All, Lows, Highs, Predicted) and, on a second row,
/// what was done about it (Treated, Snoozed, Dismissed, No response; none picked shows every
/// outcome). In each row the picked chip's highlight is one view that slides to the new pick
/// (`ChipButtonStyle`'s matched geometry, as the Logbook's chips) on the `.emphasized` spring.
/// Instant under Reduce Motion.
struct AlertHistoryFilterBar: View {
    @Binding var pick: AlertHistory.FilterPick

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var kindSpace
    @Namespace private var outcomeSpace

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            chipRow(label: AlertHistoryText.kindChipsLabel) {
                chip(AlertHistoryText.allChip, systemImage: nil, tint: Palette.brand,
                     selected: pick.kind == nil, space: kindSpace) { pick.kind = nil }
                ForEach(AlertHistory.KindFilter.allCases) { k in
                    chip(k.title, systemImage: k.symbol, tint: k.tint,
                         selected: pick.kind == k, space: kindSpace) { pick.kind = k }
                }
            }
            chipRow(label: AlertHistoryText.outcomeChipsLabel) {
                ForEach(AlertHistory.OutcomeFilter.allCases) { o in
                    chip(o.title, systemImage: o.symbol, tint: o.tint,
                         selected: pick.outcome == o, space: outcomeSpace) {
                        pick.outcome = pick.outcome == o ? nil : o
                    }
                    .accessibilityLabel(o.spoken)
                }
            }
        }
        .padding(.vertical, DS.Space.xs)
        .animation(reduceMotion ? nil : DSMotion.emphasized.animation, value: pick)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: DS.Space.xs, leading: 0, bottom: DS.Space.xs, trailing: 0))
    }

    private func chipRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.sm) { content() }
                .padding(.horizontal, DS.Space.lg)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func chip(_ title: String, systemImage: String?, tint: Color, selected: Bool,
                      space: Namespace.ID, action: @escaping () -> Void) -> some View {
        Button {
            action()
            #if os(iOS)
            Haptics.play(.choice)
            #endif
        } label: {
            HStack(spacing: DS.Space.xs) {
                if let systemImage { Image(systemName: systemImage).imageScale(.small) }
                Text(title)
            }
        }
        .buttonStyle(ChipButtonStyle(selected: selected, tint: tint, highlight: space))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension AlertHistory.KindFilter {
    var tint: Color {
        switch self {
        case .lows: return GlucoseRange.low.color
        case .highs: return GlucoseRange.high.color
        case .predicted: return Palette.brand
        }
    }
}

extension AlertHistory.OutcomeFilter {
    var tint: Color {
        switch self {
        case .treated: return AlertHistory.Outcome.treating.tone.color
        case .snoozed: return AlertHistory.Outcome.snoozed(minutes: nil).tone.color
        case .dismissed, .noResponse: return Palette.brand
        }
    }
}

/// Speaks what changes in the alert history while it's open, once per change: a new alert, or an
/// alert's outcome moving on (`AlertHistory.changes`, `AlertHistoryText.announcement`). A short
/// pause gathers a burst, so the Mac's and the iPhone's copies of one alert syncing in a moment
/// apart are spoken once. Nothing is said for what was already listed when it opened.
private struct AlertHistoryAnnouncements: ViewModifier {
    let records: [AlertRecord]
    let readings: [GlucoseReading]
    let unit: GlucoseUnit

    /// How long a burst of changes is gathered before its one announcement.
    static let delay: Duration = .milliseconds(600)

    /// What VoiceOver was last told about: the list as it opened, then after each announcement.
    @State private var announced: [AlertHistory.Item]?
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        let items = AlertHistory.items(records: records, readings: readings, now: Date())
        content
            .onAppear { if announced == nil { announced = items } }
            .onChange(of: items) { _, latest in announceSoon(latest) }
            .onDisappear {
                pending?.cancel()
                pending = nil
            }
    }

    private func announceSoon(_ latest: [AlertHistory.Item]) {
        guard announced != nil else {
            announced = latest
            return
        }
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled, let base = announced else { return }
            announced = latest
            let changes = AlertHistory.changes(from: base, to: latest, now: Date())
            if let text = AlertHistoryText.announcement(changes, unit: unit) {
                LoggedElsewhere.announce(text)
            }
        }
    }
}

/// The alert whose note is being written in the history, and the text so far.
@Observable @MainActor
final class AlertNoteEditor {
    var item: AlertHistory.Item?
    var draft = ""
    var hasNote = false

    func start(_ item: AlertHistory.Item, in contexts: [ContextEvent]) {
        let existing = AlertNote.existing(near: item.firedAt, in: contexts)
        draft = existing?.note ?? ""
        hasNote = existing != nil
        self.item = item
    }
}

/// Hosts the note editor for an alert history list (an `.alert` with a text field, as day notes
/// use): Save, Remove Note when there is one, Cancel. Saving goes through
/// `LogbookStore.saveAlertNote`, with Undo on the toast. Never logs a treatment, never snoozes.
private struct AlertNoteEditorModifier: ViewModifier {
    @EnvironmentObject private var logbook: LogbookStore
    @State private var editor = AlertNoteEditor()

    func body(content: Content) -> some View {
        @Bindable var bound = editor
        content
            .environment(editor)
            .alert(editor.item.map(AlertNoteText.editorTitle) ?? AlertNoteText.addTitle,
                   isPresented: Binding(get: { editor.item != nil }, set: { if !$0 { editor.item = nil } })) {
                TextField(AlertNoteText.placeholder, text: $bound.draft)
                #if os(iOS)
                    .textInputAutocapitalization(.sentences)
                #endif
                Button(AlertNoteText.saveButton) { save() }
                if editor.hasNote {
                    Button(AlertNoteText.removeButton, role: .destructive) { save(removing: true) }
                }
                Button("Cancel", role: .cancel) { editor.item = nil }
            } message: {
                Text(AlertNoteText.editorMessage)
            }
    }

    private func save(removing: Bool = false) {
        guard let item = editor.item else { return }
        editor.item = nil
        let text = removing ? "" : editor.draft
        #if os(iOS)
        if logbook.saveAlertNote(text, firedAt: item.firedAt) != nil, !removing { Haptics.play(.logSaved) }
        #else
        logbook.saveAlertNote(text, firedAt: item.firedAt)
        #endif
    }
}

extension View {
    /// One VoiceOver announcement per change to the alert history shown inside (a `List` of
    /// `AlertHistoryContent`), while it's open.
    func alertHistoryAnnouncements(records: [AlertRecord], readings: [GlucoseReading], unit: GlucoseUnit) -> some View {
        modifier(AlertHistoryAnnouncements(records: records, readings: readings, unit: unit))
    }

    /// Gives an alert history list its rows' Add note buttons and the editor behind them.
    func alertNoteEditor() -> some View { modifier(AlertNoteEditorModifier()) }
}

/// One alert: a bell in the range's colour, what it was and what happened to it, and when, with the
/// reading, and its note when it has one. Tapped, it opens in place into a small chart of the two
/// hours around the alert, with Open in Logbook under it. One VoiceOver element that reads it all
/// (and the chart's one-line summary while open) and opens or closes the chart, with "Open in
/// Logbook" and "Add note" (or "Edit note") actions.
struct AlertHistoryRow: View {
    let item: AlertHistory.Item
    let unit: GlucoseUnit
    /// The note saved at the alert's time, if any.
    var note: String? = nil
    /// The chart, while this row is open.
    var chart: AlertHistoryRowChart? = nil
    var lowMgdl: Double = 70
    var highMgdl: Double = 180
    /// Opens or closes the chart.
    let toggle: () -> Void
    /// The Logbook around the alert.
    let open: () -> Void
    var editNote: (() -> Void)? = nil

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                mainButton
                if let editNote { noteButton(editNote) }
            }
            if let chart {
                chartPanel(chart)
                    .transition(reduceMotion ? AnyTransition.opacity
                                : AnyTransition.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([AlertHistoryText.spoken(item, unit: unit), AlertNoteText.spoken(note), chart?.spoken]
            .compactMap { $0 }.joined(separator: ". "))
        .accessibilityHint(chart == nil ? AlertHistoryChartText.showHint : AlertHistoryChartText.hideHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
        .accessibilityAction(named: Text(AlertHistoryChartText.openLogbook)) { open() }
        .accessibilityAction(named: Text(AlertNoteText.buttonTitle(hasNote: note != nil))) { editNote?() }
    }

    /// The open row's chart, its lowest and highest, and Open in Logbook.
    private func chartPanel(_ chart: AlertHistoryRowChart) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            AlertHistoryMiniChart(item: item, chart: chart, unit: unit, lowMgdl: lowMgdl, highMgdl: highMgdl)
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Text(chart.caption)
                    .dsFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: open) {
                    Label(AlertHistoryChartText.openLogbook, systemImage: "book")
                        .dsFont(.caption)
                }
                .buttonStyle(.borderless)
                .help(AlertHistoryChartText.openLogbookHint)
            }
        }
        .padding(.leading, 20 + DS.Space.sm)
    }

    /// The pencil beside the row: Add note, or Edit note once there's one.
    private func noteButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: note == nil ? "square.and.pencil" : "note.text")
                .imageScale(.medium)
                .foregroundStyle(note == nil ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                .frame(minWidth: 32, minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(AlertNoteText.buttonTitle(hasNote: note != nil))
        .accessibilityLabel(AlertNoteText.buttonTitle(hasNote: note != nil))
    }

    private var mainButton: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Image(systemName: "bell.fill")
                    .imageScale(.small)
                    .foregroundStyle(item.range.color)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .dsFont(.body)
                        .foregroundStyle(.primary)
                    AlertOutcomeChip(item: item)
                    if let note {
                        Text(note)
                            .dsFont(.caption)
                            .italic()
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .transition(.opacity)
                    }
                    if typeSize.dsLargeText { trailing(alignment: .leading) }
                }
                Spacer(minLength: DS.Space.sm)
                if !typeSize.dsLargeText { trailing(alignment: .trailing) }
                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(chart == nil ? 0 : 180))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func trailing(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(ClockLabel.time(item.firedAt))
                .dsFont(.callout)
                .monospacedDigit()
            Text(AlertHistoryText.reading(item.readingMgdl, unit: unit))
                .dsFont(.caption)
                .monospacedDigit()
                .foregroundStyle(item.readingMgdl == nil ? HierarchicalShapeStyle.tertiary : HierarchicalShapeStyle.secondary)
        }
    }
}

/// What happened to an alert, as a small status chip. When the outcome moves on while the list is
/// open (snoozed, "Log treatment" tapped, dismissed, on either device) the chip morphs: the symbol
/// replaces itself, the words blend, the tint glides, on the `.emphasized` spring. Instant under
/// Reduce Motion. The row speaks for it, so the chip is hidden from VoiceOver.
struct AlertOutcomeChip: View {
    let item: AlertHistory.Item

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let tone = item.outcome.tone
        HStack(spacing: DS.Space.xs) {
            Image(systemName: item.outcome.symbol)
                .imageScale(.small)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            Text(AlertHistoryText.outcome(item))
                .contentTransition(reduceMotion ? .identity : .interpolate)
        }
        .dsFont(.caption)
        .fontWeight(.medium)
        .lineLimit(1)
        .foregroundStyle(tone.textColor)
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, 2)
        .background(tone.color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(tone.color.opacity(contrast == .increased ? 0.9 : 0.28),
                                        lineWidth: contrast == .increased ? DS.Stroke.increased : 0.5))
        .dsAnimation(.emphasized, value: item.outcome)
        .accessibilityHidden(true)
    }
}

/// A row picked in the iPhone's alert history, for the home stack: Settings closes and the Logbook
/// opens around that alert. Cleared by the screen that opened it.
@MainActor
final class AlertHistoryRoute: ObservableObject {
    static let shared = AlertHistoryRoute()
    @Published var request: LogbookLink?

    func open(_ link: LogbookLink) { request = link }

    func take() -> LogbookLink? {
        guard let link = request else { return nil }
        request = nil
        return link
    }
}

/// The history's export row, under the chips: how many alerts are shown, and an Export menu that
/// makes a PDF or CSV of exactly those (the chips as picked, with each alert's note). The iPhone
/// opens the share sheet, the Mac asks where to save. Made on the device from the owner's own alert
/// records, readings and notes, never anything from people they follow (`AlertHistoryExport`).
struct AlertHistoryExportRow: View {
    let records: [AlertRecord]
    let readings: [GlucoseReading]
    let notes: [ContextEvent]
    let unit: GlucoseUnit
    let pick: AlertHistory.FilterPick
    let shown: Int
    let total: Int

    @State private var working = false
    /// After a save on the Mac, or a failure on either: one line under the count.
    @State private var status: String?
    #if os(iOS)
    @State private var file: ExportFile?
    private let device = LogbookExport.Device.iPhone
    #else
    private let device = LogbookExport.Device.mac
    #endif

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AlertHistoryExportText.shown(shown, of: total))
                    .dsFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let status {
                    Text(status)
                        .dsFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: DS.Space.sm)
            if working { ProgressView().controlSize(.small) }
            Menu {
                ForEach(LogbookExport.Format.allCases) { format in
                    Button {
                        export(format)
                    } label: {
                        Label(AlertHistoryExportText.item(format, device: device),
                              systemImage: format == .pdf ? "doc.richtext" : "tablecells")
                    }
                }
            } label: {
                Label(AlertHistoryExportText.button, systemImage: "square.and.arrow.up")
            }
            #if os(macOS)
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            #endif
            .disabled(shown == 0 || working)
            .accessibilityHint(AlertHistoryExportText.hint)
        }
        .padding(.horizontal, DS.Space.lg)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: DS.Space.xs, trailing: 0))
        #if os(iOS)
        .sheet(item: $file) { f in
            ActivitySheet(url: f.url)
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        #endif
    }

    private func makeReport() -> AlertHistoryExport.Report {
        AlertHistoryExport.report(records: records, readings: readings, notes: notes, pick: pick,
                                  unit: unit, device: device)
    }

    private static func data(_ report: AlertHistoryExport.Report, format: LogbookExport.Format) -> Data {
        switch format {
        case .pdf: return AlertHistoryPDF.data(report)
        case .csv: return Data(AlertHistoryExport.csv(report).utf8)
        }
    }

    private func fail() {
        let text = AlertHistoryExportText.problem(device)
        status = text
        AccessibilityNotification.Announcement(text).post()
    }

    #if os(iOS)
    /// Makes the file off the main thread (as the Logbook export does), then opens the share sheet.
    private func export(_ format: LogbookExport.Format) {
        guard !working else { return }
        working = true
        status = nil
        let report = makeReport()
        Task {
            let url: URL? = await Task.detached(priority: .userInitiated) {
                try? ExportFile.write(Self.data(report, format: format),
                                      name: AlertHistoryExport.fileName(report, format: format))
            }.value
            working = false
            if let url {
                Haptics.play(.done)
                file = ExportFile(url: url)
            } else {
                fail()
            }
        }
    }
    #else
    /// Asks where to save, then makes the file there. Drawn on the main thread, as the Logbook's
    /// Mac export: AppKit text drawing is safest there, and a week of alerts is quick.
    private func export(_ format: LogbookExport.Format) {
        let report = makeReport()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .pdf ? .pdf : .commaSeparatedText]
        panel.nameFieldStringValue = AlertHistoryExport.fileName(report, format: format)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Self.data(report, format: format).write(to: url, options: .atomic)
            let text = AlertHistoryExportText.saved(url.lastPathComponent)
            status = text
            AccessibilityNotification.Announcement(text).post()
        } catch {
            fail()
        }
    }
    #endif
}

// MARK: - Chart in a row

/// What an open row's chart shows: the trace of the two hours around the alert, what was logged
/// then, the caption and the one line VoiceOver reads (`AlertHistoryChart`). Worked out only for
/// the open row.
struct AlertHistoryRowChart {
    let window: DateInterval
    let segments: [[DayChartPoint]]
    let markers: [ChartLogMarker]
    let caption: String
    let spoken: String

    init(item: AlertHistory.Item, readings: [GlucoseReading], entries: [LogEntry], unit: GlucoseUnit, now: Date) {
        window = AlertHistoryChart.window(for: item)
        segments = AlertHistoryChart.segments(readings, for: item, now: now)
        var doses: [InsulinDose] = [], meals: [MealEntry] = [], contexts: [ContextEvent] = []
        for e in entries where AlertHistoryChart.contains(e.timestamp, for: item, now: now) {
            switch e {
            case .dose(let d): doses.append(d)
            case .meal(let m): meals.append(m)
            case .context(let c): contexts.append(c)
            case .siteChange: break
            }
        }
        // The alert's own note is already under the row, so notes aren't marked again.
        markers = ChartLogMarker.logbook(doses: doses, meals: meals, contexts: contexts, since: window.start, notes: false)
        caption = AlertHistoryChartText.caption(segments, unit: unit)
        spoken = AlertHistoryChartText.spoken(item, segments: segments, logged: markers.count, unit: unit, now: now)
    }
}

/// The open row's chart: the reading line on the target band across the two hours around the
/// alert, a rule at the alert's moment in its range's colour, and what was logged marked along the
/// bottom (the Logbook day chart's markers). A picture only, hidden from VoiceOver: the row reads
/// `AlertHistoryRowChart.spoken` instead.
struct AlertHistoryMiniChart: View {
    let item: AlertHistory.Item
    let chart: AlertHistoryRowChart
    let unit: GlucoseUnit
    let lowMgdl: Double
    let highMgdl: Double
    var height: CGFloat = 96

    private var yDomain: ClosedRange<Double> {
        let values = chart.segments.joined().map(\.mgdl) + [lowMgdl, highMgdl] + (item.readingMgdl.map { [$0] } ?? [])
        let lo = min(values.min() ?? 60, 60) - 10
        let hi = max(values.max() ?? 200, 200) + 10
        return unit.value(fromMgdl: lo)...unit.value(fromMgdl: hi)
    }

    var body: some View {
        let yd = yDomain
        let all = Array(chart.segments.joined())
        let line = ThresholdGradient.style(minMgdl: all.map(\.mgdl).min() ?? lowMgdl,
                                           maxMgdl: all.map(\.mgdl).max() ?? highMgdl,
                                           low: lowMgdl, high: highMgdl)
        Chart {
            RectangleMark(
                xStart: .value("Start", chart.window.start), xEnd: .value("End", chart.window.end),
                yStart: .value("Low", unit.value(fromMgdl: lowMgdl)),
                yEnd: .value("High", unit.value(fromMgdl: highMgdl))
            )
            .foregroundStyle(GlucoseRange.inRange.tint.opacity(0.12))

            RuleMark(x: .value("Alert", item.firedAt))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(item.range.color.opacity(0.8))
                .annotation(position: .top, spacing: 0) {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(item.range.color)
                }

            ForEach(Array(chart.segments.enumerated()), id: \.offset) { i, run in
                ForEach(run, id: \.date) { p in
                    LineMark(
                        x: .value("Time", p.date),
                        y: .value("Glucose", unit.value(fromMgdl: p.mgdl)),
                        series: .value("Run", i)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(line)
                    .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                }
                if run.count == 1, let p = run.first {
                    PointMark(x: .value("Time", p.date), y: .value("Glucose", unit.value(fromMgdl: p.mgdl)))
                        .symbolSize(10)
                        .foregroundStyle(GlucoseRange.classify(mgdl: p.mgdl, low: lowMgdl, high: highMgdl).tint)
                }
            }

            // The reading the alert went off on, as a dot on the rule.
            if let mgdl = item.readingMgdl {
                PointMark(x: .value("Alert", item.firedAt), y: .value("Glucose", unit.value(fromMgdl: mgdl)))
                    .symbolSize(28)
                    .foregroundStyle(item.range.color)
            }

            ForEach(chart.markers) { m in
                PointMark(x: .value("Time", m.date), y: .value("Logged", markerY(lane: m.lane, yd: yd)))
                    .symbol { DayMarkerSymbol(marker: m) }
            }
        }
        .chartXScale(domain: chart.window.start...chart.window.end)
        .chartYScale(domain: yd)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: [chart.window.start, item.firedAt, chart.window.end]) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.quaternary)
                AxisValueLabel(format: .dateTime.hour().minute(), centered: false)
                    .font(.caption2)
            }
        }
        .padding(.top, DS.Space.sm)
        .frame(height: height)
        .accessibilityHidden(true)
    }

    /// Markers sit in rows along the bottom of the chart, a meal above a dose logged with it.
    private func markerY(lane: Int, yd: ClosedRange<Double>) -> Double {
        let span = yd.upperBound - yd.lowerBound
        return yd.lowerBound + span * (0.08 + 0.13 * Double(lane))
    }
}
