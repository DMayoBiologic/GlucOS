import Foundation

/// How the main reading on the app's own screens (the Mac popover, iPhone Today and its collapsed
/// title) changes from one reading to the next, kept free of SwiftUI so it can be unit-tested.
///
/// A new figure rolls its digits over to the new value on the quick `.arrival` spring. When the
/// reading also crosses a range edge, the figure and its colour move together on the slower
/// `.sweep` fade instead, so the colour isn't hurried along by the roll. Each plays once per
/// change and never repeats. Under Reduce Motion the figure and colour simply change.
///
/// `Band` is whatever names the reading's colour (the design system's `Tone`).
enum ReadingRoll: Equatable, Sendable {
    /// Nothing about the figure changed.
    case none
    /// A new figure in the same range: the digits roll on `.arrival`.
    case roll
    /// The colour changed (a range edge crossed): figure and colour together on `.sweep`.
    case recolour
    /// Reduce Motion: the new figure and colour replace the old at once.
    case instant

    static func between<Band: Equatable>(from old: (mgdl: Double, band: Band)?,
                                         to new: (mgdl: Double, band: Band),
                                         reduceMotion: Bool) -> ReadingRoll {
        guard let old else { return .none }
        let bandChanged = old.band != new.band
        guard old.mgdl != new.mgdl || bandChanged else { return .none }
        if reduceMotion { return .instant }
        return bandChanged ? .recolour : .roll
    }
}
