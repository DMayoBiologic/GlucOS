# Settings rows that depend on a switch

Some Settings rows only make sense while a switch or picker above them allows it. When that
switch changes, the rows expand or collapse in place with a slight fade, and the rows below slide
to their new place instead of jumping. Under Reduce Motion the rows are simply there or gone.

Code: `Sources/Shared/DependentRows.swift` (when rows count as revealed, what VoiceOver says),
`Sources/App/Views/DependentRowsViews.swift` (`Binding.revealingRows(shown:rows:reduceMotion:)`,
`.dependentRow()`). Tests: `DependentRowsTests`.

## Where

| Switch | iPhone | Mac |
| --- | --- | --- |
| Glucose alerts | the alert options, repeat interval, test alert | the "Alerts can't reach you" banner; the sections below dim and undim smoothly |
| Predicted lows / highs | Warn me ahead by | Warn me up to dims and undims |
| Sync logbook | status, Sync Now (and Send Report on a problem) | same |
| Insulin / Therapy | Your insulins, Bolus calculator | the Insulins and Bolus Calculator sections |
| Evening recap | Time | Time dims and undims |
| Live Activity | status, Allow in Settings | (iPhone only) |
| Open the log window from any app | (Mac only) | the shortcut failure line, if any |

The Mac keeps its convention of dimming rows that are always listed (as System Settings does);
only rows that are actually added or removed expand.

## Rules

1. The change animates with `DSMotion.standard` (a 0.3 s smooth curve); rows fade in and out
   while the list makes room. Under Reduce Motion it's instant, with no fade.
2. A second switch for rows that are already showing (Predicted highs while Predicted lows already
   shows Warn me ahead by) changes nothing and says nothing.
3. When rows appear, VoiceOver says which, once, `announcementDelay` (0.4 s) after the change, so
   the switch's own "on" is read first: one to three rows are named ("Now showing Sync status and
   Sync now."), more name the first two and count the rest ("Now showing High, Rising or falling
   quickly and 6 more settings."). Nothing is said when rows go away; focus stays on the switch.
4. Settings search still lands on the revealing switch when a row is hidden (docs/SettingsSearch.md).

New dependent row: wrap the controlling binding in `.revealingRows(shown:rows:reduceMotion:)`
and put `.dependentRow()` on the row (or a `Group` of rows) inside the `if`.
