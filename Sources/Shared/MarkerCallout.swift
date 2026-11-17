import Foundation

/// A tap (iPhone Today) or click (Mac popover) on a logged marker opens a small callout that springs
/// out of it: what kind of entry it was, the amount, when, any note, and an Open in Logbook button.
/// It stays until a tap elsewhere on the chart, Esc, a tap on the same marker, or the marker leaving
/// the chart. Plain Foundation so it can be unit-tested; `GlucoseChart` draws it.
///
/// How it shares the chart with the other touches (docs/DesignSystem.md, rule 8):
/// - A finger that lifts off a marker before `MarkerPeek.holdDuration`, without sliding off it, is a
///   tap. Held longer it's a peek, as before; moved first, it's a scrub, as before.
/// - While a callout is open the hover peek stands down, and a tap or a scrub starting anywhere
///   else on the chart only closes it. A hold on another marker still peeks it (iPhone).
/// - It only repeats what was logged. No insulin on board, no carbs left, nothing worked out.
enum MarkerCallout {
    /// What the callout says. Built by `ChartLogMarker.logbook` from the entry itself.
    struct Content: Equatable, Sendable {
        /// "Insulin", "Meal", "Treatment", "Woke up".
        var title: String
        /// "4 u Novorapid", "45 g · Toast", or nil when nothing was logged with it.
        var amount: String?
        /// The note as typed, trimmed. Nil when there isn't one.
        var note: String?

        init(title: String, amount: String? = nil, note: String? = nil) {
            self.title = title
            let amount = amount?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.amount = (amount?.isEmpty ?? true) ? nil : amount
            self.note = MarkerCallout.note(note ?? "")
        }
    }

    /// Longer notes are cut here, with an ellipsis; the whole note is one tap away in the Logbook.
    static let noteLimit = 140

    /// The note as typed, trimmed, with runs of blank lines folded to one line break, capped at
    /// `noteLimit` characters. Nil when it's empty.
    static func note(_ raw: String) -> String? {
        let lines = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let text = lines.joined(separator: "\n")
        guard text.count > noteLimit else { return text }
        let cut = text.prefix(noteLimit - 1).trimmingCharacters(in: .whitespacesAndNewlines)
        return cut + "…"
    }

    /// "4 u Novorapid", with "· Pump" when it came from a pump. `units` is already formatted.
    static func doseAmount(units: String, name: String, viaPump: Bool) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = name.isEmpty ? units : "\(units) \(name)"
        return viaPump ? "\(head) · Pump" : head
    }

    /// "45 g · Toast", "45 g", "Toast", or nil. `grams` is already formatted, nil for no carbs.
    static func mealAmount(grams: String?, food: String) -> String? {
        let food = food.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (grams, food.isEmpty) {
        case (let g?, false): return "\(g) · \(food)"
        case (let g?, true): return g
        case (nil, false): return food
        case (nil, true): return nil
        }
    }

    /// "12:56 pm · 25 min ago".
    static func timeLine(_ date: Date, now: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        "\(ClockLabel.time(date, calendar: calendar)) · \(MarkerPeek.ago(date, now: now))"
    }

    /// A finger that went down on a marker and lifted after `heldFor` seconds, having moved `dx`,
    /// `dy`: a tap when it lifted before the peek would have shown and never slid off.
    static func isTap(heldFor: TimeInterval, dx: Double, dy: Double) -> Bool {
        heldFor < MarkerPeek.holdDuration && MarkerPeek.isHolding(dx: dx, dy: dy)
    }

    /// The callout open after a tap on `tapped` while `open` was showing: the same marker closes
    /// it, another one moves it there.
    static func toggled(open: UUID?, tapped: UUID) -> UUID? {
        open == tapped ? nil : tapped
    }

    /// Where the card sits across the chart: centred over the marker, kept inside the plot. All in
    /// the same points; a plot narrower than the card centres it on the plot.
    static func centerX(markerX: Double, plotMinX: Double, plotMaxX: Double, width: Double) -> Double {
        let half = width / 2
        guard plotMaxX - plotMinX > width else { return (plotMinX + plotMaxX) / 2 }
        return min(max(markerX, plotMinX + half), plotMaxX - half)
    }

    /// The point the card grows from, across its own width (0 is its left edge, 1 its right): over
    /// the marker, so it springs out of it even when it's been pushed in from the chart's edge.
    static func anchorX(markerX: Double, centerX: Double, width: Double) -> Double {
        guard width > 0 else { return 0.5 }
        return min(max((markerX - (centerX - width / 2)) / width, 0), 1)
    }

    /// For VoiceOver, on the marker's button: "Meal, 45 grams, Toast, 12:56 pm, has a note".
    static func spoken(_ content: Content, date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        var parts = [content.title]
        if let amount = content.amount { parts.append(spokenAmount(amount)) }
        parts.append(ClockLabel.time(date, calendar: calendar))
        if content.note != nil { parts.append("has a note") }
        return parts.joined(separator: ", ")
    }

    /// "4 u Novorapid · Pump" → "4 units Novorapid, Pump", "45 g · Toast" → "45 grams, Toast".
    static func spokenAmount(_ amount: String) -> String {
        amount.components(separatedBy: " · ").map { part in
            var words = part.components(separatedBy: " ")
            if words.count >= 2 {
                let one = words[0] == "1"
                if words[1] == "u" { words[1] = one ? "unit" : "units" }
                if words[1] == "g" { words[1] = one ? "gram" : "grams" }
            }
            return words.joined(separator: " ")
        }.joined(separator: ", ")
    }
}
