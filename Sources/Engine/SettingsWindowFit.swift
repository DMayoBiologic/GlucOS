import Foundation

/// How the Mac Settings window fits a newly picked tab (docs/SettingsTabs.md). Kept free of AppKit
/// and SwiftUI so it can be unit-tested.
///
/// Switching tabs cross-fades the content while the window's height glides to fit the new tab,
/// keeping the title bar where it was. The window only moves on a tab switch: it never resizes on
/// its own while a tab is showing (a switch revealing rows, a new reading), and it opens at the
/// size it had, so nothing jumps on first open.
enum SettingsWindowFit {
    /// Smallest content area the window fits to, matching SettingsView's minHeight.
    static let minimumContentHeight: Double = 420
    /// Tallest the window grows to fit a long tab (Alerts); past this the tab scrolls as before.
    static let maximumWindowHeight: Double = 760
    /// How long after a switch the new tab's measurement is taken, so a Form that lays out in two
    /// passes is measured once it has settled.
    static let measureDelay: Double = 0.06

    /// The window height that shows all of a tab, given the window's height now and its scroll
    /// view's height (`container`) and the height its content wants (`needed`, content plus
    /// insets, including the search field above). Whatever sits outside the scroll view (title
    /// bar, tab toolbar) stays the same, so only the difference between the two is added.
    /// `chrome` is the window height minus its content area, for the minimum.
    static func fittedHeight(window: Double, container: Double, needed: Double,
                             chrome: Double, screenHeight: Double) -> Double {
        let wanted = window + (needed - container)
        let lower = minimumContentHeight + chrome
        let upper = max(lower, min(maximumWindowHeight, screenHeight))
        return min(max(wanted, lower), upper).rounded()
    }

    /// Where the window's bottom edge goes for a new height: the top edge (`top`) stays put and
    /// the bottom moves; if that would run off the bottom of the screen's visible area, the window
    /// rises just enough. AppKit coordinates, measured up from the bottom.
    static func originY(top: Double, height: Double, visibleMinY: Double, visibleMaxY: Double) -> Double {
        let y = top - height
        return y < visibleMinY ? min(visibleMinY, visibleMaxY - height) : y
    }

    /// Whether a tab switch should change the window at all. Before the window has settled after
    /// opening (including the switch to Account when the connection needs fixing) it keeps its size.
    static func step(from old: Double, to new: Double, settled: Bool, reduceMotion: Bool) -> ContentResize.Step? {
        guard settled, old > 0, new > 0, abs(new - old) >= 1 else { return nil }
        return ContentResize.step(from: old, to: new, settled: true, reduceMotion: reduceMotion)
    }
}
