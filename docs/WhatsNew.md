# What's New

Updates install by themselves (Sparkle on the Mac, TestFlight on iPhone), so a new feature can
arrive without anyone noticing. The first time GlucOS opens on a new version, it shows that
release's highlights once.

## Where it shows

- **iPhone**: a sheet, about a second after the app comes to the foreground. Sensor wearers and
  followers both get it. Done or a swipe down closes it.
- **Mac**: a card over the menu bar popover, the next time the popover opens. Sparkle relaunches
  the app by itself after an update, often while nobody is looking, so nothing opens on its own.
  Done, Return or Esc closes it; closing the popover does too.
- **Settings › About › What's New** (iPhone, follower Settings too) and **Settings › Advanced ›
  Updates › What's New…** (Mac) open every release's highlights up to this version, any time.
  Settings search finds it ("what's new", "changelog", "release notes").

The rows rise in one after another (0.06 s apart, 0.35 s each, capped at 8 steps). Under Reduce
Motion they are simply there. Each row reads as one VoiceOver element; the Mac announces the title.

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
  What's New closes and the log sheet opens straight after.

## Adding a release

Each release PR adds an entry at the top of `WhatsNewCatalog.releases`: the version it ships
(`"1.74.0"`), and two or three highlights with an SF Symbol, a short title (40 characters or
fewer) and a one-sentence detail. Plain words, no dosing advice (the tests check for both). A
version without an entry is stored quietly and shows nothing.
