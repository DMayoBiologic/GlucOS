import Foundation

// Day notes (docs/LogbookSearch.md "Day notes", round 70): a few words about a whole day, such as
// "sick day" or "travel". Written from a Logbook day header (iPhone: hold the header; Mac:
// right-click the Day cell), shown under that header and as a caption on the day's chart in the
// Insights Best and toughest days card. Each note syncs as one logbook record (kind `dayNote`)
// whose id is fixed by its date, so two devices writing a note for the same day edit one record
// and the later edit wins. Search reads a day's note with each of that day's rows. Display and
// search only: nothing here touches a forecast or a dose.

/// One day's note, as it syncs.
struct DayNote: Codable, Equatable, Sendable {
    /// The local calendar date it was written for, "2026-11-18" (`DayNotes.key`).
    var day: String
    var text: String
}

enum DayNotes {
    /// The longest note kept, in characters. A note is a label for the day, not a diary.
    static let maxLength = 60

    /// The day's key: its local calendar date, "2026-11-18". A date rather than a moment, so a
    /// note stays on the same day after the phone changes time zone.
    static func key(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Year, month and day of a key, if it is one.
    private static func parts(_ key: String) -> (Int, Int, Int)? {
        let bits = key.split(separator: "-", omittingEmptySubsequences: false)
        guard bits.count == 3, bits[0].count == 4, bits[1].count == 2, bits[2].count == 2,
              let y = Int(bits[0]), let m = Int(bits[1]), let d = Int(bits[2]),
              (1970...9999).contains(y), (1...12).contains(m), (1...31).contains(d) else { return nil }
        return (y, m, d)
    }

    /// Whether `key` names a real date ("2026-02-30" doesn't).
    static func isValid(_ key: String) -> Bool {
        guard let p = parts(key) else { return false }
        let (y, m, d) = p
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let date = cal.date(from: DateComponents(year: y, month: m, day: d)) else { return false }
        return self.key(for: date, calendar: cal) == key
    }

    /// Local midnight of the day a key names.
    static func start(of key: String, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        guard isValid(key), let p = parts(key) else { return nil }
        let (y, m, d) = p
        return calendar.date(from: DateComponents(year: y, month: m, day: d))
    }

    /// The fixed id of a day's synced record: DA7E0000-0000-4000-8000-0000YYYYMMDD. Every device
    /// works out the same id for the same date, so the note is one record, never two.
    static func recordID(for key: String) -> UUID? {
        guard isValid(key) else { return nil }
        let digits = key.replacingOccurrences(of: "-", with: "")
        return UUID(uuidString: "\(idPrefix)\(digits)")
    }

    /// The day a record id belongs to, if it is a day note's.
    static func key(recordID: UUID) -> String? {
        let s = recordID.uuidString
        guard s.hasPrefix(idPrefix) else { return nil }
        let digits = Array(s.dropFirst(idPrefix.count))
        guard digits.count == 8, digits.allSatisfy(\.isNumber) else { return nil }
        let key = "\(String(digits[0..<4]))-\(String(digits[4..<6]))-\(String(digits[6..<8]))"
        return isValid(key) ? key : nil
    }

    private static let idPrefix = "DA7E0000-0000-4000-8000-0000"

    /// What's kept of a typed note: one line, spaces tidied, at most `maxLength` characters.
    /// Empty means no note (saving it removes the day's note).
    static func cleaned(_ text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let line = words.joined(separator: " ")
        guard line.count > maxLength else { return line }
        return String(line.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
    }

    /// The note for the day `date` falls on, if there is one.
    static func note(on date: Date, in notes: [String: String], calendar: Calendar = .autoupdatingCurrent) -> String? {
        guard !notes.isEmpty, let text = notes[key(for: date, calendar: calendar)], !text.isEmpty else { return nil }
        return text
    }
}

/// What day notes say, on iPhone and Mac.
enum DayNoteText {
    /// The menu item and VoiceOver action: "Add Note" or "Edit Note".
    static func actionName(hasNote: Bool) -> String { hasNote ? "Edit Note" : "Add Note" }
    static let removeName = "Remove Note"
    /// The editor's title: "Note for Today", "Note for Tuesday 12 November".
    static func editorTitle(spokenDay: String) -> String { "Note for \(spokenDay)" }
    static let placeholder = "Sick day, travel, new sensor…"
    static let editorMessage = "A few words about the whole day. It shows under the day and on its chart in Insights."
    /// Read with the day header: "Note: sick day".
    static func spoken(_ note: String) -> String { "Note: \(note)" }
    /// A spoken line with the day's note after it: "Best day. Tuesday 10 November, 92% in range. Note: sick day".
    static func withNote(_ spoken: String, _ note: String?) -> String {
        guard let note, !note.isEmpty else { return spoken }
        let end = spoken.hasSuffix(".") || spoken.isEmpty ? "" : "."
        return "\(spoken)\(end) \(Self.spoken(note))".trimmingCharacters(in: .whitespaces)
    }
    /// Said once after a save: "Note added to Today", "Note changed for Friday 13 November", "Note removed from Today".
    static func announcement(spokenDay: String, before: String?, after: String?) -> String? {
        switch (before?.isEmpty == false ? before : nil, after?.isEmpty == false ? after : nil) {
        case (nil, nil): return nil
        case (nil, _?): return "Note added to \(spokenDay)"
        case (_?, nil): return "Note removed from \(spokenDay)"
        case (let b?, let a?): return a == b ? nil : "Note changed for \(spokenDay)"
        }
    }
}
