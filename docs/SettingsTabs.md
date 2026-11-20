# Mac Settings tab switches

Picking another tab in the Mac Settings window cross-fades the outgoing tab into the new one while
the window's height glides to fit it. The title bar stays where it was and the bottom edge moves;
if growing would run off the bottom of the screen, the window rises just enough.

## Rules (`Sources/Engine/SettingsWindowFit.swift`, `SettingsWindowFitTests`)

- The window fits to the new tab's Form: its content height plus insets (the search field above
  included), at least the 420 pt content minimum and at most 760 pt or the screen's visible height.
  Longer tabs (Alerts) scroll as before.
- It only resizes on a tab switch, including one a Settings search result makes. Rows revealed by a
  switch, a new reading or anything else on the showing tab never resize the window, and a manual
  resize is kept until the next switch.
- No jump on first open: for 0.3 s after the window opens it keeps the size it had, and the switch to
  Account for a broken connection shows Account without a fade or resize.
- Reduce Motion: the new tab is simply there and the window snaps to its height.
- Fade and glide both last 0.3 s (`DSMotion.standard`).

## How it's built

- `SettingsView` keeps the toolbar tabs on its `TabView` (each tab's content is empty) and draws the
  selected tab over it in a `ZStack` keyed by the tab, so both tabs are on screen during the fade.
- `SettingsWindowFitter` (`Sources/App/Views/SettingsTabFitViews.swift`) holds the window, takes
  each tab's scroll geometry through `.settingsTabMeasure(_:)` (applied by the search page modifier,
  so every tab gets it) and animates `NSWindow.setFrame` with `NSAnimationContext`.
- The measurement needs macOS 15's `onScrollGeometryChange`. On macOS 14 tabs still cross-fade and
  the window keeps its height.
