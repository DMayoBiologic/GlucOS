import Foundation

/// Peeking at something logged on the glucose chart: touch and hold a marker on iPhone Today, or
/// hover one in the Mac popover, and a small card shows what it was, how long ago, and the reading
/// nearest that moment. Letting go (or moving the pointer away) puts it away. Plain Foundation so it
/// can be unit-tested; `GlucoseChart` draws it.
///
/// How it shares the chart with the other touches (docs/DesignSystem.md, rule 8):
/// - A hold on a marker wins. It's recognised after `holdDuration`, sooner than the system's
///   touch-and-hold menu, and while it's held the yesterday-line menu stands down, so holding a
///   marker never opens that menu. A hold anywhere else still opens it, as before.
/// - Moving the finger before the hold is recognised is a scrub, as before. Once a peek is showing,
///   the scrub readout stays hidden until the finger lifts, so the two never sit on top of each other.
/// - A marker popping in is not peekable until it lands.
enum MarkerPeek {
    /// How long a finger stays on a marker before it peeks. The system's touch-and-hold menu takes
    /// about half a second, so this always comes first.
    static let holdDuration: TimeInterval = 0.3
    /// How far the finger may drift while holding before it's a scrub instead, in points.
    static let holdSlop: Double = 10
    /// How far from a marker's centre still counts as on it, in points. Markers are 16 points
    /// across; this gives a fingertip-sized target without reaching the next lane (about 20 points
    /// apart on the smallest chart) from the middle of a marker.
    static let hitRadius: Double = 22
    /// The nearest reading counts as "at the time" within this, as with the scrub readout.
    static let readingTolerance: TimeInterval = 10 * 60

    /// A marker where the chart draws it, in the chart's own points.
    struct Spot: Equatable {
        var id: UUID
        var x: Double
        var y: Double
    }

    /// The marker under `point`: the nearest within `radius`, or `nil`. Two markers equally near
    /// go to the first listed, so the result never flips between them.
    static func hit(x: Double, y: Double, in spots: [Spot], radius: Double = hitRadius) -> UUID? {
        var best: (id: UUID, d: Double)?
        for s in spots {
            let d = ((s.x - x) * (s.x - x) + (s.y - y) * (s.y - y)).squareRoot()
            guard d <= radius else { continue }
            if best == nil || d < best!.d { best = (s.id, d) }
        }
        return best?.id
    }

    /// Whether a finger that moved `dx`, `dy` since it went down is still holding still.
    static func isHolding(dx: Double, dy: Double) -> Bool {
        (dx * dx + dy * dy).squareRoot() <= holdSlop
    }

    /// The reading nearest `date`, when there is one close enough.
    static func reading(near date: Date, in readings: [GlucoseReading]) -> GlucoseReading? {
        let distance = { (r: GlucoseReading) in abs(r.timestamp.timeIntervalSince(date)) }
        guard let best = readings.min(by: { distance($0) < distance($1) }),
              distance(best) <= readingTolerance else { return nil }
        return best
    }

    /// "Just now", "25 min ago", "2 h 5 min ago". Something logged ahead of now (a clock change, a
    /// time typed a little ahead) says "Soon".
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < -60 { return "Soon" }
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 1 { return "Just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h ago" : "\(h) h \(m) min ago"
    }

    /// The card's second line: "25 min ago · 7.2 mmol/L then", or just the time when there was no
    /// reading near it (sensor warm-up, out of signal).
    static func detail(date: Date, now: Date, readings: [GlucoseReading], unit: GlucoseUnit) -> String {
        let when = ago(date, now: now)
        guard let r = reading(near: date, in: readings) else { return when }
        return "\(when) · \(unit.format(mgdl: r.mgdl, withUnit: true)) then"
    }

    /// The note shown in the peek, longest first cut: one paragraph, at most this many characters.
    /// The whole note is in the callout a click opens, and in the Logbook.
    static let noteLimit = 80

    /// The note on the peek's third line: newlines folded to spaces, trimmed, capped at `noteLimit`
    /// with an ellipsis. Nil for no note, and for a plain note (`readsNote`), whose title already
    /// is the note.
    static func note(_ content: MarkerCallout.Content?) -> String? {
        guard let content, !content.readsNote, let raw = content.note else { return nil }
        let text = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !text.isEmpty else { return nil }
        guard text.count > noteLimit else { return text }
        return text.prefix(noteLimit - 1).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// The Mac peek's last line, when a click opens the callout: ⌘-click goes straight to the
    /// Logbook instead.
    static let macHint = "Click for details \u{00B7} \u{2318}-click opens Logbook"

    /// VoiceOver's name for going straight to the entry, on each marker's button.
    static let openInLogbookActionName = "Open in Logbook"
}
