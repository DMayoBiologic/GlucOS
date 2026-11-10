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

### Using it

- **Click the widget** (or a GlucOS notification, or launch GlucOS again from Finder/Spotlight) to open
  the menu bar popover.
- **Widgets** (right-click the desktop → **Edit Widgets** → "GlucOS"):
  - **Glucose** in small, medium, large and extra large. Right-click → **Edit "Glucose"** to pick the
    chart window (automatic, 3h, 6h or 12h) and whether the refresh button and statistics show.
    The refresh button asks GlucOS for a new reading without opening anything.
  - **Time in Range** (small, medium): five-range breakdown, average, GMI and CV over the last 12h,
    24h, 7 or 14 days, from the locally kept history. Warns when the period has gaps in the data.
  - **Sensor** (small): time left on the current sensor and when it ends.

  A reading older than 6 minutes is greyed and marked **Stale**, with no trend arrow; after 30 minutes
  the number is replaced by dashes and "Last 7.2 at 2:05 pm". The chart always runs to *now*, so missing
  data shows as an empty stretch, never a flat line. On a tinted or unfocused desktop, where colour is
  removed, every state is still spelled out in words.
- **The popover** leads with the current reading, how long it's been in that range, and how fresh it
  is (a slim meter fills toward the 6-minute stale mark). Stale readings are greyed, crossed through
  and flagged with a "don't treat from this value" banner. Below that: the chart, your last logged
  dose and meal, and an "At a glance" card (time in range, average, CV, GMI and sensor life over
  24 h, 7 or 14 days).
- **Hover the chart** to read any individual reading and its time, or click it and step through
  readings with ← → (Home/End jump to the ends). The 3h / 6h / 12h control sets the range.
- **Keyboard** in the popover: ⌘L log, ⌘R refresh, ⌘D dashboard, ⌘, settings, ⌘C copy the reading,
  ⌘1 / ⌘2 / ⌘3 chart range, ⌘Q quit. Hold ⌘ to see them. Right-click the reading for the same actions.
- **Dashboard** (⌘D in the popover, or the expand button on the chart): a resizable window with
  - an interactive chart from 3 hours to 30 days: hover for any reading, pinch or ⌘+ / ⌘− to zoom,
    scroll sideways to pan;
  - time in range across five ranges, average, GMI, standard deviation, CV, lowest/highest and data capture;
  - daily patterns (median and percentile bands by time of day) or the last 7 days overlaid;
  - a per-day table with time in range and low episodes, and every reading in a list, exportable as CSV;
  - Keep on Top, to leave it floating beside your work.

  LibreLinkUp only provides the last 12 hours, so GlucOS keeps every reading it sees (up to 90 days)
  in `~/Library/Application Support/GlucOS/history.json`. Longer ranges fill in while GlucOS runs.
- **Insulin & food logging** (⊕ in the popover, or ⌘L in the dashboard). The first time, GlucOS asks
  how you take insulin (injections, pump, or none) and adapts:
  - *Injections*: log units, insulin type and name, and injection site (the picker shows when each
    site was last used, to help rotation). Long-acting doses are logged too.
  - *Pump*: log boluses, food, and infusion site changes. Boluses count against the site in use.
  - Food: grams of carbohydrate and what you ate, on its own or with a dose.
  - Context tags (optional): exercise, unwell, alcohol, stress, period, hypo treatment, site or
    delivery problem. Doses and meals around a tag are kept out of the typical figures in Insights
    (exercise, illness, alcohol, stress and period get their own "With …" rows instead).

  Doses and meals appear on the Overview chart (insulin along the bottom, food along the top, site
  changes as dashed lines) and in **Logbook**, where entries can be edited or deleted. They're kept
  in `~/Library/Application Support/GlucOS/logbook.json`.
- **Insights** show patterns observed in your own data, once there are at least 3 clean examples:
  how soon glucose starts falling after a bolus taken without food, when it stops falling, and how
  far it fell per unit, overall and by body area; the rise after meals, with and without insulin;
  glucose by day of infusion-site wear (pump); and injection-site rotation (injections).
  These are observations, not advice. GlucOS never suggests or calculates a dose, and the
  "drop per unit" is not a correction factor. Talk to your care team before changing anything.
