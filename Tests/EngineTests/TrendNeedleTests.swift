import XCTest
@testable import GlucOSEngine

/// The Live Activity, Dynamic Island and Lock Screen accessories draw the trend as one arrow turned
/// to `Trend.needleAngle`, so a new trend swings the arrow round instead of swapping glyphs. These
/// pin the angles to the glyphs they replaced, so the arrow never points somewhere new.
final class TrendNeedleTests: XCTestCase {
    func testAnglesMatchTheGlyphsTheyReplace() {
        // A right-pointing arrow turned clockwise by the angle (SwiftUI's rotationEffect).
        let glyphForAngle: [Double: String] = [
            -90: "arrow.up", -45: "arrow.up.right", 0: "arrow.right", 45: "arrow.down.right", 90: "arrow.down",
        ]
        for trend in [Trend.fallingQuickly, .falling, .flat, .rising, .risingQuickly] {
            XCTAssertEqual(glyphForAngle[trend.needleAngle], trend.systemImage, "\(trend)")
        }
    }

    func testRisingTurnsAnticlockwiseInOrder() {
        // From falling quickly to rising quickly the arrow only ever turns one way, so a change of
        // one step is always the short 45° swing.
        let order: [Trend] = [.fallingQuickly, .falling, .flat, .rising, .risingQuickly]
        let angles = order.map(\.needleAngle)
        XCTAssertEqual(angles, angles.sorted(by: >))
        for (a, b) in zip(angles, angles.dropFirst()) { XCTAssertEqual(a - b, 45) }
        XCTAssertEqual(Trend.unknown.needleAngle, 0)
    }
}
