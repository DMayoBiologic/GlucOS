import Foundation

// The order of the Insights cards, and which ones are hidden (docs/InsightsLayout.md). iPhone and
// Mac each keep their own, because the two screens have different cards and a person may want
// different things up top on each. Each screen's layout syncs with the logbook, so another iPhone
// (or a reinstall) gets the iPhone order back, and another Mac gets the Mac one.

/// One card on an Insights screen that can be moved or hidden. The raw values are what's stored,
/// so they never change once shipped.
enum InsightsCard: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    /// iPhone: time in range over 24 hours to 14 days.
    case glance
    /// iPhone: each of the last seven days as a column.
    case days
    case weekInReview
    case lows
    case highs
    case overnight
    case weekdayWeekend
    /// Days in a row at 70% or more in range: the current run and the longest.
    case streaks
    /// The period's best and toughest days by time in range, each as a small day chart.
    case bestDays
    /// Time in range and the average in the 4 hours after each tag, against the period. Shows only
    /// once something carries a tag.
    case tags
    case dayPattern
    /// Time in range for each hour of the clock, as a strip of 24 cells; tapping one opens the
    /// Logbook on that hour across the period's days.
    case hourlyInRange
    /// iPhone: what GlucOS has learnt about mornings.
    case mornings
    case forecastAccuracy

    var id: String { rawValue }

    /// The name in the Edit list and the customise sheet, and for VoiceOver.
    var title: String {
        switch self {
        case .glance: return "At a glance"
        case .days: return "Day by day"
        case .weekInReview: return "Week in review"
        case .lows: return "Lows"
        case .highs: return "Highs"
        case .overnight: return "Overnight"
        case .weekdayWeekend: return "Weekdays and weekends"
        case .streaks: return "In-range streaks"
        case .bestDays: return "Best and toughest days"
        case .tags: return "Tags"
        case .dayPattern: return "Your usual day"
        case .hourlyInRange: return "Time in range by hour"
        case .mornings: return "Mornings"
        case .forecastAccuracy: return "Forecast accuracy"
        }
    }

    /// SF Symbol shown beside the title in the Edit list.
    var systemImage: String {
        switch self {
        case .glance: return "chart.pie"
        case .days: return "calendar"
        case .weekInReview: return "arrow.left.arrow.right"
        case .lows: return "arrow.down.to.line"
        case .highs: return "arrow.up.to.line"
        case .overnight: return "moon.stars"
        case .weekdayWeekend: return "calendar.day.timeline.left"
        case .streaks: return "flame"
        case .bestDays: return "rosette"
        case .tags: return "tag"
        case .dayPattern: return "clock"
        case .hourlyInRange: return "square.grid.4x3.fill"
        case .mornings: return "sunrise"
        case .forecastAccuracy: return "scope"
        }
    }

    /// The iPhone Insights screen's cards, in the order they ship.
    static let phoneDefault: [InsightsCard] = [
        .glance, .days, .weekInReview, .lows, .highs, .overnight, .weekdayWeekend, .streaks,
        .bestDays, .tags, .dayPattern, .hourlyInRange, .mornings, .forecastAccuracy,
    ]

    /// The Mac Dashboard Insights page's movable cards, in the order they ship. The logging cards
    /// (insulin action, meals, sites) stay fixed above them: they depend on the therapy setting and
    /// read as one block.
    static let macDefault: [InsightsCard] = [
        .weekInReview, .lows, .highs, .overnight, .weekdayWeekend, .streaks, .bestDays, .tags,
        .dayPattern, .hourlyInRange, .forecastAccuracy,
    ]
}

/// Which Insights screen a layout belongs to. Each one syncs as its own logbook record.
enum InsightsScreen: String, CaseIterable, Codable, Hashable, Sendable {
    case phone
    case mac

