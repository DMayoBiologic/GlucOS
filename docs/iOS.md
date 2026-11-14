# GlucOS on iPhone

The iPhone app shows the same cards as the Mac popover (reading, trend, chart with forecast,
outlook, time in range, sensor), keeps a **Live Activity** on the Lock Screen and in the Dynamic
Island, and sends low/high alerts. It also has Lock Screen and Home Screen widgets.

## Logging on iPhone

The bar along the bottom has **Eating**, **Bolus** and **More**. The log sheet starts from the
moment, "What's happening?": Eating, Bolus, Basal (injections), New site (pump), Woke up, Going to
sleep, or Something else (exercise, unwell, alcohol, stress, period, hypo treatment, site
problem). Each one opens the part it needs, and more than one can be on. Parts always appear in
the same order, food first and then the dose for it, so the carbs run straight into the bolus
calculator; "Next: bolus for 45 g" under the food carries on to the dose in one tap. Waking up
and going to sleep need nothing more than the time. The Log button says what it will log ("Log
45 g + 4 u") or what's still missing. Presets, "same as last" and recent foods are one-tap fills.
Tap an entry on the Logbook card to edit it; long-press to log it again or delete it (with Undo).
Everything goes into the same logbook as the Mac and syncs both ways (docs/LogbookSync.md). The
rules both sheets share are in `Sources/App/Logbook/LogFlow.swift`.

Other ways in, all of which open the log sheet: the **Log** Lock Screen widget, the **Log**
button in the expanded Dynamic Island, the "Log in GlucOS" App Shortcut (Siri, Spotlight,
Shortcuts, the Action button), and `glucos://log` (or `glucos://log/insulin|food|site|event`).
None of them ever fill in an amount: GlucOS records what you enter, and only the bolus calculator
suggests a dose.

```
LibreLinkUp ──► push relay (Supabase edge function, every minute) ──APNs──► iPhone: alerts + Lock Screen card
           └──► iPhone app (while it's open)
```

## Why there's a relay

iOS doesn't let apps run in the background. An app gets the odd background refresh when iOS feels
like it (anything from 15 minutes to hours apart), so on its own the iPhone app could only alert
and update the Lock Screen while it's open. That isn't good enough for lows.

So GlucOS has a **push relay**: a Supabase edge function (`supabase/functions/relay`) that
`pg_cron` calls every minute. It fetches from LibreLinkUp, runs the same alert rules and forecast
as the apps (a TypeScript port, kept in step by a parity test against the Swift code), and sends
Apple push notifications:

- **Alerts** as normal push notifications, delivered with the phone locked and the app closed.
  They're *time-sensitive*, so they get through Focus modes you allow them in.
- **Lock Screen card updates** pushed straight to the Live Activity about once a minute.
- iOS ends any Live Activity after 8 hours; the relay ends it a little early and starts a fresh
  one with a push, so the card stays on the Lock Screen.

While the relay is healthy the phone leaves alerts to it, so nothing arrives twice. If the relay
goes quiet, the app falls back to alerting by itself while it's open.

There's no server to run. Supabase deploys the function, the database migration and the schedule
from `supabase/` whenever main changes (the project's GitHub integration).

## Setup (one time)

Everything else ships on merge, like the Mac app. These are the steps only you can do, because
they need your Apple account or a secret. Until the Apple secrets exist, the iPhone release job
skips with a notice. With them but without `RELAY_SECRET`, it ships an iPhone build that doesn't
use the relay, and says so in a notice. The Mac release is never affected.

### 1. Apple Developer Program

Note your **Team ID** (developer.apple.com → Account → Membership details).

### 2. Register the app

At <https://developer.apple.com/account/resources/identifiers/list>:

1. **App Groups** (top-right dropdown) → **+** → `group.au.com.declanmayo.glucos`.
2. **App IDs** → **+** → App → bundle ID `au.com.declanmayo.glucos.ios`. Tick **App Groups**
   (choose the group above), **Push Notifications** and **Time Sensitive Notifications**.
3. **App IDs** → **+** → bundle ID `au.com.declanmayo.glucos.ios.widget`. Tick **App Groups**.
4. **App IDs** → **+** → bundle ID `au.com.declanmayo.glucos.ios.messages` (the Messages app). Tick
   **App Groups** and choose the group above. (If a release already registered the ID, open it, tick App
   Groups, then **Configure** and choose the same group before saving: Apple's API can't assign a group, so without this the archive fails with "Provisioning
   profile … doesn't match the entitlements file's value for the com.apple.security.application-groups
   entitlement".)

Then in App Store Connect (<https://appstoreconnect.apple.com/apps>) → **+** → **New App**:
iOS, name "GlucOS" (any free name; it's never public), bundle ID `au.com.declanmayo.glucos.ios`,
any SKU. Open **TestFlight** → **Internal Testing** → **+**, add yourself and turn on
**Automatic distribution**, so every upload lands on your phone.

### 3. Keys

- **App Store Connect API key** (lets CI sign and upload): App Store Connect → Users and Access →
  Integrations → App Store Connect API → **+**, access **Admin**. Download the `.p8` (you only get
  one chance) and note the **Key ID** and **Issuer ID**. An existing Admin key (for example the
  one EAS uses) works too.

  CI signs with Apple's cloud-managed distribution certificate through this key
  (`scripts/sign_ios.sh`), so there's no certificate to export and no run ever creates one. The
  **iOS signing** workflow checks this on pull requests that touch signing, lists the team's
  certificates, and (run by hand with ids from that list) revokes the Apple Development
  certificates that releases made before this.
- **APNs key** (lets the relay push): developer.apple.com → Certificates, IDs & Profiles → **Keys**
  → **+** → tick **Apple Push Notifications service (APNs)**, environment **Sandbox & Production**.
  Download the `.p8` and note its **Key ID**. An existing APNs key for the team works too.

### 4. Secrets

One random relay secret, kept by the function. It is never built into the app, because anyone
with the public TestFlight link can install it: your iPhone gets it from the relay when you sign
in with the same LibreLinkUp account the relay uses (`POST /v1/claim`). The GitHub copy is no
longer used by the build.

```sh
RELAY_SECRET=$(openssl rand -hex 32)

# GitHub, for the TestFlight build (gh auth login once)
R=DMayoBiologic/GlucOS
gh secret set APPLE_TEAM_ID       -R $R --body "ABCDE12345"
gh secret set APPLE_API_KEY_ID    -R $R --body "<App Store Connect key id>"
gh secret set APPLE_API_ISSUER_ID -R $R --body "<issuer id>"
gh secret set APPLE_API_KEY_P8    -R $R < AuthKey_XXXXXXXXXX.p8

# Supabase, for the relay (supabase login once)
P=aqlbadbyjuoruwnwyfrc
supabase secrets set --project-ref $P RELAY_SECRET="$RELAY_SECRET" \
  APNS_KEY_ID="<APNs key id>" APPLE_TEAM_ID="ABCDE12345" APNS_KEY_P8="$(cat AuthKey_YYYYYYYYYY.p8)"
```

(Or add the four in the Supabase dashboard → Edge Functions → Secrets.) `APPLE_API_*` are the
same names the Mac notarization step uses; they don't change the Mac build unless the Developer
ID certificate secrets are also set.

### 5. Ship and install

Re-run the latest **Release** workflow (Actions → Release → Run workflow) or merge anything. The
iPhone build uploads to TestFlight (Apple takes 5–20 minutes to process it) and already knows the
relay's address. It connects to the relay once you sign in with the relay's LibreLinkUp account.
The same build then goes to external testers through the public link: see docs/TestFlight.md.

On the iPhone: install **TestFlight**, open the GlucOS invite, install, sign in with your
LibreLinkUp follower account, and allow notifications. Settings → Push relay should say
"Alerts: Sent by the relay" within a minute, and the card appears on the Lock Screen.

## Good to know

- **Don't force-quit GlucOS** (swiping it away in the app switcher). iOS won't wake a force-quit
  app, so when the relay starts the next 8-hour Lock Screen card the phone can't hand back its new
  push token, and the card stops updating until you open GlucOS again. Alerts are unaffected.
- **Alerts don't bypass the silent switch.** That needs Apple's Critical Alerts entitlement,
  which you request at <https://developer.apple.com/contact/request/notifications-critical-alerts-entitlement/>.
  Once granted, add the entitlement to the app and set the `APNS_CRITICAL_ALERTS=true` secret.
- **The relay's forecast is trend-only.** The phone and the Mac forecast with the synced
  logbook; the relay forecasts from the recent trend, at the strength and timing it has learnt
  from its own readings (docs/ForecastAccuracy.md §6).
- **The relay gets your LibreLinkUp login.** The app sends it over HTTPS (with the relay secret).
  It's kept encrypted in Supabase Vault. Signing out on the phone asks the relay to delete it; if
  the relay can't be reached then, the login stays in Vault until it can.
- **Two followers, one account.** The Mac and the relay each poll LibreLinkUp once a minute.
- **Without the relay** the app still works while it's open, and the Lock Screen card updates
  whenever iOS gives it background time.

## Relay reference

Base URL `https://aqlbadbyjuoruwnwyfrc.supabase.co/functions/v1/relay`. Endpoints: `GET /health`,
`GET /v1/status`, `POST /v1/register`, `POST /v1/test` (see `Sources/Core/RelayProtocol.swift`),
all but `/health` and `/v1/claim` with `Authorization: Bearer <RELAY_SECRET>`, and `POST /v1/tick`,
which the schedule calls with a token the migration keeps in Vault. `POST /v1/claim` with
`{email, password}` returns `{secret}` when they match the LibreLinkUp login the relay fetches
with (403 otherwise; 5 wrong tries lock it for 15 minutes). That's how the owner's iPhone connects
without the secret being in the app, and why nobody else's install can sign the relay out.

| Function secret | |
|---|---|
| `RELAY_SECRET` | required; the owner's app claims it and sends it as `Authorization: Bearer …` |
| `APNS_KEY_P8`, `APNS_KEY_ID`, `APPLE_TEAM_ID` | APNs auth; without them it fetches but can't push |
| `APNS_BUNDLE_ID` | default `au.com.declanmayo.glucos.ios` |
| `APNS_CRITICAL_ALERTS` | `true` once Apple grants Critical Alerts |

State lives in the `glucos` schema (not exposed by the Data API, row-level security on): one
`relay` row, the `readings` table (90 days) and the cached APNs token. The LibreLinkUp login and
session are in Vault. The `glucos-relay-tick` cron job runs every minute; `net._http_response`
shows its recent results.

Tests: `deno test --allow-read --allow-env --allow-net supabase/functions/relay/`. Set
`GLUCOS_TEST_DB_URL` to a local `supabase/postgres` database (see `ci.yml`) to include the
Postgres store test. After changing the Swift alert rules or forecast, regenerate the parity
fixture with `GLUCOS_WRITE_PARITY=1 swift test --filter RelayParityTests`.
