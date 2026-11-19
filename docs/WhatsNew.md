# What's New

Updates install by themselves (Sparkle on the Mac, TestFlight on iPhone), so a new feature can
arrive without anyone noticing. The first time GlucOS opens on a new version, it shows that
release's highlights once.

## Where it shows

- **iPhone**: a sheet, about a second after the app comes to the foreground. Sensor wearers and
  followers both get it. Continue or a swipe down closes it.
- **Mac**: a card over the menu bar popover, the next time the popover opens. Sparkle relaunches
  the app by itself after an update, often while nobody is looking, so nothing opens on its own.
  Continue, Return or Esc closes it; closing the popover does too.
- **Settings › About › What's New** (iPhone, follower Settings too) and **Settings › Advanced ›
  Updates › What's New…** (Mac) open every release's highlights up to this version, any time.
  Settings search (Mac, and iPhone Settings for sensor wearers) finds it ("what's new", "changelog",
  "release notes"). Follower Settings has the row but no search.

The rows rise in one after another (0.06 s apart, 0.35 s each, capped at 8 steps). Each row's
symbol, and the sparkles over the title, plays one SF Symbols bounce as it settles (0.2 s into its
rise), never repeating. Continue fades in last, 0.1 s after the last row lands (under a second
however long the list); Return, Esc and VoiceOver reach it before then. Under Reduce Motion the
rows and Continue simply fade in together (0.25 s), with no movement and no symbol effects. Each
row reads as one VoiceOver element, and VoiceOver focus starts on the title (0.55 s after opening,
0.25 s under Reduce Motion) on both iPhone and Mac. Timings: `WhatsNew.symbolDelay`,
`continueDelay`, `titleFocusDelay`, tested in `WhatsNewTests`.

## When it shows

Rules in `Sources/Engine/WhatsNew.swift` (`WhatsNew.decide`), tests in `WhatsNewTests`.

- The stored version (`whatsNewLastSeenVersion` in UserDefaults) is the last one shown.
- **Fresh install**: nothing shows; the version is stored straight away. A fresh install is "no
  stored version and not used before" (iPhone: not signed in, not following, still on the welcome
  screen; Mac: setup not done).
- **Update**: shows the releases after the stored version, up to this one, newest first, at most 3.
  The first update after What's New shipped (no stored version but already in use) shows the latest
  release up to this version.
- **Never twice**: the version is stored once the sheet or card is on screen. A launch where it
  couldn't show (a log sheet or the setup sheet opening, a low reading) leaves it for next time.
  A downgrade shows nothing and never moves the stored version back.
- A patch release, or a version with no entry, is stored quietly.
- **During a low** (below the target range) the automatic sheet waits, so the reading stays in
  view. Settings still opens it.
- iPhone checks only in the foreground: a background launch before first unlock can't read the
  sign-in and would look like a fresh install.
- A log sheet asked for while What's New is up (a notification's Log treatment, a widget, Siri):
  What's New closes and the log sheet opens straight after, unless a newer log request arrived in
  that moment, which then wins.

## Adding a release

Each release PR adds an entry at the top of `WhatsNewCatalog.releases`: the version it ships
(`"1.74.0"`), and two or three highlights with an SF Symbol, a short title (40 characters or
fewer) and a one-sentence detail. Plain words, no dosing advice (the tests check for both). A
version without an entry adds nothing of its own: someone who
skipped a listed release still catches up on it, otherwise the version is stored quietly.
