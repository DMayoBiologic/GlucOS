# GlucOS

Native macOS menu bar app + desktop widgets for FreeStyle Libre glucose, fed by Abbott's
LibreLinkUp follower service. Read-only: it never touches the sensor or the LibreLink phone app.

```
sensor → LibreLink (phone) → LibreView cloud → LibreLinkUp API → GlucOS (Mac) → widget
```

**Not a medical device.** Confirm on your phone before treating. The follower feed lags 1–3 min
and silently stops if the phone loses signal; GlucOS flags stale data, but your phone's alarms
are the real ones.

## Install

Grab `GlucOS-x.y.z.zip` from the [latest release](https://github.com/DMayoBiologic/GlucOS/releases/latest),
unzip, drag to `/Applications`, right-click → Open the first time (it's self-signed). Or:

```sh
make install-release
```

First launch: drop icon in the menu bar → **Settings…** → LibreLinkUp *follower* email/password,
region **Australia** → **Save & Connect**. Then **Display → Launch at login**, and add a widget via
right-click desktop → **Edit Widgets** → "GlucOS".

### Updates

GlucOS checks `releases/latest/download/appcast.xml` every 6 h via [Sparkle](https://sparkle-project.org)
and installs new versions automatically (applied on relaunch). **Updates** in the menu checks on demand.
Downloads are verified with an EdDSA signature, so an ad-hoc-signed build is fine.

## Developing

Requirements: macOS 14+, Xcode 15+, Homebrew. No Apple Developer account needed (ad-hoc signing).

```sh
make            # xcodegen → xcodebuild Release → /Applications → launch
make test       # unit tests for the shared models, stats and history merge
make open       # open in Xcode
```

### One-time release setup

```sh
make sparkle-keys
```

Generates the Sparkle EdDSA key pair with Sparkle's own tool, stores the private key in your login
Keychain *and* as the repo secret `SPARKLE_PRIVATE_KEY`, sets repo variable `SPARKLE_PUBLIC_ED_KEY`,
writes the public key into `project.yml` and pushes. Needs `gh auth login` once.

Optional repo secrets for proper Developer ID signing + notarization (needs a paid developer account):
`MACOS_CERTIFICATE_P12` (base64 .p12), `MACOS_CERTIFICATE_PASSWORD`, `APPLE_API_KEY_ID`,
`APPLE_API_ISSUER_ID`, `APPLE_API_KEY_P8`. Without them releases are ad-hoc signed.

### Cutting a release

```sh
make release V=0.2.0
```

Bumps `MARKETING_VERSION`, tags `v0.2.0`, pushes. [`release.yml`](.github/workflows/release.yml)
then builds on a macOS runner, signs, zips, generates the appcast, and publishes the GitHub Release.
Every installed copy updates itself within 6 h. `ci.yml` compiles every push.

## Layout

```
project.yml              XcodeGen spec — app + widget targets, Sparkle package, Info.plist keys
Sources/Shared/          models, stats, shared snapshot store, chart (compiled into both targets)
Sources/App/             menu bar app: LibreLinkUp client, Keychain, poll loop, alerts, Sparkle, views
Sources/Widget/          WidgetKit extension: timeline provider + small/medium/large views
Tests/                   XCTest logic tests (Shared sources compiled in, no host app)
.github/workflows/       ci.yml (build + tests), release.yml (tag → release + appcast)
```

The app polls every 60 s, writes `~/Library/Application Support/GlucOS/snapshot.json`, then calls
`WidgetCenter.reloadAllTimelines()` — only when something the widget shows actually changed, to stay
inside WidgetKit's reload budget. The widget only reads that file — no network, no credentials.

LibreLinkUp's graph endpoint only returns ~12 h of 15-minute points, so GlucOS keeps its own history:
older points it already had, the graph points, and the 1-minute live readings since the last graph
point. That gives a chart that reaches "now", a delta over ~5 minutes rather than ~15, and 24 h of
stats. Stats are time-weighted (each reading counts for the time until the next, capped at 15 min),
so the dense recent readings don't skew time-in-range, and gaps don't count as time spent at the
last value. The chart breaks the line over gaps longer than 15 min.

On errors the poll interval backs off exponentially (up to 15 min). A rejected password pauses
polling until **Save & Connect** — repeated bad logins can get the account locked.

## Alerts

Low / high (thresholds in Settings), urgent-low (< 3.0 mmol/L, repeats every 5 min), rising/falling
quickly, no data > 6 min, sensor expiring within 24 h, and "needs attention" when the login stops
working (wrong password, new T&Cs, no one followed, API change). Per-type cooldown is configurable.
"Very high" is above 13.9 mmol/L or your high threshold, whichever is higher.

## When it breaks

| Symptom | Fix |
|---|---|
| "requires client version X" | Normally adopted automatically. If it persists: Settings → Advanced → set the version header to X → Reconnect |
| "Paused — fix the login" | Correct the password in Settings → **Save & Connect** |
| "terms acceptance required" | Open LibreLinkUp on your phone, accept the new T&Cs |
| "not following anyone" | Accept the invitation in the LibreLinkUp app (not LibreLink) |
| Stale data, phone fine | LibreLink must be running in the background with internet |
| Widget shows "no data" | App must have run once; Advanced tab shows the snapshot path |
| "Updates not configured" | Build has no Sparkle public key — run `make sparkle-keys`, re-release |
| Release job fails on key | `SPARKLE_PRIVATE_KEY` secret missing — `make sparkle-keys` |

The LibreLinkUp API is unofficial and reverse-engineered; Abbott can change it at any time.
