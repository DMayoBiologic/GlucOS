import SwiftUI

// Settings › Alerts › History on the iPhone and the Mac (docs/AlertHistory.md): the last 7 days of
// low and high alerts, grouped by day, each one a button into the Logbook around it. The rules and
// words are in `AlertHistory` / `AlertHistoryText` (Sources/Engine/AlertHistory.swift). Each row
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

/// The days and their alerts, worked out from the logbook's alert records and the stored readings.
/// Recomputed as records arrive (a new alert, a tap synced from the other device), so the list
/// keeps up while it's open.
struct AlertHistoryContent: View {
    let records: [AlertRecord]
    let readings: [GlucoseReading]
    let unit: GlucoseUnit
    let alertsOn: Bool
    /// A row was picked: the Logbook around it.
    let open: (LogbookLink) -> Void

    /// For the alerts' notes: the Logbook's plain notes.
    @EnvironmentObject private var logbook: LogbookStore
    /// Set by `alertNoteEditor()` on the list; without it the rows have no note button.
    @Environment(AlertNoteEditor.self) private var editor: AlertNoteEditor?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let now = Date()
        let items = AlertHistory.items(records: records, readings: readings, now: now)
        let days = AlertHistory.days(items)
        Group {
            if days.isEmpty {
                Section {
                    EmptyStateView(systemImage: alertsOn ? "bell" : "bell.slash",
                                   title: AlertHistoryText.emptyTitle,
                                   message: AlertHistoryText.emptyMessage(alertsOn: alertsOn))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Space.lg)
                        .accessibilityElement(children: .combine)
                }
            } else {
                ForEach(days) { day in
                    Section {
                        ForEach(day.items) { item in
                            AlertHistoryRow(item: item, unit: unit,
                                            note: AlertNote.existing(near: item.firedAt, in: logbook.contexts)?.note,
                                            open: { open(AlertHistory.link(for: item, records: records, now: Date())) },
                                            editNote: editor.map { e -> () -> Void in { e.start(item, in: logbook.contexts) } })
                        }
                    } header: {
                        HStack {
                            Text(ClockLabel.dayTitle(ClockLabel.day(of: day.start, now: now)))
                            Spacer()
                            Text(AlertHistoryText.count(day.items.count))
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                    }
                }
            }
        }
        // A new alert slides in at the top; instant under Reduce Motion.
        .dsAnimation(.standard, value: items.map(\.id))
        // A note appearing under its row, or going, fades in place; instant under Reduce Motion.
        .dsAnimation(.standard, value: noteTexts(items))
    }

    private func noteTexts(_ items: [AlertHistory.Item]) -> [String] {
        items.map { AlertNote.existing(near: $0.firedAt, in: logbook.contexts)?.note ?? "" }
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
    /// Gives an alert history list its rows' Add note buttons and the editor behind them.
    func alertNoteEditor() -> some View { modifier(AlertNoteEditorModifier()) }
}

/// One alert: a bell in the range's colour, what it was and what happened to it, and when, with the
/// reading, and its note when it has one. One VoiceOver element that reads it all and opens the
/// Logbook, with an "Add note" (or "Edit note") action for the note button beside it.
struct AlertHistoryRow: View {
    let item: AlertHistory.Item
    let unit: GlucoseUnit
    /// The note saved at the alert's time, if any.
    var note: String? = nil
    let open: () -> Void
    var editNote: (() -> Void)? = nil

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            mainButton
            if let editNote { noteButton(editNote) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([AlertHistoryText.spoken(item, unit: unit), AlertNoteText.spoken(note)]
            .compactMap { $0 }.joined(separator: ". "))
        .accessibilityHint(AlertHistoryText.hint)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .accessibilityAction(named: Text(AlertNoteText.buttonTitle(hasNote: note != nil))) { editNote?() }
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
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Image(systemName: "bell.fill")
                    .imageScale(.small)
                    .foregroundStyle(item.range.color)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .dsFont(.body)
                        .foregroundStyle(.primary)
                    Label(AlertHistoryText.outcome(item), systemImage: item.outcome.symbol)
                        .labelStyle(.titleAndIcon)
                        .dsFont(.caption)
                        .foregroundStyle(.secondary)
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
