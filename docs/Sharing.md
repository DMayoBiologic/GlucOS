# Sharing live readings

GlucOS can share your glucose live with family, the way Find My shares a location: you send a link in
Messages, and whoever opens it sees your reading, trend and the last 3 hours, updated every minute. With
GlucOS on their iPhone they get close to your own screen (see "What followers see"), the reading stays
on their Lock Screen and in their Dynamic Island, and they can check in on you at any time.

GlucOS is also in the Messages **+** drawer. From there it sends a live bubble that keeps updating in
the chat for anyone with GlucOS. Messages has no public API for Apple's own Live Location bubble, which
updates even with the app closed, so a GlucOS bubble only updates while it's on screen. The Live Activity
on the follower's phone, and the live web page for anyone without the app, cover everything else.

## Using it

- **Share**: on the iPhone, tap the people icon at the top left of the home screen, or go to Settings →
  Sharing. Choose a name to show followers and how long the link lasts (1 hour up to "until I stop"),
  then send it in Messages.
- **Share from a chat**: in Messages, tap **+**, then **GlucOS** (under **More** the first time). Pick how
  long it lasts and tap **Send Live Glucose**. That makes a link and puts two things in the message field:
  the live bubble, and the plain link for anyone without GlucOS. The bubble shows your reading, trend and
  last 3 hours. In the chat it refreshes every 30 seconds while it's on screen, and its **Follow** button
  opens GlucOS to put the reading on the Lock Screen. On a phone without GlucOS, or on a Mac, it shows a
  picture of the reading from when it was sent.
- **Follow**: open the link. In a browser it shows the live view. Tap **Open in GlucOS** to follow in the
  app, which puts the reading on your Lock Screen and sends you their alerts. You can also paste a link
  with **+** on the Following screen or **Follow Someone** in Settings.
- **Following without a sensor**: a new install asks "I wear a sensor" or "I'm following someone". The
  second needs no sensor or LibreLinkUp account: the app's home is the person you follow, shown the way
  they see themselves (no logging, no alerts of your own), with **See an Example** until you have a link.
  Following more than one person puts a row of them, each with their reading, at the top to switch. Opening a share link before
  choosing picks it for you. **I Wear a Sensor Too** in its Settings signs in later and keeps your follows.
- **Their alerts**: each follow has an **Alerts** switch (on by default; in the card's ⋯ menu and in
  Settings). With it on, the relay sends you the sharer's glucose alerts as they fire for them (lows,
  highs, fast changes, predicted lows and highs, no data), titled with their name, e.g. "Declan: Low
  glucose — 3.6". Sensor-expiry and account alerts stay with the sharer. They're time-sensitive
  notifications, so allow GlucOS in any Focus you use at night.
- **Stop**: Settings → Sharing → Stop Sharing. The link stops working at once and followers' Lock Screen
  cards are removed. Links with an expiry stop by themselves.

Followers need GlucOS on their iPhone for the Lock Screen card and alerts: send them the public TestFlight
link (docs/TestFlight.md). The web view works anywhere.

## What followers see

In GlucOS, a followed person's screen is built from the same Signal pieces as the owner's home
(`FollowPersonView`, Sources/iOS/Views/FollowPersonViews.swift). On a follower-only phone it's the home
screen; on a phone that also wears a sensor, tapping a following card opens it.

- **Stage**: range pill and how long they've been in it, the value with its needle, the range rail with
  the forecast's ghost marker, the forecast note and the freshness meter, on their range field.
- **Check in**: a card under the stage and a bar along the bottom, at any reading. While they're low or
  forecast low it turns amber and says so. It shows the latest check-in (waiting, no answer, okay, needs
  help) and asks for the follower's name right there if it's missing.
- **On board**: insulin and carbs still acting, worked out from their logbook (`OnBoardNow`), and the
  forecast's headline. The forecast is the relay's trend-only one, the same as their Lock Screen card.
- **Chart**: 3, 6, 12 or 24 hours, with their insulin, food and wake-ups marked and the forecast past Now.
- **Logbook**: the last 24 hours grouped by day, read-only, with See All for 48 hours.
- **Time in range**: 24 hours, 7 or 14 days (ring, average, GMI, CV, range bar), and the last seven days
  as columns.

The data is the share function's `GET /v1/detail?since=<seconds>` (supabase/functions/share/detail.ts):
readings from `glucos.readings` in 5-minute buckets (14 days on the first load, then only what's new,
`FollowHistory`), and the owner's doses, meals, site changes and moments from the last 48 hours. The
owner's Supabase user is the one the relay's forecast ledger found from its LibreLinkUp login
(`work.forecastLog.owner`); until the owner's apps have signed in to logbook sync, there's no logbook.
Notes are blanked and bolus calculator workings left out. Saved insulins, foods, presets and settings
are never shared.

Each link has a **Show my logbook** switch (Sharing, on each link, and when making one; on by default,
`glucos.shares.shows_logbook`, relay `POST /v1/shares/update`). Off, followers still get readings, chart
and time in range.

## How it works

```
 owner's iPhone ──POST /v1/shares──▶ relay ──every minute──▶ APNs ──▶ follower Live Activities
                                       │
                                       └─ work.latestCard ──▶ share function ◀── web view / follower app
```

- `supabase/functions/relay` creates, lists and revokes shares for the owner (relay secret). On each
  tick it saves the newest card as `work.latestCard` and pushes it to every follower's Live Activity.
  It uses the same rules as the owner's card: resend on change or every 10 minutes, replace before iOS's
  8-hour limit using the follower's push-to-start token, and end the card when the share expires or is
  revoked. When the owner's alerts fire, followers with alerts on (`glucos.followers.alerts_enabled`
  and a `device_token`) get them too (`followerAlertKinds` in engine.ts).
