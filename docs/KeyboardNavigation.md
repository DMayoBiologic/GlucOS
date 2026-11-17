# Moving round with the keyboard (Mac)

The menu bar popover, Insights and the Logbook can be used without the mouse. Tab and the arrow
keys move a focus ring through the cards and controls, Return or Space does what a click would,
and Esc closes. This works with the system's **Keyboard navigation** setting off (the macOS
default); with it on, buttons join the Tab loop as usual and get the same ring. Every existing
shortcut (docs/KeyboardLogging.md) still works.

| Keys | What it does |
| --- | --- |
| Tab, ⇧Tab | Next or previous card or control, in reading order. The first Tab shows the ring. |
| ↑ ↓ | The card or row above or below, landing near the same place along it. They never wrap. |
| ← → | Along a row: the toolbar buttons, the Your usual chips, the two sides of a card, the 24 hours of Time in range by hour, the Logbook's search and filter bars. They stop at the ends. On a period picker or the Logbook filters they pick the next value first. In the search field they move the cursor, never the ring. |
| Return, Space | Press what has the ring. On a card with nothing of its own to do, Return goes into it (to its first tile or link). |
| Esc | Close the sheet, the ⌘? list or the popover. |

The ring is the system's focus colour, 2.5 pt, just outside the card or control. It comes up
with the keyboard and goes away on a click, so clicking a card never leaves a ring round it
(`FocusRingVisibility`). It fades in 0.12 s, instantly under Reduce Motion.

## Where it goes

- **Menu bar popover:** the reading (Return opens the reading details), the snoozed-alerts chip,
  Log treatment during a low, the chart (← → still step through readings, ↑ ↓ leave it), the
  summary card (Return shows or hides Details, as ⌘I does), the Your usual chips, then the
  toolbar's Log, Refresh, Dashboard and Settings. The ⋯ menu is reached with Tab when Keyboard
  navigation is on, and its items all have shortcuts.
- **Insights:** Customise Cards…, then each card in the order on screen. The Lows, Highs and
  Overnight cards hold their period picker (← → change it) and "in the Logbook" link; streaks
  holds its link; Weekdays and weekends, Week in
  review and Best and toughest days hold their two sides; Best and toughest days stack theirs (↑ ↓);
  Tags holds a tile per tag (↑ ↓, as the grid's width varies); Time in range
  by hour holds its 24 hours.
- **Logbook:** Back to Insights (when it came from a card), the search bar (search field, date
  chip, Jump to Date, Edit…, Log Again Now, Delete), the filter bar (← → on the filters pick the
  next one, then move on to Alerts and the tags), then the table, which keeps every arrow key for
  its rows (Tab and ⇧Tab leave it) and where Return edits the selected entry.

Sheets close on Esc: Customise Cards, the ⌘? lists, the clinic export and the share preview, as
well as the log sheet. Popovers (the calendar, a day's chart, reading details) close on Esc by
themselves.

The full list is in Settings → Logging → Keyboard → Keyboard shortcuts (Show All…), and each ⌘?
list has a "Moving around" group.

## Code

- Rules (unit-tested in `KeyNavigationTests`): `Sources/Engine/KeyNavigation.swift`: `KeyStop`
  (a stop, its row, the card it sits in and the arrow keys it `keeps` for itself), `KeyNavigation.rows/order/target/firstInside`, and
  `FocusRingVisibility`.
- Views: `Sources/App/Views/KeyFocus.swift`. A screen holds one `@FocusState var keyFocus:
  String?` and calls `.keyNavigation($keyFocus)`; each card or control calls `.keyStop(id, row:,
  kind:, action:)`. Stops report themselves through a preference in layout order, so the arrow
  keys follow what's on screen without a hand-kept list. `.card` stops are always focusable;
  `.control` stops are focusable unless Keyboard navigation already makes the button so;
  `.native` stops (the chart, the search field, the table) only join the arrow keys' order.
  The modifiers do nothing on iPhone, where the Insights cards are shared.
- Tab is the system's own key loop, which follows the layout, so it matches `KeyNavigation.order`.
- `.keyCycle($value, through:)` makes ← → step a segmented picker that is one stop.
- Lists: `ShortcutCatalog.navigation(escape:closes:)` and `ShortcutCatalog.all` (Settings).
- A new card or control: add `.keyStop` with an id unique on its screen; put side-by-side stops on
  one `row`.
