# Error reports (diagnostics)

When something fails in GlucOS on the iPhone or the Mac, the app sends a short structured report
to the GlucOS Supabase project, so problems show up without screenshots.

## What's reported

| Feature (`feature`) | Step (`step`) | When | Code (`code`) |
|---|---|---|---|
| `sensor.nfc` | `read-memory` | Read sensor identified the sensor but couldn't read or decode its memory | The NFC error from the Details line (`NFC 100`), or `bad-crc` / `bad-data` |
| `sensor.nfc` | `scan` | The tap failed before the sensor was identified, or Bluetooth takeover failed | `NFC <code>` or the Swift error |
| `sensor.nfc` | `session` | iOS ended the NFC session with an error (not a cancel or timeout) | `NFC <code>` |
| `linkup.fetch` | `fetch` | LibreLinkUp gave an unexpected reply, a changed response, or wants a newer client version (not wrong passwords, rate limits, outages or being offline) | `ClientError <n>`, `URLError <n>` |
| `logbook.sync` | `sync`, `sign-in` | Logbook sync failed (not a refused LibreLinkUp login or being offline) | `HTTP <status>`, `session-expired`, `session-refused`, `bad-response` |
| `relay` | `register`, `status` | The iPhone couldn't register with or read the push relay | `RelayError <n>`, `URLError <n>` |
| `forecast.upload` | `push` | Scored forecasts couldn't be sent to the sync server (they wait for the next sync) | `HTTP <status>`, `URLError <n>` |

Each report also has the person-facing `message`, a technical `detail`, a `context` object (for
sensor problems: `sensor`, `region`, `patchInfo`, `mode`; for LinkUp: `region`, `clientVersion`),
and the device: a random `install_id`, `platform`, `app` (bundle id), `app_version`, `build`,
`os_version` and `model` (`iPhone17,1`, `Mac15,6`).

Never sent: glucose values, logbook entries, the LibreLinkUp login or email (emails are scrubbed
from messages), the sensor serial number.

## How it works

- **App:** `Sources/Core/Diagnostics.swift`. `Diagnostics.shared.report(...)` at the failure sites
  sends each problem (feature + step + code) at most once an hour per install and counts the repeats
  in between (`repeats`). Reports wait on disk (Caches/GlucOS/diagnostics-queue.json, up to 50)
  while offline and go when the app next starts or comes to the front.
- **Opt-out:** Settings › Diagnostics on the iPhone (also in follower mode) and the Mac's Advanced
  tab. UserDefaults key `diagnosticsEnabled`, on by default. The privacy page says the same
  (web/privacy).
- **Send Report button** (`SendReportButton` in `Sources/Core/DiagnosticsViews.swift`): under the
  Read sensor error, LinkUp connection problems (Mac Account tab), logbook sync problems and relay
  errors. It sends the latest problem of that feature with an optional note, `user_sent = true`,
  even with automatic reports off.
- **Server:** edge function `diagnostics` (`POST /functions/v1/diagnostics/v1/report`, JWT check
  off, deployed by the GitHub integration on merge). It validates the shape, clips fields, takes at
  most 20 reports a request and 60 automatic reports an hour per install (Send Report always fits),
  and ignores a retried report it already has. Table `glucos.diagnostics` (RLS on, no policies; only
  the database owner reads it). pg_cron job `glucos-diagnostics-retention` deletes reports older
  than 180 days.

## Reading reports

From a Claude thread, use the Supabase MCP `execute_sql` on project `aqlbadbyjuoruwnwyfrc`
(`*.supabase.co` isn't reachable from the cloud container). Locally, `scripts/diagnostics.sh` runs
the same queries with `psql` and `SUPABASE_DB_URL`.

```sql
-- Each problem in the last 30 days, most frequent first.
select feature, step, code, reports, occurrences, installs, sent_by_user, app_versions,
       last_seen, latest_message, latest_detail
from glucos.diagnostics_summary order by occurrences desc;

-- The last two weeks, newest first (times in Perth).
select * from glucos.diagnostics_recent limit 30;

-- Sensor read failures by code and sensor type.
select code, context ->> 'sensor' as sensor, context ->> 'patchInfo' as patch_info, count(*), max(occurred_at)
from glucos.diagnostics where feature = 'sensor.nfc'
group by 1, 2, 3 order by 4 desc;

-- What people wrote when they pressed Send Report.
select occurred_perth, feature, code, note, detail, app_version, model
from glucos.diagnostics_recent where user_sent;
```

## Adding a report somewhere new

Call `Diagnostics.shared.report(feature:step:error:context:)` (or build a `DiagnosticEvent` with a
specific `code`) where the error is shown, and put a `SendReportButton(feature:step:message:)` under
the error text. Use a stable lower-case `feature`/`step` (`[a-z0-9._-]`, the server refuses
anything else), keep `code` short enough to group by, and keep personal data out of `context`.
Add the new row to the table above.
