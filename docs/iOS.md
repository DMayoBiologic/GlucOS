# GlucOS on iPhone

The iPhone app shows the same cards as the Mac popover (reading, trend, chart with forecast,
outlook, time in range, sensor), keeps a **Live Activity** on the Lock Screen and in the Dynamic
Island, and sends low/high alerts. It also has Lock Screen and Home Screen widgets.

```
LibreLinkUp ──► push relay (Fly.io, every 60 s) ──APNs──► iPhone: alerts + Lock Screen card
           └──► iPhone app (while it's open)
```

## Why there's a relay

iOS doesn't let apps run in the background. An app gets the odd background refresh when iOS feels
like it (anything from 15 minutes to hours apart), so on its own the iPhone app could only alert
and update the Lock Screen while it's open. That isn't good enough for lows.

So GlucOS has a **push relay**: a tiny server of your own (`Relay/`, Swift on Linux) that fetches
from LibreLinkUp every minute, runs the *same* alert rules and forecast code as the apps, and
sends Apple push notifications:

- **Alerts** as normal push notifications, delivered with the phone locked and the app closed.
  They're *time-sensitive*, so they get through Focus modes you allow them in.
- **Lock Screen card updates** pushed straight to the Live Activity about once a minute.
- iOS ends any Live Activity after 8 hours; the relay ends it a little early and starts a fresh
  one with a push, so the card stays on the Lock Screen.

While the relay is healthy the phone leaves alerts to it, so nothing arrives twice. If the relay
is down, the app falls back to alerting by itself while it's open.

## Setup (one time, about 30 minutes)

Everything else ships on merge, like the Mac app. These are the steps only you can do, because
they need your Apple account, a credit card or a secret. Until a step's secrets exist, its
release job just skips with a notice; the Mac release is never affected.

### 1. Apple Developer Program

Join at <https://developer.apple.com/programs/> (A$149/year). Note your **Team ID**
(developer.apple.com → Account → Membership details).

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
  one chance) and note the **Key ID** and **Issuer ID**.
- **APNs key** (lets the relay push): developer.apple.com → Certificates, IDs & Profiles → **Keys**
  → **+** → tick **Apple Push Notifications service (APNs)**, environment **Sandbox & Production**.
  Download the `.p8` and note its **Key ID**.

### 4. Hosting

Sign up at <https://fly.io> (needs a card; an always-on 256 MB machine is about US$2–3 a month),
then create a deploy token: dashboard → **Tokens** → **Create token**.

### 5. Repo secrets

From a clone of the repo (`gh auth login` once):

```sh
R=DMayoBiologic/GlucOS
gh secret set APPLE_TEAM_ID       -R $R --body "ABCDE12345"
gh secret set APPLE_API_KEY_ID    -R $R --body "<App Store Connect key id>"
gh secret set APPLE_API_ISSUER_ID -R $R --body "<issuer id>"
gh secret set APPLE_API_KEY_P8    -R $R < AuthKey_XXXXXXXXXX.p8
gh secret set APNS_KEY_ID         -R $R --body "<APNs key id>"
gh secret set APNS_KEY_P8         -R $R < AuthKey_YYYYYYYYYY.p8
gh secret set FLY_API_TOKEN       -R $R --body "<fly token>"
openssl rand -hex 32 | gh secret set RELAY_SECRET -R $R
```

`APPLE_API_*` are the same names the Mac notarization step uses; they don't change the Mac build
unless the Developer ID certificate secrets are also set.

### 6. Ship and install

Re-run the latest **Release** workflow (Actions → Release → Run workflow) or merge anything. The
relay deploys to `https://glucos-relay-dmayobiologic.fly.dev` and the iPhone build uploads to
TestFlight (Apple takes 5–20 minutes to process it). The build already knows the relay's address
and secret.

On the iPhone: install **TestFlight**, open the GlucOS invite, install, sign in with your
LibreLinkUp follower account, and allow notifications. Settings → Push relay should say
"Alerts: Sent by the relay" within a minute, and the card appears on the Lock Screen.

## Good to know

- **Don't force-quit GlucOS** (swiping it away in the app switcher). iOS won't wake a force-quit
  app, so when the relay starts the next 8-hour Lock Screen card the phone can't hand back its new
  push token, and the card stops updating until you open GlucOS again. Alerts are unaffected.
- **Alerts don't bypass the silent switch.** That needs Apple's Critical Alerts entitlement,
  which you request at <https://developer.apple.com/contact/request/notifications-critical-alerts-entitlement/>.
  Once granted, add the entitlement to the app and set `APNS_CRITICAL_ALERTS=true` on the relay.
- **The relay's forecast is trend-only.** Insulin and food are logged on the Mac, so the relay
  and the phone forecast from the recent trend; the Mac's forecast also uses the logbook.
- **The relay gets your LibreLinkUp login.** The app sends it over HTTPS (with the relay secret)
  so the relay can fetch; it's stored owner-only on the relay's volume and forgotten when you sign
  out on the phone.
- **Two followers, one account.** The Mac and the relay each poll LibreLinkUp once a minute. If
  Abbott starts rate-limiting (HTTP 429), raise `POLL_SECONDS` on the relay.
- **Without the relay** the app still works while it's open, and the Lock Screen card updates
  whenever iOS gives it background time.

## Relay reference

| Env var | |
|---|---|
| `RELAY_SECRET` | required; the app sends it as `Authorization: Bearer …` |
| `APNS_KEY_P8`, `APNS_KEY_ID`, `APPLE_TEAM_ID` | APNs auth; without them it fetches but can't push |
| `APNS_BUNDLE_ID` | default `au.com.declanmayo.glucos.ios` |
| `DATA_DIR` | default `/data` (state, tokens, last 48 h of readings) |
| `POLL_SECONDS` | default 60, minimum 30 |
| `APNS_CRITICAL_ALERTS` | `true` once Apple grants Critical Alerts |

Endpoints: `GET /health`, `GET /v1/status`, `POST /v1/register`, `POST /v1/test` (see
`Sources/Core/RelayProtocol.swift`). Run it anywhere Docker runs:

```sh
docker build -f Relay/Dockerfile -t glucos-relay .
docker run -p 8080:8080 -v glucos:/data -e RELAY_SECRET=… -e APNS_KEY_P8="$(cat key.p8)" \
  -e APNS_KEY_ID=… -e APPLE_TEAM_ID=… glucos-relay
```

The relay compiles the shared sources through symlinks in `Relay/Sources/RelayKit/Core`, so the
alert rules, forecast and LibreLinkUp client are the same code as the apps. `cd Relay && swift test`.
