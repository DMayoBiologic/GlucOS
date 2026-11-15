import Foundation

/// The rules behind a Logbook row opening into its detail on the iPhone (docs/Redesign.md §7.2).
/// Plain Foundation so `swift test` covers them; the card itself is `PhoneLogbookDetail` in the
/// iPhone app.
///
/// Tapping a row grows a card out of the row's own frame, in place, to its full height; closing
/// shrinks it back into the row. Everything is driven by one `progress` value, 0 (the row) to 1
/// (the open card), animated by a spring. A spring keeps its speed when its target changes, so
/// tapping again mid-flight turns the card round from where it is, and a drag down to close moves
/// the same value under the finger. It plays once per tap and holds still once settled: no timers,
/// nothing repeating (power audit #94). Under Reduce Motion nothing moves: the open card fades in
/// over the list in its final place and fades out again.
enum LogbookRowExpand {
    /// How the card gets from the row to open.
    enum Style: Equatable {
        /// The card grows out of the row's frame and shrinks back into it.
        case matched
        /// Reduce Motion: the open card fades in and out where it sits.
        case crossFade

        init(reduceMotion: Bool) { self = reduceMotion ? .crossFade : .matched }
    }

    /// Space kept between the open card and the edges of the list.
    static let margin: Double = 12
    /// The open card's corner radius. The row has square corners, so it rounds as it opens.
    static let cornerRadius: Double = 22
    /// The card's padding once open. Zero at the row, so the row's text starts where it was.
    static let padding: Double = 16
    /// How dark the list gets behind the open card.
    static let scrimOpacity: Double = 0.22
    /// Dragging down this far takes the card all the way back to the row.
    static let dragRange: Double = 320
    /// Letting go after dragging (or flicking, by the predicted end) this far down closes the card.
    static let closeDistance: Double = 90

    /// Where the open card sits in a container of `size`: the full width less the margins, its
    /// natural height (capped so it fits), as near the row's own top as fits, so it opens in place
    /// rather than jumping to the top of the screen.
    static func openFrame(row: CGRect, contentHeight: Double, in size: CGSize) -> CGRect {
        let width = max(0, Double(size.width) - 2 * margin)
        let room = max(0, Double(size.height) - 2 * margin)
        let natural = contentHeight.isFinite && contentHeight > 0 ? contentHeight : Double(row.height)
        let height = min(max(natural, Double(row.height)), room)
        let wanted = Double(row.minY) - padding
        let top = min(max(wanted, margin), max(margin, Double(size.height) - margin - height))
        return CGRect(x: margin, y: top, width: width, height: height)
    }

    /// The card's frame part way between the row (0) and open (1). Not clamped: a spring may carry
    /// it a little past open and back, and that should show.
    static func frame(row: CGRect, open: CGRect, progress: Double) -> CGRect {
        let p = progress.isFinite ? progress : 0
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * CGFloat(p) }
        return CGRect(x: mix(row.minX, open.minX), y: mix(row.minY, open.minY),
                      width: max(0, mix(row.width, open.width)), height: max(0, mix(row.height, open.height)))
    }

    /// Progress clamped to 0…1, for things that mustn't overshoot (opacities, padding).
    static func clamped(_ progress: Double) -> Double {
        guard progress.isFinite else { return 0 }
        return min(1, max(0, progress))
    }

    /// The details under the row's line: hidden until the card has some room, then in by about
    /// nine tenths of the way, so they never squash into the row's height.
    static func detailOpacity(progress: Double) -> Double {
        let p = clamped(progress)
        return min(1, max(0, (p - 0.35) / 0.55))
    }

    /// How dark the list is behind the card.
    static func scrim(progress: Double) -> Double { scrimOpacity * clamped(progress) }

    static func corner(progress: Double) -> Double { cornerRadius * clamped(progress) }

    static func inset(progress: Double) -> Double { padding * clamped(progress) }

    /// Where a drag down leaves the card: 1 at rest, falling as the finger goes down, never below 0.
    /// Dragging up does nothing.
    static func dragProgress(translation: Double) -> Double {
        guard translation.isFinite, translation > 0 else { return 1 }
        return max(0, 1 - translation / dragRange)
    }

    /// Whether letting go of a drag closes the card or lets it settle back open.
    static func closesOnRelease(translation: Double, predictedEnd: Double) -> Bool {
        let t = translation.isFinite ? translation : 0
        let e = predictedEnd.isFinite ? predictedEnd : t
        return max(t, e) >= closeDistance
    }

    /// The row still open after the logbook changes: nil once that entry has gone (deleted here or
    /// on the Mac, or undone), so the card closes rather than showing something that isn't there.
    static func stillOpen(_ id: UUID?, among ids: [UUID]) -> UUID? {
        guard let id, ids.contains(id) else { return nil }
        return id
    }
}

