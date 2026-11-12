# Sending GlucOS to anyone: TestFlight

Every merge to main ships the iPhone app to two TestFlight groups:

- **Internal** (you): every build, straight after Apple processes it.
- **Public** (anyone with the link): the same build, after Apple's Beta App Review.

Send people the **public link** (it looks like `https://testflight.apple.com/join/XXXXXXXX`). They
install the TestFlight app, tap the link, and install GlucOS. On first launch they pick **I wear a
sensor** or **I'm following someone**; followers need no sensor or account (docs/Sharing.md).

## What CI does

`scripts/testflight_external.py` runs in the release workflow's `testflight-external` job after
the upload, and every hour from `testflight-link.yml`. It is idempotent:

1. Creates the external group **Public** if it's missing.
2. Fills in the test information testers see: description, privacy policy
   (<https://gluc-os-seven.vercel.app/privacy/>, from `web/privacy/`), and the feedback email.
3. Fills in Beta App Review's notes (how to try follower mode with **See an Example**; no demo
   account needed) and, if App Store Connect doesn't have them yet, the contact details.
4. Waits for the build to process, adds this release's PR titles as **What to Test**, adds it to
   **Public** and submits it for Beta App Review.
5. Turns on the public link (Apple allows that only once a build has passed review, so the
   scheduled run does it as soon as the first approval lands) and prints it in the run summary.

## One-time: contact details for Beta App Review

Apple needs a name, email and phone number for the reviewer to contact. Either fill them in once
at App Store Connect → GlucOS → TestFlight → **Test Information**, or set repository variables
(they're used only where App Store Connect is empty):

```sh
R=DMayoBiologic/GlucOS
gh variable set TESTFLIGHT_CONTACT_FIRST_NAME -R $R --body "Declan"
gh variable set TESTFLIGHT_CONTACT_LAST_NAME  -R $R --body "Mayo"
gh variable set TESTFLIGHT_CONTACT_EMAIL      -R $R --body "you@example.com"
gh variable set TESTFLIGHT_CONTACT_PHONE      -R $R --body "+61 4xx xxx xxx"
```

The email doubles as the feedback address testers see. Until these exist the job adds builds to
**Public** but doesn't submit them, and says so in a warning; the next scheduled run submits the
newest build once they're filled in.

## Limits

- **10,000 external testers** per app, across all external groups. A public link can have its own
  lower cap; GlucOS's has none.
- **Builds expire after 90 days.** Testers keep getting new builds as long as you merge at least
  once every 90 days. An expired build stops opening.
- **Beta App Review** is needed for the first build of each version. Every merge bumps the version,
  so each one is reviewed, but after the first approval Apple usually clears later builds in
  minutes to hours. Until then external testers stay on the previous build.
- Testers need **iOS 17.2** or later and the TestFlight app. TestFlight sends Apple crash reports
  and any feedback testers write to you.

## When the App Store is the better path

TestFlight is right while GlucOS is family and friends testing it. Move to the App Store when you
want people to find it themselves, more than 10,000 people, no 90-day expiry, or automatic updates
without TestFlight. Expect more scrutiny there than in Beta App Review:

- **Medical apps (guideline 1.4.1).** Apps that show health data are reviewed closely, and claims
  of accuracy or treatment use need regulatory clearance. Keep GlucOS a viewer: "not a medical
  device" in the description, screenshots and app, no dosing advice (it gives none today), and be
  ready to explain that readings come from the user's own LibreLinkUp account. Reviewers may also
  ask whether using LibreLinkUp's unofficial API is permitted by Abbott; that is the biggest risk
  to approval.
- **Privacy.** A privacy policy URL (the page above) and the App Privacy "nutrition label" in App
  Store Connect: health data and identifiers linked to the user for app functionality, not used
  for tracking.
- **Account deletion (5.1.1(v)).** Apps with accounts must offer deletion in the app. Logbook sync
  creates a Supabase user per LibreLinkUp account, so the App Store build needs a "Delete my data"
  action that removes it.
- **Demo access.** Reviewers need to see real features: follower mode with the example card helps,
  but they may ask for a working share link.
- **Health disclaimers** in the description and on first launch (the welcome screen has one).

The release automation would change little: the same upload, plus a step that submits the version
for App Store review (`appStoreVersionSubmissions`) when a PR title says so.
