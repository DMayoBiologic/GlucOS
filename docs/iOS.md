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

### Siri and Shortcuts

Two more App Shortcuts (Siri, Spotlight, Shortcuts, the Action button), in
`Sources/iOS/GlucoseIntents.swift`, with their phrases in `GlucOSAppShortcuts`:

- **"What's my glucose in GlucOS"** (also "What's my GlucOS reading", "Check my glucose in GlucOS")
  answers out loud without opening the app: the reading, its range, trend, change and age, then the
  forecast's caveat line when there is one ("About the forecast: Trend only for now: …"). The words
  are the widgets' spoken reading (`SpokenGlucose`, tests `SpokenGlucoseTests`). If the saved
  reading isn't fresh it asks for a new one and waits up to 8 seconds. A reading older than 6
  minutes is said to be **stale**, with its age, and never as the current glucose: no range, no
  trend, no forecast. Past 30 minutes it says there's no recent reading and when the last was. It
  also returns the sentence as text, for a Shortcut to use.
- **"Log treatment in GlucOS"** (also "I'm treating a low in GlucOS") opens the app on the same
  low treatment sheet as the inline Log treatment button and the alert's button (`.treating(.low)`,
  docs/AlertActions.md), filled in from your "Treat a low" usual. **It never logs anything by
  itself**: you check it and tap Log.

### Control Center controls

Two controls for Control Center, the Lock Screen's bottom buttons and the Action button (iOS 18),
in `Sources/iOSWidget/GlucoseControls.swift`, with their taps in `Sources/iOSIntents/ControlIntents.swift`:

- **Glucose** shows the latest reading, trend and age, "6.1 ↗ · 2m", the same line as the inline Lock
  Screen widget (`ControlGlance`, tests in `WidgetGlanceTests`). Once the reading is older than 6
  minutes it says **"Stale 6.1 · 12m"** with a clock symbol and no trend; past 30 minutes it shows no
  number, "No reading for 45m". VoiceOver reads the widgets' spoken reading, then "Opens Today in
  GlucOS". A tap opens the app on Today (out of Settings or Sharing; an open log sheet stays). The
  app reloads it with the Glucose widgets (`WidgetReload.Group.glucose.controlKinds`, through
  `ControlCenter.reloadControls`), so its age is as of the app's last fetch.
- **Log treatment** opens the same low treatment sheet as the inline button, the alert's button and
  the Siri shortcut (`.treating(.low)`). **It never logs anything by itself**. It's a fixed button,
  so it's never reloaded.

### Home Screen quick actions

Long-press the GlucOS icon for four quick actions (`HomeQuickAction` and `HomeQuickItem` in
`Sources/App/HomeQuickActions.swift`, tests `HomeQuickActionTests`; the app side is
`PhoneQuickActions` and `PhoneSceneDelegate` in `Sources/iOS/GlucOSPhoneApp.swift`):

- **Log treatment** opens the same low treatment sheet as Siri, the control and the alert's button
  (`.treating(.low)`), filled in from the "Treat a low" usual when there is one. **It never logs
  anything by itself.**
- **Log meal** opens the log sheet on food. When there's a usual meal for this part of the day
  ("Usual breakfast", docs/UsualEntries.md), it takes this place instead and opens the sheet filled
  in from it, the same as the Your Usual widget's button. iOS shows four items at most, which is why
  it replaces Log meal rather than joining it. The usual correction and Treat a low are never offered
  here: a correction is a dose amount that only applies while a fresh high lasts, and Log treatment
  already covers the low.
- **Log insulin** opens the log sheet on the dose step, empty. **No units are ever filled in.**
- **What's my glucose** opens Today (out of Settings, Sharing or a pushed screen; an open log sheet
  stays) and fetches a new reading straight away.