/// What an opened Logbook row lists under its line: every field the entry has, in words. Read-only;
/// the amounts are shown exactly as logged.
enum LogbookEntryDetail {
    struct Line: Equatable {
        let label: String
        let value: String
        /// Words the user typed or picked (food, insulin and site names, notes), where the Logbook
        /// search's matches are picked out.
        var searchable = false
    }

    /// "Today 9:12 am · 2 h 10 min ago". The "ago" part only for the last day.
    static func when(_ date: Date, now: Date, calendar: Calendar = .autoupdatingCurrent,
                     locale: Locale = .autoupdatingCurrent) -> String {
        let at = ClockLabel.dayTime(date, now: now, calendar: calendar, locale: locale)
        let age = now.timeIntervalSince(date)
        guard age >= 60, age < 24 * 3600 else { return at }
        return "\(at) · \(LogFormat.duration(age)) ago"
    }

    static func lines(_ entry: LogEntry, site: InjectionSite?) -> [Line] {
        var out: [Line] = []
        switch entry {
        case .dose(let d):
            out.append(Line(label: "Amount", value: LogFormat.units(d.units)))
            let insulin = d.name.isEmpty ? d.kind.title : "\(d.name) (\(d.kind.title))"
            out.append(Line(label: "Insulin", value: insulin, searchable: true))
            if d.viaPump {
                out.append(Line(label: "Given by", value: "Pump"))
            } else if let s = d.site ?? site {
                out.append(Line(label: "Site", value: s.title, searchable: true))
            }
            if let purpose = d.purpose?.label { out.append(Line(label: "For", value: purpose)) }
            if let c = d.calculation {
                out.append(Line(label: "Calculator", value: "Suggested \(LogFormat.units(c.suggestedUnits))"))
            }
        case .meal(let m):
            out.append(Line(label: "Carbs", value: m.carbs > 0 ? LogFormat.grams(m.carbs) : "Not counted"))
            if !m.food.isEmpty { out.append(Line(label: "Food", value: m.food, searchable: true)) }
            for item in m.items ?? [] {
                var parts: [String] = []
                if let portion = item.portion, !portion.isEmpty { parts.append(portion) }
                parts.append(LogFormat.grams(item.grams))
                parts.append("\(LogFormat.grams(item.carbs)) carbs")
                out.append(Line(label: item.name, value: parts.joined(separator: " · "), searchable: true))
            }
        case .siteChange(let s):
            out.append(Line(label: "Site", value: s.site.title, searchable: true))
        case .context(let c):
            for tag in c.sortedTags { out.append(Line(label: tag.title, value: tag.help)) }
        }
        let note = entry.noteText
        if !note.isEmpty { out.append(Line(label: "Note", value: note, searchable: true)) }
        return out
    }
}

extension LogEntry {
    /// The entry's note, whatever its type.
    var noteText: String {
        switch self {
        case .dose(let d): return d.note
        case .meal(let m): return m.note
        case .siteChange(let s): return s.note
        case .context(let c): return c.note
        }
    }
}
