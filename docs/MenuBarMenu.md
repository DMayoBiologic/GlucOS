# The menu bar item's right-click menu

Right-click or Control-click the reading in the menu bar for a small menu:

- **Your usual**: the same up to three one-tap repeats the popover row offers (the usual meal for
  this time of day, the usual correction while high, what you take for a low), with ⌥⌘1–⌥⌘3.
- **Log Something…**: the log window on a new entry.
- **Open Logbook**: the dashboard on the Logbook, as you last left it.
- **Copy Reading** (⌘C): the current reading as one line in the unit on screen, the same line ⌘C
  copies in the popover (`ReadingCopy`), such as "6.1 mmol/L, steady, 2 min ago". Its tooltip shows
  the line first. The item says "✓ Copied" for 1.2 s, then the reading comes back, and VoiceOver
  announces "Copied" once. Left out while there is no reading to copy.
- **Settings…** (⌘,).

A plain click still opens the popover, and the hover preview closes when the menu opens.

## Nothing is logged from the menu

Picking a usual opens the log window filled in from it, exactly as the popover row does
(`LogSheetTarget.usual`), with the entry
itself rather than its id: a usual meal shown at 10:59 as breakfast and picked at 11:00 still fills
breakfast. A usual correction only fills while one is still offered, so one that stopped applying
because glucose came down opens unfilled (`UsualEntries.startingFill`). It is logged there with Log, after `RepeatCheck` ("Already logged?") and,
for a dose, the calculator's confirm step. A meal never brings a dose with it.

## How it works

- `Sources/Engine/MenuBarQuickMenu.swift` (MenuBarQuickMenuTests): which clicks open the menu and
  what rows it holds. Long usual titles are cut at 44 characters.
- `Sources/App/Views/MenuBar/MenuBarQuickMenuController.swift`: MenuBarExtra owns the status item
  and can't be given a menu, so a local event monitor watches for a right or Control click on
  GlucOS's status bar button, swallows it and pops an `NSMenu` up under the button, highlighted.
  Usuals are worked out when the menu opens. Open Logbook sets `DashboardRequest.opensLogbook`;
  Settings posts `glucosOpenSettings` for `MenuBarLabel`, which can reach `openSettings`.
- Power: the monitor only sees GlucOS's own events and returns at once for any other click. No
  timer, no tick.
