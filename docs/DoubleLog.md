# Logged twice?

Logging the same thing twice is easy: Siri and then the app, the iPhone and then the Mac, a widget
tap and then the log sheet, or a second tap on Log Again Now. A doubled dose in the Logbook makes
insulin on board, the forecast and Insights all wrong. So after a new meal or dose is saved, GlucOS
looks for one that is nearly the same, and if it finds one the undo toast says so:

> ⧉ Logged twice? 4 u NovoRapid · **Undo**

It is a gentle check after the fact. **It never blocks a save, never deletes anything by itself,
and never changes an amount.** Dosing maths are untouched.

## What counts as logged twice (`DoubleLog`, Sources/Engine/DoubleLog.swift)

- Only new **meals** and **doses**: never notes, events, site changes or edits.
- The other entry's time is within **5 minutes** of the new one's, either side.
- A dose: the same kind of insulin (and the same insulin when both name one, however it's spelled),
  with units within 0.1 u or 5% of each other.
- A meal: carbs within 1 g or 5%, and the same food when both name one.
- Entries saved together (a meal and its dose from one Log) are never each other's twins. The
  closest in time wins.
- Entries from other devices count once they have synced, so an iPhone log followed by the same
  one on the Mac is caught.

## Where it's checked

Every new entry from a log sheet, which is where Siri, widgets, controls, alert buttons, quick
actions and the Mac shortcut all end up, and every Log Again Now. One-tap fills already get the
"Already logged?" step before saving (`RepeatCheck`, docs/UsualEntries.md); when the user answered
**Log anyway** there, the toast doesn't ask again.

## Undo (`LogbookRepeatUndo`, `LogbookStore.offerRepeatUndo` / `undoRepeat`)

- It is one more kind of the shared undo toast (`LogbookUndoOffer.repeated`), with the same
  countdown bar, pause on touch or hover, swipe to dismiss, ⌘Z on the Mac and VoiceOver
  announcement. One Undo at a time, as always.
- Undo deletes only the **new** entries, on every device, and only while the earlier twin is still
  there, so the user can never be left with neither. It has no Undo of its own.
- The offer ends when the new entry is edited, or when sync brings a change to either entry from
  another device.
- iPhone: the toast shows wherever the undo toast already does. Mac: in the Logbook, Settings and
  Alert History as before, and now also over the menu bar popover and the dashboard's other pages,
  showing only "Logged twice?" there.

Tests: Tests/EngineTests/DoubleLogTests.swift.
