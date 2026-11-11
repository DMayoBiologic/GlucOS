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
- **Records.** One row per entry in `glucos.logbook`: its id, kind (`dose`, `meal`, `siteChange`,
  `context`, `preset`), the entry as JSON (the same encoding as `logbook.json`), when it was last
  changed, and a server change counter (`rev`). Devices pull everything above the last counter they
  saw, and everything from the start every 12 hours.
- **Conflicts.** The later edit wins, by the editing device's clock (the server caps it at five
  minutes ahead of its own). A delete is an edit that leaves a tombstone, so it reaches the other
  devices and an older copy can't bring the entry back. Logic: `Sources/App/Logbook/LogbookSync.swift`,
  with the server's half in `logbook_push`.
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
