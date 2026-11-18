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
    /// A row was picked: the Logbook around it.
    let open: (LogbookLink) -> Void

    /// For the alerts' notes: the Logbook's plain notes.
    @EnvironmentObject private var logbook: LogbookStore
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
