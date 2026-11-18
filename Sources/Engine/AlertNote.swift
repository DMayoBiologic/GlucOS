import Foundation

// A short note on a low or high alert (docs/AlertNotes.md): typed straight into the notification's
// "Add note" field, or from the alert's row in Settings › Alerts › Alert History. It is saved as a
// plain Logbook note at the alert's time: a `ContextEvent` with no tags, so it syncs, shows, is
// searched and is exported like any other note, and never counts as a treatment, a meal or
// anything Insights or the forecast read. Saving one never snoozes and never logs a treatment.
// Plain Foundation so the rules are unit-tested.

enum AlertNote {
    /// One short line: longer text is cut here.
    static let maxLength = 120
    /// The note that belongs to an alert: one within this long of when it went off. The Mac and the
    /// iPhone stamp the same alert a little apart, so this matches the history's own merge window.
    static let window: TimeInterval = AlertHistory.sameAlert

    /// The text as saved: trimmed, on one line, at most `maxLength` characters. Nil when nothing
    /// is left.
    static func cleaned(_ text: String) -> String? {
        let oneLine = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oneLine.isEmpty else { return nil }
        guard oneLine.count > maxLength else { return oneLine }
        return String(oneLine.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
    }

    /// A plain note: an event with no tags and some text. Only alert notes are logged like this
    /// (the log sheet always saves an event with at least one tag).
    static func isNote(_ c: ContextEvent) -> Bool { c.tags.isEmpty && !c.note.isEmpty }

    /// The note already saved for the alert that went off at `firedAt`, if any: the closest plain
    /// note within `window`.
    static func existing(near firedAt: Date, in contexts: [ContextEvent]) -> ContextEvent? {
        contexts
            .filter { isNote($0) && abs($0.timestamp.timeIntervalSince(firedAt)) <= window }
            .min { abs($0.timestamp.timeIntervalSince(firedAt)) < abs($1.timestamp.timeIntervalSince(firedAt)) }
    }

    /// What saving `text` for an alert does to the Logbook.
    enum Change: Equatable {
        /// Nothing: empty text and no note yet, or the same text again.
        case none
        /// Save this entry: a new note at the alert's time, or the existing one with new text
        /// (same id, time and tags).
        case save(ContextEvent)
        /// Empty text over an existing note: delete it.
        case remove(UUID)
    }

    static func change(text: String, firedAt: Date, existing: ContextEvent?, id: UUID = UUID()) -> Change {
        let cleaned = cleaned(text)
        if let existing {
            guard let cleaned else { return .remove(existing.id) }
            guard cleaned != existing.note else { return .none }
            var edited = existing
            edited.note = cleaned
            return .save(edited)
        }
        guard let cleaned else { return .none }
        return .save(ContextEvent(id: id, timestamp: firedAt, tags: [], note: cleaned))
    }
}

/// The words for alert notes, shared by both apps.
enum AlertNoteText {
    /// The notification's text action and the history row's button.
    static let addTitle = "Add note"
    static let editTitle = "Edit note"
    static let saveButton = "Save"
    static let removeButton = "Remove Note"
    /// The notification's text field and the editor's.
    static let placeholder = "What happened?"
    /// What the row title of a plain note says in the Logbook.
    static let entryTitle = "Note"

    static func buttonTitle(hasNote: Bool) -> String { hasNote ? editTitle : addTitle }

    /// The editor's title: "Note on Low at 3:12 pm".
    static func editorTitle(_ item: AlertHistory.Item) -> String {
        "Note on \(item.title) at \(ClockLabel.time(item.firedAt))"
    }

    /// Under the editor's field.
    static let editorMessage = "Saved in the Logbook at the alert's time. It never logs a treatment or snoozes."

    /// Read after the rest of the history row.
    static func spoken(_ note: String?) -> String? {
        guard let note, !note.isEmpty else { return nil }
        return "Note: \(note)"
    }
}
