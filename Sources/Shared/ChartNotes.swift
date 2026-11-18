import Foundation

/// Notes on the glucose chart: a plain note in the Logbook (a context entry with text and no tags,
/// `AlertNote.isNote`), including one added from a low or high alert, shows as a small note marker
/// at its time on iPhone Today, the Mac popover and the Mac Outlook chart. It behaves like every
/// other marker: it pops in and shrinks out (`MarkerPop`), a hold or hover peeks at it
/// (`MarkerPeek`), a tap opens its callout with the whole note (`MarkerCallout`), the peek card
/// offers Edit (`MarkerActions`), and a scrub snaps onto it (`ScrubSnap`). Plain Foundation so it
/// can be unit-tested; `ChartLogMarker.logbook` builds the marker.
///
/// VoiceOver reads one line per note, "Note at 3:05 pm: Felt shaky after the walk". Under Reduce
/// Motion the marker just appears or goes. Followers never see the person's notes on the chart.
enum ChartNote {
    /// The marker's symbol.
    static let systemImage = "note.text"

    /// Notes share the context lane with wake-ups (two rows up from the bottom).
    static let lane = 2

    /// A note this close to a wake-up sits one lane higher, so the two don't cover each other.
    static let crowding: TimeInterval = 20 * 60

    /// How much of the note the marker's label (VoiceOver, the peek card, a scrub landing on it)
    /// carries. The callout shows up to `MarkerCallout.noteLimit`, the Logbook all of it.
    static let excerptLimit = 60

    /// Which lane a note at `date` sits in, given when wake-ups were logged.
    static func lane(at date: Date, wakes: [Date]) -> Int {
        wakes.contains { abs($0.timeIntervalSince(date)) < crowding } ? lane + 1 : lane
    }

    /// The note's first line, trimmed, cut at `excerptLimit` characters with an ellipsis. Nil when
    /// there's no text, which is never drawn.
    static func excerpt(_ raw: String) -> String? {
        guard let first = raw.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        guard first.count > excerptLimit else { return first }
        return first.prefix(excerptLimit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// "Note at 3:05 pm: Felt shaky after the walk": the marker's one line. Nil for an empty note.
    static func label(_ raw: String, at date: Date, calendar: Calendar = .autoupdatingCurrent) -> String? {
        excerpt(raw).map { "Note at \(ClockLabel.time(date, calendar: calendar)): \($0)" }
    }
}
