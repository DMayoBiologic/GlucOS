# Notes on alerts

A low or high alert can carry a few words about what was going on ("went for a run", "skipped
lunch", "sensor squashed in bed"), so the Logbook remembers why it went off.

## Where

- **On the notification.** Low and high alerts (urgent low, low, very high, high and their forecast
  versions) have an **Add note** button beside Log treatment and Snooze. It opens a text field on
  the notification itself; type and tap **Save**. Nothing opens: on iPhone the note is saved and
  sent to the sync server in the background, so the Mac has it too. Urgent lows get Log treatment
  and Add note (still never Snooze). It works on the relay's pushes too, since they name the same
  categories, so the relay needed no change.
- **In Settings › Alerts › Alert History** (docs/AlertHistory.md). Each row has a pencil button,
  **Add note**, beside it; once the alert has a note the button becomes **Edit note** and the note
  shows in italics under the outcome. The editor lets you change the text, **Remove Note**, or
  cancel. Saving shows the usual undo toast, **Added note · Undo** (an edit shows "Edited note",
  removing shows the delete's Undo). ⌘Z undoes on the Mac.

The in-app banner keeps only its Log treatment and Snooze buttons. Test alerts' Add note does
nothing, like their other buttons (docs/TestAlert.md). A follower's copy of someone else's alert
never saves a note.

## What a note is

- A plain Logbook note at the alert's time: an event (`ContextEvent`) with **no tags** and the text
  as its note. One line, trimmed, at most 120 characters (`AlertNote.cleaned`).
- It syncs like any entry, shows in the Logbook as **Note**, is found by searching its words or
  "note", and is exported with type "Note". Its row in the Logbook can be edited or deleted like
  any other.
- **It never logs a treatment and never snoozes.** With no tags it is not a hypo treatment, food,
  insulin or anything Insights, the forecast or the bolus calculator read.
- The alert's note is the closest plain note within 3 minutes of when it went off
  (`AlertNote.existing`), the same window the history uses to merge the Mac's and the iPhone's
  copies of one alert. Typing a note again from the history edits that one rather than adding a
  second.
- A note typed on the notification offers no Undo toast, since nothing is on screen. Edit or remove
  it from the Logbook or the Alert History.

## Undo

`LogbookAddUndo` (Sources/App/Logbook/LogbookSync.swift) holds the added note. Undo deletes it on
every device, and only while it is still there under the same id. A newer change to it from
another device ends the Undo; this device's own add echoing back from the server doesn't. As with
every Undo, one at a time: an add replaces a pending delete's, edit's or batch's Undo, and they
replace it.

## VoiceOver

Each history row is still one element: it reads the alert, its reading and outcome, then "Note:
…" when there is one. Activating it opens the Logbook around the alert; the **Add note** (or
**Edit note**) action opens the editor. The notification's action is labelled by the system from
its title, "Add note".

## Motion

A note appearing under its row, or going, fades in place with the standard motion, and is instant
under Reduce Motion. The undo toast moves as it does everywhere (fade only under Reduce Motion).

## Code

- Rules and words: Sources/Engine/AlertNote.swift (`AlertNote`, `AlertNoteText`). Tests:
  AlertNoteTests.
- Action: `AlertSnoozes.noteAction` ("alert.note"), a `UNTextInputNotificationAction` in
  `AlertNotifications.categories`; `AlertNotifications.note` reads the typed text; both apps'
  `didReceive` delegates hand it to `AlertLogRecorder.noted`.
- Store: `LogbookStore.saveAlertNote(_:firedAt:offersUndo:)`, `lastAdd`, `undoAdd`;
  `LogbookUndoOffer.added`.
- Views: `AlertHistoryContent` / `AlertHistoryRow` in Sources/App/Views/AlertHistoryViews.swift.

## Notes on the chart

Every plain note (a Logbook context entry with text and no tags, alert notes included) shows as a
small note marker at its time on iPhone Today, the Mac popover and the Mac Outlook chart
(`ChartNote`, `Sources/Shared/ChartNotes.swift`). It shares the wake-up lane, one lane higher when
a wake-up is within 20 minutes. Like every other marker it pops in and shrinks out, a hold (iPhone)
or hover (Mac) peeks at it, a tap or click opens the callout with the note, the peek card offers
Edit only, and a scrub snaps onto it. VoiceOver reads one line per note ("Note at 3:05 pm: Felt
shaky"); the marker's button reads the note itself. Static under Reduce Motion. Followers never see
the person's notes on their chart.
