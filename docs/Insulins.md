# Your insulins

Set up once, picked with a tap whenever a dose is logged, on the Mac and the iPhone.

- **Where.** Settings → Logging → Your Insulins (Mac), Settings → Logging → Your insulins (iPhone).
  Each insulin has a name, a type (rapid, ultra-rapid, short, intermediate, long-acting, premixed)
  and, optionally, a dose step: how far − / + move the units in the log sheet (e.g. 0.5 u for a
  half-unit pen). Without one the step is 1 u, or 0.5 u on a pump.
- **Logging.** The log sheet shows the saved insulins as chips. A new dose starts on the mealtime
  insulin logged most recently, otherwise the first mealtime insulin in the list. "Other" opens the
  old type + name entry. Every way of logging goes through the two log sheets (the iPhone logging
  bar, Logbook card, Lock Screen widget, Dynamic Island, "Log in GlucOS" in Siri/Shortcuts, the Mac
  popover and quick-log window), so they all get this.
- **Names are kept consistent.** A dose's name is matched to a saved insulin ignoring case, spaces
  and punctuation, and written with the saved spelling. A name that isn't saved yet is added to
  the list when the dose is logged. Settings offers to rewrite earlier doses and presets that spell
  a saved insulin differently ("Novorapid" → "NovoRapid"); only the name changes.
- **First run.** The list starts with the insulins already in the logbook (most-used spelling and
  type) and the names from the old Settings fields. Those go up to the sync server as older than
  anything there, so an insulin deleted on another device stays deleted.
- **Sync.** Record kind `insulin` in the logbook sync, with its position in the list. Stored on
  each device in `insulins.json` next to `logbook.json`. No server change was needed (kinds are
  free text); older app versions skip the records.
- **Site rotation.** For an injection, the log sheet starts on the site used longest ago (never-used
  sites first, within the body areas the user injects into), marks it as suggested, and notes when
  the site picked was used in the last three days. Rules: `Sources/App/Logbook/SiteRotation.swift`.

## Reordering (round 97)

The order is the one the log sheet's chips follow. To change it, rest a finger on an insulin for
0.3 s on iPhone (or drag it a few points with the pointer on the Mac) and it lifts: it grows to
1.03x with a soft shadow and follows the finger, and the rows it passes slide aside by its height,
so the gap shows where it will land. It takes a row's place once its middle passes that row's
middle. Letting go settles it into the gap and saves the order, which syncs like any edit. On
iPhone a light tap plays at the pick-up (`HapticEvent.rowPicked`) and at the drop (`rowDropped`).

- **Reduce Motion:** the row keeps its size and only the shadow shows; the other rows jump to their
  places. **Increase Contrast:** no shadow, only the 1.03x lift.
- **VoiceOver** and iPhone **Edit** mode keep the system rows, so VoiceOver's move actions and the
  delete buttons work as before. A tap still opens the insulin. On iPhone, swipe left to delete as
  before (the Logbook's swipe from round 95, Delete only, `phoneSwipeToDelete`). On the Mac,
  right-click offers Edit and Delete.
- Rules: `Sources/Shared/RowReorderDrag.swift` (tested by `RowReorderDragTests`); view:
  `InsulinReorderRows` in `InsulinSettingsView.swift`.

Code: `Sources/App/Logbook/InsulinLibrary.swift` (rules, tested by `InsulinLibraryTests`),
`InsulinSettingsView.swift` (Settings), `LogbookStore` (storage and sync).
