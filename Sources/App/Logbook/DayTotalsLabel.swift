import SwiftUI

extension LogbookDayTotals {
    /// A day's insulin, carbs and entry count, from what was logged that day (alerts aren't
    /// entries and never reach here). The same sums the headers already showed.
    init(_ entries: [LogEntry]) {
        self.init()
        for e in entries {
            switch e {
            case .dose(let d): units += d.units
            case .meal(let m): carbs += m.carbs
            case .siteChange, .context: break
            }
        }
        self.entries = entries.count
    }

    /// Each day's totals, keyed by local midnight.
    static func byDay(_ entries: [LogEntry], calendar: Calendar = .autoupdatingCurrent) -> [Date: LogbookDayTotals] {
        Dictionary(grouping: entries) { calendar.startOfDay(for: $0.timestamp) }.mapValues { LogbookDayTotals($0) }
    }

    /// "14 u · 120 g", only the parts that were logged: the Mac's Day cell, where room is short.
    var compact: String {
        var parts: [String] = []
        if units > 0 { parts.append(LogFormat.units(units)) }
        if carbs > 0 { parts.append(LogFormat.grams(carbs)) }
        return parts.joined(separator: " · ")
    }
}

/// A Logbook day header's totals ("14 u · 120 g carbs", or "4 entries · …" on a folded day) that
/// roll to their new values when an entry is added, edited, deleted or undone: the digits turn
/// over on the `.arrival` spring, upward as the day grows and downward as it shrinks
/// (`DayTotalsRoll`). A header the list rebuilt starts from what this day last showed
/// (`DayTotalsMemory`), so it rolls too rather than jumping. Instant under Reduce Motion.
///
/// VoiceOver hears the new totals once per change ("Today now 14 units, 120 grams of carbs,
/// 4 entries"), at low priority so the undo toast or "Saved" speaks first. The label itself
/// says nothing: the header it sits in carries the totals in its own label and value.
struct DayTotalsLabel: View {
    let id: String
    let text: String
    let totals: LogbookDayTotals
    /// "Today", "Tuesday 12 November": how the announcement names the day.
    let spokenDay: String
    let memory: DayTotalsMemory

    @State private var shown: String
    @State private var countsDown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(id: String, text: String, totals: LogbookDayTotals, spokenDay: String, memory: DayTotalsMemory) {
        self.id = id
        self.text = text
        self.totals = totals
        self.spokenDay = spokenDay
        self.memory = memory
        _shown = State(initialValue: memory.lastText(id) ?? text)
    }

    var body: some View {
        Text(shown)
            .contentTransition(reduceMotion ? .identity : .numericText(countsDown: countsDown))
            .onAppear { take() }
            .onChange(of: text) { take() }
            .onChange(of: totals) { take() }
            .accessibilityHidden(true)
    }

    private func take() {
        let old = memory.record(id, totals: totals, text: text)
        let change = DayTotalsRoll.between(old, totals, reduceMotion: reduceMotion)
        switch change {
        case .none:
            // A fold or open changes the words, not the totals: it moves with the fold itself.
            if shown != text { shown = text }
        case .instant:
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { shown = text }
        case .roll(let down):
            countsDown = down
            withAnimation(DSMotion.arrival.animation) { shown = text }
        }
        if change.announces, memory.mayAnnounce(at: Date()) {
            LoggedElsewhere.announce(DayTotalsText.announcement(day: spokenDay, totals))
        }
    }
}
