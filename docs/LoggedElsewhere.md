# Entries logged from elsewhere

Round 40 of the improvement loop. Something logged without opening the Logbook (Siri or Shortcuts,
the Log treatment control in Control Center, the in-app alert banner, a notification's Log
treatment button, a widget, or the Mac's keyboard shortcut) used to land in the Logbook and on the
chart like anything else, so it was easy to miss that it went in. Now it gets **one soft
highlight** the next time its Logbook row and its chart marker appear, with a short caption saying
where it came from: "Logged from Siri", "Logged from Control Center", "Logged from the alert",
"Logged from the notification", "Logged from the widget", "Logged with your shortcut".

Rules: `Sources/Shared/LoggedElsewhere.swift` (`LogOrigin`, `LoggedElsewhereMarks`; tests
`LoggedElsewhereTests`). Views: `Sources/Shared/LoggedElsewhereViews.swift`.

## How it works

- The log sheets know where they were opened from: `PhoneLogRequest.origin` on the iPhone,
  `LogWindowRequest.origin` on the Mac (cleared whenever the window is opened on a new target from
  inside the app). A sheet opened from inside the app has no origin and nothing changes.
- When a new entry is saved, the sheet records the ids it saved (dose, meal, site change, events)
  with that origin, just before saving. The Siri / widget "I'm up" wake-up does the same.
- Each place takes its highlight once: the **Logbook** (iPhone Today's Logbook card or the full
  Logbook, whichever shows the row first; the Mac dashboard's table) and the **chart** the user
  logs against (iPhone Today, the Mac popover). A closed Mac popover keeps its highlight until it
  opens.
- After 10 minutes (`LoggedElsewhereMarks.lifetime`) it isn't news, and the entry appears plainly.
  Edits never highlight. Nothing is saved or synced: an entry logged by Siri on the iPhone shows
  plainly on the Mac.

## What it looks like

- **Logbook row:** the row's colour fades in behind it, the time cross-fades to the caption, both
  hold for 2.4 s and fade back. Nothing in the row moves. On the Mac the caption takes the Details
  cell's place for the same time, and the Entry label lights as for any new entry.
- **Chart marker:** a ring in the marker's colour eases out of it once and fades, with the caption
  in a small capsule above the marker (kept inside the chart near the edges). It waits until the
  log sheet has closed (`LoggedElsewhereMarks.settle`, 1.1 s after saving) so it isn't spent
  behind it.
- Nothing loops. Under Reduce Motion the ring doesn't grow: it and the caption only fade in and out.
- **VoiceOver** hears it once for everything saved together, wherever it shows first: "Meal added
  to chart, logged from Siri" on the chart (folded into the marker's own line), or "Logged from
  Siri: 45 g · Toast" from a row. The caption itself is hidden from VoiceOver, so rows read as
  usual.

## Also in this round

The iPhone's trend announcement (#219) stays quiet when the reading is already stale as it
arrives, as the trend of a late reading isn't news (`PhoneCards`, `!s.isStale(at: .now)`).
