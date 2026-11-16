import Foundation

/// The Mac popover's opening choreography, kept free of SwiftUI so it can be unit-tested.
///
/// Each time the popover opens, its sections fade and rise into place one after another, top to
/// bottom, once. Only the sections that are showing take a turn, so a popover without notices or
/// prompts doesn't pause where they would be. The chart's forecast waits for its card to be most
/// of the way in before it draws in, so the two read as one movement rather than two at once.
/// Nothing repeats while the popover stays open (docs/Redesign.md §4.6), and under Reduce Motion
/// everything is simply there.
enum PopoverStagger {
    /// The popover's sections, in the order they're laid out and come in.
    enum Section: Int, CaseIterable, Sendable {
        /// The reading, or the "waiting" / "connect" card when there is none.
        case hero
        case notices
        /// Dose, low and wake prompts: they come in together.
        case prompts
        case chart
        case summary
        case toolbar
        case footer
    }

    /// Between one section starting and the next.
    static let step: TimeInterval = 0.045
    /// How long each section takes to fade and rise.
    static let duration: TimeInterval = 0.32
    /// How far below its place a section starts, in points.
    static let rise: Double = 8
    /// How far through the chart card's rise the forecast starts drawing in.
    static let forecastLead: Double = 0.6

    /// The section's turn among the ones that are showing (0 = first), or nil when it isn't
    /// showing. The hero always counts, since its slot holds the empty state when there's no
    /// reading.
    static func order(of section: Section, showing: Set<Section>) -> Int? {
        let present = showing.union([.hero])
        guard present.contains(section) else { return nil }
        return Section.allCases.filter { $0.rawValue < section.rawValue && present.contains($0) }.count
    }

    /// When the section starts coming in, in seconds after the popover opens.
    static func delay(of section: Section, showing: Set<Section>) -> TimeInterval {
        Double(order(of: section, showing: showing) ?? 0) * step
    }

    /// When the last section has settled. The whole opening stays under half a second or so.
    static func settled(showing: Set<Section>) -> TimeInterval {
        let last = Section.allCases.compactMap { order(of: $0, showing: showing) }.max() ?? 0
        return Double(last) * step + duration
    }

    /// When the chart's forecast should start drawing in: part way through the chart card's rise,
    /// so the line grows out of a card that's already where it belongs.
    static func forecastDelay(showing: Set<Section>) -> TimeInterval {
        guard order(of: .chart, showing: showing) != nil else { return 0 }
        return delay(of: .chart, showing: showing) + duration * forecastLead
    }

    /// Which way the summary card's content slides when its period changes: +1 when moving to a
    /// longer period (the new one comes in from the trailing edge, the old one leaves the other
    /// way), -1 for a shorter one, 0 when nothing changed. Periods are compared by their length in
    /// hours.
    static func slideDirection(fromHours old: Int, toHours new: Int) -> Int {
        new == old ? 0 : (new > old ? 1 : -1)
    }

    /// How far, in points, the outgoing and incoming summary content travel when the period changes.
    static let slideDistance: Double = 18
}
