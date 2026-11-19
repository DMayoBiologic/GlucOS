import Foundation

/// Dragging the forecast details card (`ForecastDetailsCard`, round 73) down to put it away, on
/// iPhone (round 93), kept free of SwiftUI so it can be unit-tested.
///
/// The card follows the finger down, fading and shrinking a touch as it goes, and gives only a
/// little the wrong way. Let go past `distance`, or with a flick that would carry it past
/// `flickDistance`, and it drops the rest of the way out of the popover before the popover goes;
/// short of that it springs back. Under Reduce Motion the card never moves: it dims as the finger
/// travels, and a drag far enough closes it with the card's own cross-fade.
///
/// The card's figures and VoiceOver's sentence never change while it's dragged, and VoiceOver
/// keeps its escape gesture and Close action, since it can't drag.
enum ForecastCardDrag {
    /// Movement before the drag takes over, so a still touch on the card does nothing.
    static let minimumDistance: Double = 6
    /// How far down the card has to go to be put away, in points.
    static let distance: Double = 64
    /// A quick flick that would carry it at least this far puts it away too.
    static let flickDistance: Double = 150
    /// How much the card moves for a drag upward, the wrong way, and the most it ever gives.
    static let upwardGive: Double = 0.2
    static let upwardLimit: Double = 12
    /// How much of its opacity, and of its size, the card has lost by `distance`.
    static let fadeAtDistance: Double = 0.45
    static let shrinkAtDistance: Double = 0.04
    /// The drop out of the popover once it's let go far enough.
    static let dropDuration: TimeInterval = 0.18
    /// How far past the card's own height it drops, so it's well clear before the popover goes.
    static let dropOvershoot: Double = 24

    /// Where the card sits for a drag of `dy` points down (negative: up). Still under Reduce Motion.
    static func offset(_ dy: Double, style: ForecastCardEntrance.Style) -> Double {
        guard style == .widen else { return 0 }
        return dy >= 0 ? dy : max(dy * upwardGive, -upwardLimit)
    }

    /// How far toward being put away the drag is: 0 at rest (or dragged up), 1 at `distance`.
    static func progress(_ dy: Double) -> Double {
        min(max(dy / distance, 0), 1)
    }

    /// The card's opacity while dragged. Dims under Reduce Motion too, as the only cue.
    static func opacity(_ dy: Double) -> Double {
        1 - fadeAtDistance * progress(dy)
    }

    /// The card's scale while dragged. Always 1 under Reduce Motion.
    static func scale(_ dy: Double, style: ForecastCardEntrance.Style) -> Double {
        style == .widen ? 1 - shrinkAtDistance * progress(dy) : 1
    }

    /// Whether a drag that ended `dy` points down, and would have carried on to `predicted`, puts
    /// the card away. A flick only counts going down.
    static func dismisses(_ dy: Double, predicted: Double) -> Bool {
        dy >= distance || (dy > 0 && predicted >= flickDistance)
    }

    /// Where the card drops to once let go, for a card `height` points tall: past its own bottom,
    /// and never back up from where the finger left it.
    static func dropOffset(from dy: Double, height: Double) -> Double {
        max(dy, max(height, 0) + dropOvershoot)
    }
}