    /// The screen's movable cards, in the order they ship.
    var defaults: [InsightsCard] {
        switch self {
        case .phone: return InsightsCard.phoneDefault
        case .mac: return InsightsCard.macDefault
        }
    }

    /// Where builds before syncing kept this screen's layout (UserDefaults). Read once and moved
    /// into the logbook.
    var legacyKey: String {
        switch self {
        case .phone: return InsightsLayout.phoneKey
        case .mac: return InsightsLayout.macKey
        }
    }

    /// The fixed id of this screen's synced record (kind `insightsLayout`). Never changes.
    var recordID: UUID {
        switch self {
        case .phone: return UUID(uuidString: "1A5E7C0D-0000-4C0B-8A1E-000000000001")!
        case .mac: return UUID(uuidString: "1A5E7C0D-0000-4C0B-8A1E-000000000002")!
        }
    }

    init?(recordID: UUID) {
        guard let screen = Self.allCases.first(where: { $0.recordID == recordID }) else { return nil }
        self = screen
    }
}

/// One screen's layout as the logbook syncs it. The screen travels in the payload too, so a record
/// can be read without its id.
struct SyncedInsightsLayout: Codable, Equatable, Sendable {
    var screen: String
    var order: [String]
    var hidden: [String]

    init(screen: InsightsScreen, layout: InsightsLayout) {
        self.screen = screen.rawValue
        order = layout.order
        hidden = layout.hidden.sorted()
    }

    var layout: InsightsLayout { InsightsLayout(order: order, hidden: Set(hidden)) }
}

/// What a person has chosen: the order they put the cards in and the ones they hid. Stored as raw
/// strings so a card a newer build added, or an older build doesn't know, survives a round trip.
struct InsightsLayout: Codable, Equatable, Sendable {
    /// Every card the person has placed, hidden ones included, so a restored card returns to where
    /// it was.
    var order: [String]
    var hidden: Set<String>

    /// Nothing chosen yet: the shipped order, everything showing.
    static let standard = InsightsLayout(order: [], hidden: [])

    var isStandard: Bool { order.isEmpty && hidden.isEmpty }

    /// The screen's cards in the person's order. A card they've never seen (shipped after they last
    /// edited) shows, slotted in after the card it follows in `defaults`, so a new card lands
    /// near its neighbours instead of at the bottom. Stored names no longer on this screen drop out.
    func arranged(_ defaults: [InsightsCard]) -> [InsightsCard] {
        var out: [InsightsCard] = []
        var seen = Set<InsightsCard>()
        for raw in order {
            if let card = InsightsCard(rawValue: raw), defaults.contains(card), seen.insert(card).inserted {
                out.append(card)
            }
        }
        for (i, card) in defaults.enumerated() where !seen.contains(card) {
            // After the nearest card before it in the shipped order that's already placed.
            let anchor = defaults[..<i].reversed().first { out.contains($0) }
            let at = anchor.flatMap { a in out.firstIndex(of: a).map { $0 + 1 } } ?? 0
            out.insert(card, at: at)
            seen.insert(card)
        }
        return out
    }

    /// The cards that show, in order.
    func visible(_ defaults: [InsightsCard]) -> [InsightsCard] {
        arranged(defaults).filter { !hidden.contains($0.rawValue) }
    }

    /// The hidden cards, in the order they'd show if restored.
    func hiddenCards(_ defaults: [InsightsCard]) -> [InsightsCard] {
        arranged(defaults).filter { hidden.contains($0.rawValue) }
    }

    func isHidden(_ card: InsightsCard) -> Bool { hidden.contains(card.rawValue) }

    // MARK: Changes

