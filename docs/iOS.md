# GlucOS on iPhone

The iPhone app shows the same cards as the Mac popover (reading, trend, chart with forecast,
outlook, time in range, sensor), keeps a **Live Activity** on the Lock Screen and in the Dynamic
Island, and sends low/high alerts. It also has Lock Screen and Home Screen widgets.

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

Then in App Store Connect (<https://appstoreconnect.apple.com/apps>) → **+** → **New App**:
iOS, name "GlucOS" (any free name; it's never public), bundle ID `au.com.declanmayo.glucos.ios`,
any SKU. Open **TestFlight** → **Internal Testing** → **+**, add yourself and turn on
**Automatic distribution**, so every upload lands on your phone.

### 3. Keys

- **App Store Connect API key** (lets CI sign and upload): App Store Connect → Users and Access →
  Integrations → App Store Connect API → **+**, access **Admin**. Download the `.p8` (you only get
  one chance) and note the **Key ID** and **Issuer ID**. An existing Admin key (for example the
  one EAS uses) works too.
- **APNs key** (lets the relay push): developer.apple.com → Certificates, IDs & Profiles → **Keys**
  → **+** → tick **Apple Push Notifications service (APNs)**, environment **Sandbox & Production**.
  Download the `.p8` and note its **Key ID**. An existing APNs key for the team works too.

### 4. Secrets

One random relay secret, shared by the phone (baked into the build) and the function:

```sh
RELAY_SECRET=$(openssl rand -hex 32)

# GitHub, for the TestFlight build (gh auth login once)
R=DMayoBiologic/GlucOS
gh secret set APPLE_TEAM_ID       -R $R --body "ABCDE12345"
gh secret set APPLE_API_KEY_ID    -R $R --body "<App Store Connect key id>"
gh secret set APPLE_API_ISSUER_ID -R $R --body "<issuer id>"
gh secret set APPLE_API_KEY_P8    -R $R < AuthKey_XXXXXXXXXX.p8
gh secret set RELAY_SECRET        -R $R --body "$RELAY_SECRET"

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
relay's address and secret.

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
- **The relay's forecast is trend-only.** Insulin and food are logged on the Mac, so the relay
  and the phone forecast from the recent trend; the Mac's forecast also uses the logbook.
- **The relay gets your LibreLinkUp login.** The app sends it over HTTPS (with the relay secret).
  It's kept encrypted in Supabase Vault. Signing out on the phone asks the relay to delete it; if
  the relay can't be reached then, the login stays in Vault until it can.
- **Two followers, one account.** The Mac and the relay each poll LibreLinkUp once a minute.
- **Without the relay** the app still works while it's open, and the Lock Screen card updates
  whenever iOS gives it background time.

## Relay reference

Base URL `https://aqlbadbyjuoruwnwyfrc.supabase.co/functions/v1/relay`. Endpoints: `GET /health`,
`GET /v1/status`, `POST /v1/register`, `POST /v1/test` (see `Sources/Core/RelayProtocol.swift`),
all but `/health` with `Authorization: Bearer <RELAY_SECRET>`, and `POST /v1/tick`, which the
schedule calls with a token the migration keeps in Vault.

| Function secret | |
|---|---|
| `RELAY_SECRET` | required; the app sends it as `Authorization: Bearer …` |
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
