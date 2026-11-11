# Sharing live readings

GlucOS can share your glucose live with family, the way Find My shares a location: you send a link in
Messages, and whoever opens it sees your reading, trend and the last 3 hours, updated every minute. With
GlucOS on their iPhone, the reading also stays on their Lock Screen and in their Dynamic Island.

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
  second needs no sensor or LibreLinkUp account: the app shows only the people you follow (no logging,
  no alerts of your own), with **See an Example** until you have a link. Opening a share link before
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

Followers see the same card as your Lock Screen: reading, trend, delta, 3 hours of history and the
forecast. They get your glucose alerts if they leave Alerts on, but never your logbook, insulin or account. Anyone with the link can see it, so
send it only to people you trust, and use an expiry for one-off shares.