    /// Moves showing cards the way SwiftUI's `onMove` reports it: `offsets` into `visible`, and the
    /// index in `visible` before which they land. Hidden cards keep their places in the full order.
    mutating func moveVisible(fromOffsets offsets: IndexSet, toOffset destination: Int,
                              defaults: [InsightsCard]) {
        let full = arranged(defaults)
        var shown = full.filter { !isHidden($0) }
        let moving = offsets.sorted().filter { $0 < shown.count }.map { shown[$0] }
        guard !moving.isEmpty else { return }
        let before = offsets.filter { $0 < destination }.count
        shown.removeAll { moving.contains($0) }
        let at = min(max(destination - before, 0), shown.count)
        shown.insert(contentsOf: moving, at: at)
        // Fill the slots the showing cards held with their new order.
        var next = shown.makeIterator()
        setOrder(full.map { card in isHidden(card) ? card : (next.next() ?? card) })
    }

    /// One place up (`by: -1`) or down (`by: 1`) among the showing cards: the context menu and the
    /// VoiceOver actions. Does nothing at either end.
    mutating func move(_ card: InsightsCard, by step: Int, defaults: [InsightsCard]) {
        let shown = visible(defaults)
        guard let i = shown.firstIndex(of: card) else { return }
        let target = i + step
        guard target >= 0, target < shown.count else { return }
        moveVisible(fromOffsets: IndexSet(integer: i), toOffset: step > 0 ? target + 1 : target, defaults: defaults)
    }

    /// One place up or down among the cards actually on screen, when the screen leaves some showing
    /// cards out (the Tags card before anything is tagged): it swaps with the next card the person
    /// can see, and a card left out keeps its slot beside its own neighbour.
    mutating func move(_ card: InsightsCard, by step: Int, defaults: [InsightsCard],
                       onScreen: (InsightsCard) -> Bool) {
        let all = visible(defaults)
        let shown = all.filter(onScreen)
        guard let i = shown.firstIndex(of: card) else { return }
        let target = i + step
        guard target >= 0, target < shown.count,
              let from = all.firstIndex(of: card), let to = all.firstIndex(of: shown[target]) else { return }
        moveVisible(fromOffsets: IndexSet(integer: from), toOffset: step > 0 ? to + 1 : to, defaults: defaults)
    }

    mutating func hide(_ card: InsightsCard, defaults: [InsightsCard]) {
        pinOrder(defaults)
        hidden.insert(card.rawValue)
    }

    /// Back where it was before it was hidden.
    mutating func restore(_ card: InsightsCard, defaults: [InsightsCard]) {
        pinOrder(defaults)
        hidden.remove(card.rawValue)
    }

    /// Writes the current order down, so a card added later still counts as new.
    private mutating func pinOrder(_ defaults: [InsightsCard]) {
        setOrder(arranged(defaults))
    }

    /// Stored names this screen doesn't show (a newer build's card, after going back a version)
    /// stay at the end, so going forward again keeps them where they were put.
    private mutating func setOrder(_ cards: [InsightsCard]) {
        let placed = cards.map(\.rawValue)
        let known = Set(placed)
        var kept = Set<String>()
        let unknown = order.filter { !known.contains($0) && kept.insert($0).inserted }
        order = placed + unknown
    }

    // MARK: Storage

    /// The JSON builds before syncing kept in UserDefaults. Empty means nothing chosen yet.
    var stored: String {
        guard !isStandard, let data = try? JSONEncoder().encode(Stored(order: order, hidden: hidden.sorted())),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// Reads `stored` back. Anything unreadable is the standard layout rather than an error.
    init(stored text: String) {
        guard let data = text.data(using: .utf8), let s = try? JSONDecoder().decode(Stored.self, from: data) else {
            self = .standard
            return
        }
        self.init(order: s.order, hidden: Set(s.hidden))
    }

    init(order: [String], hidden: Set<String>) {
        self.order = order
        self.hidden = hidden
    }

    private struct Stored: Codable {
        var order: [String]
        var hidden: [String]
    }

    /// The UserDefaults keys builds before syncing used, one per screen (`InsightsScreen.legacyKey`).
    static let phoneKey = "insights.layout.phone"
    static let macKey = "insights.layout.mac"
}