The list is set from code at launch, on each return to the app and whenever the Your usual entries
or the phone's mode change, so it appears after the first launch. iOS keeps the last list while the
app isn't running, so a usual meal can outlast its part of the day; a tap then opens the sheet, which
works the entry out again and starts on food with nothing filled in if it's no longer offered.
Entries saved from a quick action's sheet get the one-time "Logged from the Home Screen" highlight
(docs/LoggedElsewhere.md). A follower-only phone gets only **Latest readings**, which opens the
people it follows; leftover logging items do nothing there. A phone that hasn't picked a mode gets
none. The titles are read by VoiceOver as shown, and every sheet opens the way it does from inside
the app, Reduce Motion included.

The **Your Usual** Home Screen widget (medium) shows the same "Your usual" entries as the log sheet,
up to three. A tap opens the log sheet filled in from that entry, the same as tapping its tile there;
nothing is logged until you tap Log, after the logged-twice check (docs/UsualEntries.md).

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
- **Low and high alerts have two buttons.** *Snooze 30 min* quiets your own alerts (followers still
  get every one), and *Log treatment* opens the log sheet on your usual low treatment or a
  correction. Urgent lows can't be snoozed. See [AlertActions.md](AlertActions.md).
- **See the figures for part of the chart.** Rest two fingers on the Today chart for a moment, then drag them. A band covers that stretch and a card shows its average, lowest, highest, time in range and change. Lift your fingers to put it away. With VoiceOver, swipe up or down on the chart to hear the same figures for the last 30 minutes, hour, 2 hours and so on.
- **Pull down on Today to refresh.** A ring fills as your readings arrive and you feel a light tap when there's something new. Under Reduce Motion you get the standard system indicator.
- **Your alerts are in the Logbook.** Each low or high alert gets a quiet row showing when it went off and what you did about it. Use the filter to hide these rows. They never count as treatments.
- **Search the Logbook by day.** Try "pizza last week" or "fri" in the search box. The Meals, Insulin, Lows and Notes chips narrow the list, and what matched is highlighted.
- **Open an entry in the Logbook.** Tap an entry in the full Logbook to see everything about it where it sits, with Edit, Log Again and Delete. Tap it again, tap outside or drag down to close.
- **Swipe a Logbook row.** Swipe right and tap Log Again Now to log the same entry again at the current time, exactly as it was logged (same units, insulin, site, carbs and food). It needs a tap, so a flick never logs a dose twice. Swipe left to delete; the Undo toast brings it back. On the Mac, right-click a row for the same two actions.
- **A new sensor counts down its warm-up.** For the sensor's first hour, Today and the Live Activity show a ring that fills and "Readings start in about N min" in place of the old sensor's last reading. The first reading cross-fades in when it arrives. Signed in with no readings at all, Today says what to do next and offers Check Again.
- **"Back in range ≈ 20 min".** When you're high, Today shows roughly when you'll be back in range. It only appears while your own past estimates have usually been within 15 minutes, and it is never shown for lows. The Live Activity and the Lock Screen and Home Screen widgets show it too, under the same rule. While the app is closed the Lock Screen card comes from the relay, which only shows it once its own estimates have passed the same check.
- **The reading rolls, it doesn't jump.** On Today the number rolls to each new value, its colour fades when you cross a range edge, and the trend arrow turns. Under Reduce Motion the number just changes.
- **Taking your Logbook to the clinic.** Export it from the Logbook: pick the days, then share a PDF summary or a CSV. It's made on the phone, works offline and never includes follower data (docs/LogbookExport.md).
- **The forecast draws in.** On Today, the forecast line draws out from Now when you open the app and bends smoothly into each new forecast, as on the Mac. With Reduce Motion on, it just changes.
- **Your usual day moves.** In Insights, the bands of Your usual day draw in when the card appears and glide when you switch between 14 and 30 days. With Reduce Motion on, they just change.
- **Today so far moves.** On Today, the Today so far card counts up when it first shows, and its figures roll as new readings come in. With Reduce Motion on, they just change.
- **Insights glides between periods.** Range bars glide, Day by day columns grow to their new heights, Week in review cross-fades and every figure rolls when you change period. With Reduce Motion on, they just change.
- **Each Logbook day shows its time in range.** A thin bar with the percentage sits on every day header and draws in once; VoiceOver reads it, for example "Tuesday, 78% in range".
- **A snooze shows on the Lock Screen.** While alerts are snoozed, the Lock Screen card and the Dynamic Island show a bell-slash with the time the snooze ends, even with the app closed, and VoiceOver reads it.
- **Log treatment from Today.** During a low, or when one is predicted, Today shows a Log treatment button that opens the log sheet filled in with your usual low treatment. It never logs by itself.
- **Highs have their own Insights card.** It shows your time above range, how many highs you had and the longest one, and tapping it opens the Logbook on Highs over the same days.
- **What you logged last shows under the chart.** A quiet line such as "Meal 1 h 40 m ago · 45 g" appears on Today, and tapping it opens that entry in the Logbook. It hides when nothing was logged in the last 12 hours.
- **Nights have their own Insights card.** The Overnight card shows your time in range from midnight to 6 am, overnight lows and the usual change across the night, and tapping it opens the Logbook on those nights.
- **Weekdays and weekends side by side.** An Insights card compares time in range, average glucose and lows on weekdays and weekends, and tapping either side opens the Logbook on those days.
- **Entries logged from elsewhere are pointed out once.** Something you log from Siri, a control, an alert or a widget gets a brief highlight and a caption on its Logbook row and chart marker the next time you open the app.
- **Pinch the Today chart to change its span.** Spread two fingers for fewer hours or pinch together for more, stepping through 3, 6, 12 and 24 hours like the control above it. The axes spring to the new span (with Reduce Motion on, it cross-fades), and the app opens on the span you chose last.
- **Insights cards go in the order you choose.** Tap Edit in Insights, or touch and hold a card, to drag cards into a new order or hide them. Hidden cards stay in a Hidden section until you bring them back, and new cards show up by default.
- **Streaks of good days.** The In-range streaks card in Insights shows your current and longest run of days at 70% or more in range, with the last 14 days as dots. The run and the dots count back from the latest reading, so after readings stop they describe the days up to then. Tap it to open the Logbook on the longest run.
- **Best and toughest days.** An Insights card picks the whole days with the most and least time in range over the last 7, 14 or 30 days, each with a small chart of the day that draws in (a cross-fade with Reduce Motion on). Tap either day to open the Logbook on it.
- **StandBy shows your glucose at a glance.** When the iPhone is charging on its side, the Glucose widget in StandBy shows a large reading, the trend arrow and a thin range band. It dims under the red Night Mode tint and updates without flicker.
- **An evening recap, if you want one.** Turn it on in Settings and pick a time (9 pm by default). Each evening a notification gives the day's time in range, average, lows and highs; tap it to open Insights on a Today card.
- **Tag entries to find them later.** In the log sheet, add a tag such as Exercise, Sick, Stress, Alcohol or one of your own. Each tag becomes a filter chip in Logbook search, and tags sync with the Mac.
- **See what your tags do.** Once you've tagged entries, a Tags card in Insights shows time in range and average glucose in the 4 hours after each tag, next to all your readings. Tap a tag to open the Logbook on it.
- **Share an Insights card.** Touch and hold any card in Insights and pick Share Card… to send it as a picture. It shows the card as it looks on screen, with its period and dates. GlucOS adds no name or account, but any tag labels you typed appear on the Tags card.
- **Snoozes count down.** While alerts are snoozed, the chip shows a ring that drains as the snooze runs out and shrinks away when it ends. With Reduce Motion on, it shows the minutes left instead.
- **See how a period compares.** Turn on Compare to previous period in Insights, and cards like At a glance, Lows and Highs show how their main figures moved from the period before, with colour for better or worse. If the previous period has too few readings, no comparison shows.
- **A meal and its insulin share a row.** In the Logbook, entries logged within 15 minutes of each other show as one row. Tap it to open out the separate entries, each with its own swipes and menu.
- **See your day hour by hour.** The Time in range by hour card in Insights colours each of the 24 hours by how much time you spent in range over the period. Tap an hour to see what you logged around then on those days.
- **Tap the reading for details.** Tap the current reading on Today to see when it was taken, where it came from, how fast it's changing per minute and when the next one is due. Touch and hold anything you logged on the chart to peek at it.
- **Search Settings.** Type in the search field at the top of Settings to find a setting by its name or an everyday word, like "mmol" for units. Tap a result to jump to it; it lights up briefly so you can spot it. A setting that appears only when another switch is on, such as "Warn me ahead by", lights up the row that reveals it instead.
- **Empty cards explain themselves.** When an Insights card or a Logbook filter has nothing to show, it says why and offers one thing to try, like a longer period or clearing the filter. Tap a Logbook entry to edit it; the editor opens out of its row and folds back when you close it.
- **Step through Insights periods.** Swipe sideways on Insights to go back a period, or forward again, never past today. If an alert banner is showing, swipe it up to put it away. A different kind of alert stacks with it, newest in front (an urgent low always stays in front); tap the stack to see them all. A repeat of the same kind replaces the one showing.
- **Settings rows glide in.** Rows that depend on a switch, like Warn me ahead by, slide open when you turn it on and fold away when you turn it off, and VoiceOver says which rows appeared.
- **Know when your sensor ends.** In a sensor's last day, Today shows how long it has left, and once it ends a card points you to starting a new one. You can turn on a reminder for the evening before. The undo toast shows a thin bar as it runs out; touch it to pause, or swipe it away.
- **Alerts show a chart.** Your own low, high and forecast alerts include a small chart of the last 3 hours and the forecast (an alert with fewer than 2 readings to draw shows text only, and a follower's copy has no chart). Touch and hold an alert to see it; VoiceOver reads a summary. On the Mac the chart is the alert's picture, and you can rest the pointer on the menu bar reading to preview the last 2 hours (turn this off in Settings > General > Menu Bar).
- **Fold a Logbook day.** Tap the chevron by a day's name to hide its rows; the header keeps its time-in-range bar and shows how many entries it holds. Today always opens unfolded.
- **Undo an edit, and ask what a figure means.** After you save a change to a Logbook entry, the undo toast offers Undo to put it back exactly as it was. In Insights, tap the ⓘ beside time in range, average, GMI, variability or time below to see what it means and how it was worked out for the period shown.
- **See what a limit would do, and what you logged.** In Settings, under the low and high limits, a line shows how often each limit would have alerted over the last 7 days, using the same rules and snoozes as real alerts. On the Today chart, tap a logged marker to see the entry's kind, amount, time and note, with Open in Logbook.
- **One alert per low or high, and the scrub finds the key points.** Alerts from the same low or high replace each other in Notification Centre instead of stacking, and each one still sounds. When you're back in range, the alert changes quietly to say how long it lasted and the lowest or highest reading. While you scrub the Today chart, the line snaps onto logged entries and the day's lowest and highest readings, with a light tap.
- **Try an alert, and watch the day add up.** Settings › Alerts has Send a Test Alert, which delivers a sample low titled "Test alert" with the real sound, buttons and chart. It is never logged, snoozed or counted. In the Logbook, a day's totals and its range bar move to their new values when you add, edit, delete or undo an entry.
- **Note a whole day, and watch search narrow.** Hold a Logbook day header to add a short note for that day, such as sick day or travel. The note syncs, shows under the day and on its Best and toughest days chart, and search finds it. As you type a search, matching words fade into their highlight, the count rolls, and rows that stop matching shrink away.
- **Pick several entries, and see where a figure's note comes from.** In the Logbook, tap Select to delete or tag several entries at once (a meal and its insulin come together), and one Undo brings them all back on every device. Tapping ⓘ on an Insights figure now grows its note out of that figure, with a plain fade under Reduce Motion.
- **Peek at a marker, and pick your alert sound.** Hold a logged marker on the Today chart for a card with Edit and Log Again Now (it never logs anything by itself). In Settings › Alerts, choose Standard, Chime, Pulse or Beacon; tapping one plays a preview, and pushed alerts use the same sound.
- **See what the forecast is based on, and watch a batch delete.** Tap the forecast on Today for where it puts you in 30 and 60 minutes, how often its range held recently, and what moved it. Deleting several Logbook entries cascades them out one by one, and Undo brings them back the same way.
- **Compare two days side by side.** From the Logbook's jump-to-a-date calendar or a day's menu, pick a second day to see both days' readings on one chart, with time in range, average, lows and highs side by side. The forecast details card now grows out of the forecast line and folds back when closed.
- **Look back at your alerts.** Settings › Alerts › Alert History lists the last 7 days of low and high alerts by day, with the reading and whether each was snoozed, treated, dismissed or left; tap one to open the Logbook around it. Comparing two days now draws the second day in, and Swap days trades them.
- **Add a note to an alert.** Low and high alert notifications have an "Add note" field, and every Alert History row has an Add note button. The note lands in your Logbook at the alert's time. Alert History also updates live while it's open.
- **Filter your alerts, and see them in Insights.** Alert History has chips for lows, highs and predicted alerts and for how each one ended. Insights has an Alerts card that counts them over the period, and tapping it opens Alert History.
- **Take your alerts to the clinic.** Alert History has an Export menu under the filter chips. It makes a PDF or CSV of the alerts shown, with each one's time, kind, reading, outcome and note. Tapping the Insights Alerts card zooms into Alert History.
- **See your notes on the chart, and what changed.** Logbook and alert notes show as small markers on the Today chart; hold one to read it. After an update, a short What's New appears once, and Settings › About › What's New reopens it.
- **See why readings are missing, and catch a double log.** Where readings stop for 10 minutes or more, Today shows a dashed bridge across the gap; tap it to see why (sensor warming up or ended, no signal, or the phone asleep). Save a meal or insulin entry that nearly matches one from the last 5 minutes and the undo toast asks "Logged twice?". Undo removes only the new copy, and nothing is ever blocked or deleted on its own.
- **Know when readings are missing, even from a widget.** Ten minutes after the last reading, widgets, StandBy, the Lock Screen and the Live Activity say "No readings for 12 min" in grey, with the reason when GlucOS knows it. Insights has a Sensor coverage card that shows how much of the period has readings and the longest gaps. Tap it to open the Logbook around the longest gap.
- **Check the connection from a gap.** If a gap in readings says "No signal" or "Can't connect to LibreLinkUp", tap Check Now on Today to try one fetch straight away. The result appears in the card, and you can tap once every 30 seconds. On Insights, the Sensor coverage card fills its meter and grows its gap bars when it comes into view.
- **Alerts don't bypass the silent switch.** That needs Apple's Critical Alerts entitlement,
  which you request at <https://developer.apple.com/contact/request/notifications-critical-alerts-entitlement/>.
  Once granted, add the entitlement to the app and set the `APNS_CRITICAL_ALERTS=true` secret.
- **The relay's forecast is trend-only.** The phone and the Mac forecast with the synced
  logbook; the relay forecasts from the recent trend, at the strength and timing it has learnt
  from its own readings (docs/ForecastAccuracy.md §6).
- **The relay gets your LibreLinkUp login.** The app sends it over HTTPS (with the relay secret).
  It's kept encrypted in Supabase Vault. Signing out on the phone asks the relay to delete it; if
  the relay can't be reached then, the login stays in Vault until it can.
- **New readings move, they don't jump.** On the Live Activity, Dynamic Island and Lock Screen
  widgets the number counts over, the range colour cross-fades and the trend arrow turns. With
  Reduce Motion on, the number just fades in place. Nothing loops, so it costs no extra battery.
- **Press and drag the chart** to read any reading and its time. A light tick marks crossing your
  low or high line and passing anything you logged; let go and the readout glides back to now.
- **Stale readings look stale everywhere.** When data stops, the number fades to grey and a strike
  line draws across it on the app, widgets and Lock Screen; VoiceOver says the reading is stale.
- **Saving a log entry** turns the Log button into a checkmark with a light tap before the sheet
  closes, so you know it went in (a plain cross-fade under Reduce Motion). A warning such as the logged-twice check always stops you first.
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
