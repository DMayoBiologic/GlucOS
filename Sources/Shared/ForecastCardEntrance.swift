import Foundation

/// How the forecast details card (`ForecastDetails`, round 73) arrives and leaves (round 74), kept
/// free of SwiftUI so it can be unit-tested.
///
/// The card grows out of the forecast it describes: inside the popover, a strip as thin as the
/// dashed line (`lineHeight`) on the edge nearest the line widens into the whole card, tinted like
/// the chart's range band and settling to a faint wash, and the card's contents show as it opens.
/// Then the 30 and 60 minute figures roll from where the forecast starts to their own value, one
/// after the other, the numeric roll the log sheets' typed amounts use (`TypedAmountRoll`). Closing
/// runs it backwards: the figures roll back and the band narrows to the line before the popover goes.
/// Under Reduce Motion the contents cross-fade in and out, the band is simply there, and the
/// figures never roll.
///
/// Display only: the card's figures and VoiceOver's sentence are always the forecast's own; only
/// the text on its way there is ever anything else, and VoiceOver never hears it.
enum ForecastCardEntrance {
    enum Style: Equatable, Sendable {
        /// The band widens out of the line, then the figures roll in.
        case widen
        /// Reduce Motion: the contents fade, nothing moves.
        case crossFade

        init(reduceMotion: Bool) { self = reduceMotion ? .crossFade : .widen }
    }

    /// The strip the card opens from and closes to, as thick as the forecast's dashed line (points).
    static let lineHeight: Double = 2
    /// The band widening into the card.
    static let openDuration: TimeInterval = 0.34
    /// The band narrowing back to the line, and the figures rolling back with it.
    static let closeDuration: TimeInterval = 0.22
    /// Reduce Motion's fades.
    static let fadeInDuration: TimeInterval = 0.2
    static let fadeOutDuration: TimeInterval = 0.15
    /// When the first figure starts rolling, partway through the widening so it lands as the band
    /// settles, and the gap before the next.
    static let firstFigureDelay: TimeInterval = 0.14
    static let figureStagger: TimeInterval = 0.08
    /// The band's tint while it's still a line (the chart band's strongest), and once it's the card.
    static let lineTint: Double = 0.30
    static let cardTint: Double = 0.06

    /// When the figure in row `index` (0 = 30 min) starts rolling, from the card first showing.
    static func figureDelay(index: Int) -> TimeInterval {
        firstFigureDelay + Double(max(index, 0)) * figureStagger
    }

    /// How long the card plays before the popover is let go, so the close is seen.
    static func closeDuration(_ style: Style) -> TimeInterval {
        style == .widen ? closeDuration : fadeOutDuration
    }

    /// The opening's height for a card `full` points tall: the line while closed, the whole card
    /// open. Under Reduce Motion always the whole card.
    static func bandHeight(open: Bool, full: Double, style: Style) -> Double {
        guard style == .widen, !open else { return max(full, 0) }
        return min(lineHeight, max(full, 0))
    }

    /// The band's tint (opacity of the forecast band's colour).
    static func bandTint(open: Bool, style: Style) -> Double {
        style == .widen && !open ? lineTint : cardTint
    }

    /// The contents' opacity: only Reduce Motion fades them; otherwise the opening reveals them.
    static func contentOpacity(open: Bool, style: Style) -> Double {
        style == .crossFade && !open ? 0 : 1
    }

    /// The figure a row shows (mg/dL): where the forecast starts until its roll, its own value after.
    /// Under Reduce Motion always its own value.
    static func figure(_ h: ForecastDetails.Horizon, start: Double, rolledIn: Bool, style: Style) -> Double {
        style == .crossFade || rolledIn ? h.mgdl : start
    }

    /// Which way the digits roll: rolling in, down when the forecast falls from its start; rolling
    /// back out, the other way.
    static func countsDown(_ h: ForecastDetails.Horizon, start: Double, rollingIn: Bool) -> Bool {
        rollingIn ? h.mgdl < start : start < h.mgdl
    }

    /// Whether the card opens from its top edge: the popover sits below a point in the chart's top
    /// half (`ForecastPopoverAnchor`), so its top edge is the one nearest the line.
    static func opensFromTop(pointY: Double, plotMidY: Double) -> Bool { pointY < plotMidY }
}
