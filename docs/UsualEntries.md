# One-tap repeats ("Your usual")

Round 7 of the improvement loop. Most of what gets logged has been logged before: the same breakfast
most mornings, the same correction when running high, the same jelly beans for a low. The log sheets
(iPhone `PhoneLogSheet`, Mac `LogSheet`) now offer those as a **Your usual** row under
"What's happening?". One tap fills the entry in; the Log button logs it.

Rules: `Sources/Engine/UsualEntries.swift` (tests `UsualEntriesTests`). App side:
`Sources/Bolus/UsualEntryViews.swift`.

## On the Mac: popover and keyboard

Round 26. The menu bar popover shows the same entries, up to three, as a **Your usual** row above
the toolbar (`PopoverUsualRow`). The chips are short ("Toast and banana", "Correction 2 u",
"Treat a low", `UsualEntry.shortTitle`); the tooltip and VoiceOver give the whole entry. A click
opens the log window filled in from that entry (`LogSheetTarget.usual`), exactly as clicking its
chip in the sheet would. **Nothing is logged from the popover:** the entry is logged with Log in
that window, after `RepeatCheck`, the calculator and its confirm step. The sheet works the entries
out again when it opens and fills nothing in if the one picked is no longer offered (a correction
after glucose came down, say).

Keyboard: **⌥⌘1 – ⌥⌘3** pick the first three entries, in the popover and in the log sheet
(`UsualKeys`, listed in the ⌘? lists; the sheet lists them only while it offers some). Holding ⌘
in the popover shows the keys on the chips. ⌥⌘ keeps them clear of ⌘1–⌘9 (moments in the sheet,
chart range in the popover).

## On the iPhone Home Screen: the Your Usual widget

Round 27. A medium Home Screen widget (`UsualWidget`, Sources/iOSWidget/UsualWidget.swift) shows
the entries the sheet would offer now, up to three, as buttons, with a **+** for anything else.

- The app works the entries out on every publish (`GlucoseStore.refreshUsualGlance`) and writes them
  into `GlucoseSnapshot.usuals` as `UsualGlance`, words and all: the widget extension doesn't compile
  Sources/Engine. `WidgetReload.Group.usual` reloads the widget only when they change.
- A button runs `OpenUsualIntent` (iOS 17+ App Intents, `openAppWhenRun`), which opens GlucOS on the
  log sheet with `PhoneLogTarget.usual(id:)`. **Nothing is logged from the widget:** the sheet works
  the entries out again, fills that one in if it's still offered (`applyStartingUsual`, as on the
  Mac) and otherwise just opens on food or the dose. Log then goes through `RepeatCheck`, the
  calculator and its confirm step as usual. If the intent runs in the widget's own process it leaves
  the id in the app group (`UsualActions.takePending`, kept for 60 s) and the app opens it on launch.
- Between reloads the widget drops what the app would no longer offer (`UsualGlance.visible`): a
  correction once its reading goes stale, a meal once its part of the day ends. Its timeline has an
  entry at each of those moments and nothing else. No animation: widgets run no timers.
- VoiceOver reads each button in words (`spoken`), with a hint that it opens GlucOS to check and log.

## What's offered

| Tile | Read from | Shown when | Fills in |
|---|---|---|---|
| Usual breakfast / lunch / dinner / snack | Meals in the same part of the day (breakfast 5–11, lunch 11–15, dinner 17–22, else snack) over the last 28 days, grouped by name (or carbs, if unnamed). Needs 3 different days. Ties go to the latest. | Always, for the current part of the day | The food, its foods from the list and its carbs, **from the latest time it was logged**. Opens the dose step. |
| Usual correction | Fast-acting doses ≥ 0.5 u with no food or hypo treatment within 30 min, not marked "for a meal", not a calculator dose for carbs (a dose answered "Correction" always counts). Needs 3 in 28 days; the most common amount, ties to the latest. | Glucose fresh and at or above the high line, not falling faster than 2 mg/dL/min, no bolus in the last hour, not low | The units and insulin shown on the tile. The dose is stored with purpose `correction`, so "Was that dose for a meal?" doesn't ask. |
| Treat a low | Food logged within 10 min of a Hypo treatment tag, over 90 days. Needs 2 of the same. | Glucose below the low line, or within 20 mg/dL of it and falling at 1 mg/dL/min or more. Shown first, and the correction is hidden. | The food and carbs, tagged Hypo treatment. No dose. |

Hypo treatments never count as a usual meal.

## Safety

- Every amount is one the user logged themselves. Nothing is averaged or invented.
- A usual meal never fills a dose. With the calculator set up it works the dose out as before (and
  its own cautions, including PR #54's `.possibleRepeat`, show on the card). The dose step also offers
  "With it last time: 4.5 u", the bolus logged within 20 min of that meal the latest time, as a chip
  the user taps; it disappears once the carbs are changed.
- A dose with no food yet offers the usual meal above it ("Usual breakfast? Add Toast · 45 g"), so
  the calculator gets the carbs in one tap.

## Logged twice? (`RepeatCheck`)

Every one-tap fill (a usual entry, a preset, "Same as last", a recent food chip, "With it last time")
is checked against the logbook when Log is pressed:

- a fast-acting dose within 45 minutes of the entry's time, whatever it came from (the calculator's
  own check only sees calculator doses);
- a meal within 45 minutes with the same name, or carbs within 10% (5 g or more);
- for a low treatment, another hypo treatment in the 15 minutes before.

If anything matches, an "Already logged?" step names it ("You logged 4 u 12 minutes ago. If it's the
same dose, don't log it again.") with Log anyway / Cancel. When the dose came from the calculator,
the same text leads its existing confirm step, so there's still one dialog.

## Motion and accessibility

- Tiles fade and scale in with `DSMotion.standard` (`.dsAnimation`), and filling the sheet animates
  through `DS.animate(_:reduceMotion:)`: under Reduce Motion everything changes at once.
- VoiceOver reads the tile in words ("Usual breakfast: Toast and banana, 45 grams of carbs"), with a
  hint saying what a tap does, the selected tile carries the Selected trait, and after a tap it
  announces what was filled in.
- The low treatment tile is filled with the critical tone, not only coloured, so it stands out
  without relying on colour.