- **Colour-coded menu bar icon** (Settings → Display, off by default): tints the drop green/orange/red by
  range. An urgent low is always shown in colour, whatever the setting. Stale data always shows the
  plain warning sign, with the reading's age in place of the trend arrow.
- **Settings → Alerts** shows whether macOS is allowing GlucOS notifications and can send a test alert.
  If notifications are turned off while alerts are enabled, the popover says so.

### Updates

GlucOS checks `releases/latest/download/appcast.xml` every hour via [Sparkle](https://sparkle-project.org).
A new version downloads in the background, installs, and GlucOS relaunches itself on it: no prompts,
nothing to click, no restart needed. **Check for Updates** in the menu checks on demand.
Downloads are verified with an EdDSA signature, so an ad-hoc-signed build is fine.

## Developing

Requirements: macOS 14+, Xcode 15+, Homebrew. No Apple Developer account needed (ad-hoc signing).

```sh
make            # xcodegen → xcodebuild Release → /Applications → launch
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

### Releases

Merging to `main` ships. [`release.yml`](.github/workflows/release.yml) runs on every push to `main`:
it takes the latest `vX.Y.Z` tag, bumps the patch number, builds on a macOS runner, signs (and
notarizes if the Apple secrets are set), zips, generates the Sparkle appcast, and publishes the GitHub
Release + tag. Every installed copy updates and relaunches itself within the hour. Nothing is committed back to `main`.

- `[minor]` or `[major]` in the PR title / merge commit message bumps that part instead.
- `[skip release]` in the PR title (or commit subject) skips the release; docs-only (`*.md`) pushes are skipped too.
- Re-running a release job for a commit that already shipped rebuilds the same version.
- To force a version: Actions → Release → Run workflow, or `make release V=1.0.0`.

`ci.yml` compiles every push and PR.

## Layout

```
project.yml              XcodeGen spec — app + widget targets, Sparkle package, Info.plist keys
Sources/Shared/          models, stats, shared snapshot store, chart (compiled into both targets)
Sources/App/             menu bar app: LibreLinkUp client, Keychain, poll loop, alerts, Sparkle, views,
                         app delegate (glucos:// URLs, notification presentation), Assets.xcassets (app icon)
Sources/Widget/          WidgetKit extension: Glucose, Time in Range and Sensor widgets, configuration + refresh intents
scripts/make_app_icon.py regenerates the app icon PNGs (Pillow)
.github/workflows/       ci.yml (compile check), release.yml (merge to main → release + appcast)
```

The app polls every 60 s, writes `~/Library/Application Support/GlucOS/snapshot.json`, then calls
`WidgetCenter.reloadAllTimelines()`. The widget only reads that file (and `history.json` for Time in
Range) — no network, no credentials. Its refresh button posts a Darwin notification the app listens for.

## Alerts

Low / high (thresholds in Settings), urgent-low (< 3.0 mmol/L, repeats every 5 min), rising/falling
quickly, no data > 6 min, sensor expiring within 24 h, and "API changed" if Abbott bumps the minimum
client version. Per-type cooldown is configurable.

## When it breaks

| Symptom | Fix |
|---|---|
| "requires client version X" | Settings → Advanced → set the version header to X → Reconnect |
| "terms acceptance required" | Open LibreLinkUp on your phone, accept the new T&Cs |
| "not following anyone" | Accept the invitation in the LibreLinkUp app (not LibreLink) |
| Stale data, phone fine | LibreLink must be running in the background with internet |
| Widget shows "no data" | App must have run once; Advanced tab shows the snapshot path |
| "Updates not configured" | Build has no Sparkle public key — run `make sparkle-keys`, re-release |
| Release job fails on key | `SPARKLE_PRIVATE_KEY` secret missing — `make sparkle-keys` |

The LibreLinkUp API is unofficial and reverse-engineered; Abbott can change it at any time.
