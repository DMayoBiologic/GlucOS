import Foundation

// Dragging a row to a new place in a short list, such as Settings › Your Insulins (round 97).
// The picked-up row lifts to 1.03x with a soft shadow and follows the finger or pointer; the rows it
// passes slide aside by its height, so the gap always shows where it will land. On iPhone a light
// tap plays when the row lifts and again when it drops. Under Reduce Motion the row keeps its size
// (only the shadow shows) and the other rows jump to their places instead of sliding. Under
// Increase Contrast there is no shadow, as with every other GlucOS shadow. Plain Foundation, so the
// rules are unit-tested (RowReorderDragTests).

enum RowReorderDrag {
    /// How far a picked-up row grows.
    static let liftScale = 1.03
    /// The shadow under a picked-up row.
    static let shadowOpacity = 0.18
    static let shadowRadius = 10.0
    static let shadowY = 4.0
    /// How long the finger rests on an iPhone row before it lifts. Shorter than a context menu's,
    /// longer than a tap, so a quick swipe still scrolls Settings.
    static let pickupDelay = 0.3
    /// How far a Mac pointer drags before the row lifts, so a click still opens the insulin.
    static let macPickupDistance = 4.0
    /// How long the lift, the rows sliding aside and the drop take.
    static let duration = 0.22

    struct Look: Equatable, Sendable {
        var scale: Double
        var shadowOpacity: Double

        static let resting = Look(scale: 1, shadowOpacity: 0)
    }

    /// How a row looks while picked up or not.
    static func look(lifted: Bool, reduceMotion: Bool, increasedContrast: Bool) -> Look {
        guard lifted else { return .resting }
        return Look(scale: reduceMotion ? 1 : liftScale, shadowOpacity: increasedContrast ? 0 : shadowOpacity)
    }

    /// Where the row picked up at `from` would land after moving `translation` points (down is
    /// positive), given each row's height. It takes a row's place once its middle has been passed.
    static func target(from: Int, translation: Double, heights: [Double]) -> Int {
        guard heights.indices.contains(from) else { return from }
        var target = from
        var travelled = 0.0
        if translation > 0 {
            var i = from + 1
            while i < heights.count, translation > travelled + heights[i] / 2 {
                travelled += heights[i]
                target = i
                i += 1
            }
        } else if translation < 0 {
            var i = from - 1
            while i >= 0, -translation > travelled + heights[i] / 2 {
                travelled += heights[i]
                target = i
                i -= 1
            }
        }
        return target
    }

    /// How far the row at `index` slides aside while the row from `from` hovers over `target`:
    /// up by the picked-up row's height when it moved down past it, down when it moved up past it.
    static func shift(of index: Int, from: Int, target: Int, heights: [Double]) -> Double {
        guard heights.indices.contains(from), index != from else { return 0 }
        let height = heights[from]
        if from < target, index > from, index <= target { return -height }
        if target < from, index >= target, index < from { return height }
        return 0
    }

    /// The `onMove` destination for dropping the row from `from` at `target` (SwiftUI counts the
    /// destination before the row is taken out), or nil when it lands where it started.
    static func moveDestination(from: Int, target: Int) -> Int? {
        guard from != target else { return nil }
        return target > from ? target + 1 : target
    }
}
