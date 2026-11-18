# Logbook sync

Doses, food, pump site changes, context tags and presets are shared between GlucOS on the Mac and
on the iPhone through the GlucOS Supabase project. Nothing to set up: both apps sign in with the
LibreLinkUp account they already use.

## How it works

- **Offline-first.** Each device keeps the whole logbook locally (`logbook.json`, unchanged) and
  always reads and writes that copy. `LogbookSyncService` pushes and pulls in the background: two
  seconds after a change, every minute while the app runs, when the iPhone app comes to the
  foreground and during its background refreshes. What's waiting to go up is in
  `logbook-sync.json` next to the logbook.
- **Records.** One row per entry in `glucos.logbook`: its id, kind (`insulin`, `dose`, `meal`, `siteChange`,
  `context`, `preset`, `food`, `bolusSettings`, `lowAnswer`, `alert`, `insightsLayout`, `dayNote`), the entry as JSON (the same encoding as `logbook.json`), when it was last
  changed, and a server change counter (`rev`). Devices pull everything above the last counter they
  saw, and everything from the start every 12 hours.
- **Conflicts.** The later edit wins, by the editing device's clock (the server caps it at five
  minutes ahead of its own). A delete is an edit that leaves a tombstone, so it reaches the other
  devices and an older copy can't bring the entry back. Logic: `Sources/App/Logbook/LogbookSync.swift`,
  with the server's half in `logbook_push`.
- **Undo.** Undoing a delete saves the entries again with a fresh edit time, later than the
  delete's tombstone, so the server takes them back and the other devices pull them again (a
  deleted-then-undone entry reappears on the Mac rather than staying gone). This device's own
  tombstone coming back on the next pull leaves Undo available; only a change made elsewhere after
  the delete ends it (`LogbookUndo`). On iPhone and Mac the Undo toast stays up 5 seconds after the
  last delete (20 under VoiceOver); on the Mac, ⌘Z undoes.
- **Undo toast countdown.** A thin bar along the bottom of the toast drains over those 5 seconds
  (`UndoCountdownBar`, clock in `Sources/Shared/UndoCountdown.swift`). A finger on the toast
  (iPhone) or the pointer over it (Mac) pauses the bar, and letting go carries on from where it
  stopped, with at least a second left. Swipe the toast sideways or down (drag it on the Mac) to
  dismiss it early; it follows the finger with a little give upward and springs back from a short
  drag (`UndoSwipe`). Dismissing never undoes. Only a new delete restarts the bar and is announced
  to VoiceOver, once; pauses, a partial Undo or sync trimming the buffer don't. Under Reduce Motion
  the toast fades in and out in place, doesn't follow the finger, and the bar steps down once a
  second instead of gliding. VoiceOver users can dismiss with the escape gesture or the Dismiss
  action. One drain per toast, nothing loops.
- **Undo an edit.** Saving an edit from the log sheet (iPhone or Mac) brings up the same toast,
  "Edited meal" (or dose, site change, event), with Undo, the same countdown and the same swipe.
  Undo saves the entry back exactly as it was before the edit, under the same id and with a fresh
  edit time, so it syncs to the other devices like any edit (`LogbookEditUndo`,
  `LogbookStore.undoEdit`); the row cross-fades back to its old values. It only ever touches the
  edited entry, and amounts come back only as they were saved; nothing is worked out. The toast
  offers one Undo at a time: an edit replaces a pending delete's Undo and a delete replaces a
  pending edit's. A later save to that entry on this device (another edit, an answer to "Was it for
  a meal?"), its delete, or a newer change to it pulled from another device ends the Undo; this
  device's own edit coming back from the server doesn't. Saving with nothing changed offers none.
  Under Reduce Motion the restore and the toast fade in place.
- **First sync.** A device's existing entries are uploaded as older than anything already on the
  server: entries the server lacks are added, and a delete made elsewhere still wins.
- **Sign-in.** The `account` edge function checks the LibreLinkUp login with Abbott once, finds or
  creates the Supabase user for that LibreLinkUp user id (the email is a made-up
  `llu-<hash>@users.glucos.invalid` that never gets mail) and returns a session. The password isn't
  kept; after that the apps refresh the session with Supabase Auth. Failed sign-ins back off (2 min
  up to an hour) so LibreLinkUp never sees a burst of logins.
- **Access.** Row-level security limits every user to their own rows. The table is in the
  `glucos` schema, which the Data API doesn't expose; apps reach it only through
  `public.logbook_push` and `public.logbook_pull`, which run with the caller's rights.

The iPhone's forecast, insulin and carbs on board use the synced logbook, so a dose logged on the
Mac counts on the iPhone (and its Lock Screen card) after the next sync. The push relay's
forecast is still trend-only.

## Testing

- `swift test` covers the merge rules (`LogbookSyncTests`, two simulated devices and a server).
  `LogbookSyncClientTests` runs the real client against a Supabase stack when
  `GLUCOS_SYNC_TEST_URL` is set.
- `deno test supabase/functions/` covers the `account` function, and with `GLUCOS_TEST_DB_URL`
  the table, RLS and push/pull rules against Supabase's Postgres image, like CI.

## Tags

Entry tags (`labels`, docs/LogbookTags.md) are part of the entry payload, so they sync with no server change.

## Day notes (round 70)

Each day note is one record of kind `dayNote`, payload `{"day": "2026-11-18", "text": "Sick day"}`.
Its id is fixed by the date (`DA7E0000-0000-4000-8000-0000YYYYMMDD`, `DayNotes.recordID`), so a
note written for the same day on the iPhone and the Mac is one record and the later edit wins.
Clearing a note pushes a tombstone. A payload with a date that doesn't exist is left alone. Day
notes aren't in the share allowlist, so followers never see them. Tests: `DayNotesTests`.
