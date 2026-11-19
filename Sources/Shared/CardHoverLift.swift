import Foundation

// Mac Insights cards lift a touch while the pointer rests on them (round 94): the card grows to
// 1.01x and a soft shadow fades in under it over 0.15 s, then both settle back when the pointer
// leaves. Driven only by hover, so nothing runs while the pointer is still and nothing repeats.
// Under Reduce Motion the card keeps its size and only the shadow fades (a fade moves nothing).
// Under Increase Contrast there is no shadow, as with every other GlucOS shadow, so the card only
// grows. The lift sits inside the card's rise-in, so a pointer resting there as the page opens
// never shows a shadow before its card.

enum CardHoverLift {
    /// How far a hovered card grows.
    static let scale = 1.01
    /// How long it takes to lift or settle.
    static let duration = 0.15
    /// The shadow under a lifted card.
    static let shadowOpacity = 0.14
    static let shadowRadius = 14.0
    static let shadowY = 6.0

    struct Look: Equatable, Sendable {
        var scale: Double
        var shadowOpacity: Double

        static let resting = Look(scale: 1, shadowOpacity: 0)
    }

    /// How a card looks for the pointer and the person's accessibility settings.
    static func look(hovering: Bool, reduceMotion: Bool, increasedContrast: Bool) -> Look {
        guard hovering else { return .resting }
        return Look(scale: reduceMotion ? 1 : scale, shadowOpacity: increasedContrast ? 0 : shadowOpacity)
    }

    /// The card the pointer is over after `card` reports `hovering`. A late "left" from the card
    /// the pointer came from never clears the card it has just moved onto.
    static func hovered<ID: Equatable>(_ current: ID?, card: ID, hovering: Bool) -> ID? {
        if hovering { return card }
        return current == card ? nil : current
    }
}