- `supabase/functions/share` is public. The share token is the credential (`Authorization: Bearer`). It
  serves the snapshot for the web view and takes follower phones' push tokens. A revoked, expired or
  unknown token gets 404.
- `glucos.shares` keeps only a SHA-256 of each token (32 random bytes). `glucos.followers` holds each
  follower phone's Live Activity tokens. Both tables have RLS on with no policies, like the relay's own.
- A follower's Live Activity is `GlucoseActivityAttributes` with `followID` set to the share id and
  `name` set to the share's label. The owner's own card has `followID == nil`. `LiveActivityController`
  only touches the owner's card and `FollowStore` only touches follower cards.
- The web view is `web/share/index.html`, served by the `gluc-os` Vercel project at
  `https://gluc-os-seven.vercel.app/share/` (`vercel.json` serves `web/` as static files, no build). The
  token is in the URL fragment, so it never reaches Vercel or Messages' link-preview fetch.

Limits: 20 live links, 10 follower phones per link, and expiry between 10 minutes and 90 days (or none).

## Check-ins

When the person you follow is low, or forecast to go low, their card on your Lock Screen (and in the
Dynamic Island and the app) shows **Check in**. Their low alerts on your phone have the same button.
Tapping it asks them if they're okay, without opening GlucOS:

1. They get a time-sensitive notification, "Sam checking in: Are you okay? Your glucose is 3.4 mmol/L",
   with **I'm okay** and **I need help** buttons that work from the Lock Screen without unlocking. Their
   own Lock Screen card shows "Sam is checking in" with the same two buttons, and so does the top of the
   app.
2. Your card shows "Checked in 10:42 · waiting" straight away.
3. When they answer you get a notification ("Declan is okay", or a critical "Declan needs help"), and
   your card shows the answer and its time for 30 minutes.
4. No answer after 5 minutes: they're asked again, as a critical alert when the relay may send those
   (`APNS_CRITICAL_ALERTS`), and you're told ("No answer from Declan... If you can, call them"). Your
   card shows "No answer since 10:42" with **Ask again**. Everyone else following them hears too
   ("Sam checked in on Declan 5 minutes ago and hasn't heard back"), with a **Check in** button of their
   own, if they have alerts on. When the answer comes, they get it as well. An unanswered check-in
   lapses after an hour.

The same buttons are on the card on an Apple Watch (Smart Stack) and in CarPlay. There the range rail
makes way for a short note and the buttons; the tap runs on the iPhone, as it does from the Lock Screen.

One answer covers everyone waiting. Tapping Check in again re-notifies at most every 2 minutes. Set
your name under Settings, Following, so the person knows who's asking ("Someone who follows you"
otherwise).

How it runs:

- The follower asks through the `share` function, `POST /v1/checkin {installation, name}`, with the
  share token. It records the check-in in `glucos.check_ins` and sends the owner's notification at
  once, with the relay's APNs key and cached provider token. `GET /v1/snapshot?installation=…` also
  returns that phone's latest check-in, so the app's own updates of the card keep it.
- The owner answers through the relay, `POST /v1/checkins/answer {answer: "okay" | "help"}`, with the
  relay secret. Every follower waiting gets a notification at once. `RelayStatus.checkIn` says who's
  waiting.
- The relay's minute tick puts each follower's check-in on their card and the waiting one on the
  owner's (`checkIn` in the card's content state, `CheckInState` in Swift), sends the 5-minute
  reminders once (`reminded_at`), and pushes any change at priority 10.
- The Live Activity buttons are `LiveActivityIntent`s (`Sources/iOSIntents`), compiled into the widget
  and the app. iOS runs them in the app's process, so they use the app's Keychain and network.
  Notification buttons are the `glucos.checkin` and `glucos.follow.low` categories
  (`Sources/iOS/CheckIns.swift`). Neither needs the phone unlocked.

Rules and wording are in `supabase/functions/relay/checkins.ts`; tests in `checkins_test.ts` and
`checkins_pg_test.ts`.

## Setup

The functions and migration deploy on merge, like the rest of `supabase/`. The web view deploys on merge
through Vercel's GitHub integration (pushes that don't touch `web/` or `vercel.json` skip the build).

### The Messages app

`Sources/iOSMessages` is an iMessage app extension (`au.com.declanmayo.glucos.ios.messages`) embedded in the
iPhone app. Its bubble is an `MSMessageLiveLayout` whose URL is the share's web link. Messages runs the
extension in transcript style to draw the bubble, and the extension polls the `share` function for
that link's snapshot. The alternate `MSMessageTemplateLayout` holds a picture rendered at send time.

The extension can't read the app's Keychain, so the app copies its relay settings into the app group
(`SharedStore.defaults`). The build bakes in only the relay URL; the secret reaches the extension
through the app group once the owner's iPhone has claimed it (docs/iOS.md), so on anyone else's phone
the extension can't make links. Links made in Messages keep their token in the app group
(`MessagesShareLinks`), so the app's Sharing screen can send them again.

## Privacy

In a browser, followers see the same card as your Lock Screen: reading, trend, delta, 3 hours of history
and the forecast. In GlucOS they also see up to 14 days of readings and, unless you turn off **Show my
logbook** for that link, your insulin, food, site changes and moments from the last two days, without
notes. They get your glucose alerts if they leave Alerts on, but never your saved insulins, foods,
settings or account. Anyone with the link can see it, so
send it only to people you trust, and use an expiry for one-off shares.
