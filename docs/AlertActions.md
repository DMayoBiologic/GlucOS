# Alert buttons: Log treatment and Snooze 30 min

Low and high alerts on the iPhone and the Mac carry two buttons. They work the same whether the
alert came from the relay as a push or from the device itself.

| Alert | Buttons |
| --- | --- |
| Low, predicted low | Log treatment, Snooze 30 min |
| High, very high, predicted high, predicted very high | Log treatment, Snooze 30 min |
| Urgent low, predicted urgent low | Log treatment (never snoozable) |
| Rapid change, no data, sensor, connection | none |

## Snooze 30 min

- Quiets that one alert for 30 minutes, nothing else: no other alert's level, nothing a follower
  gets. The level is the alert's family: lows (low and predicted low), highs (high and predicted
  high) or very highs (very high and predicted very high, and highs with them). Snoozing a high lets
  a very high through. Escalation always gets through.
- **Urgent lows are never snoozed**, by either button, on any device or by the relay. Their
  notification has no Snooze button and the relay refuses one (`400`).
- When the snooze ends and the alert is still due, it fires on the next reading, not a repeat timer
  later (`AlertPlanner.release`).
- It only quiets **your own** alerts. Followers' alerts, their Check in button, check-ins and the
  5-minute no-answer reminders, and the Lock Screen card all carry on exactly as before. The relay
  keeps a second set of alert timers for the owner (`work.ownerPlanner`) so a snooze can't change
  the shared ones (`work.planner`) that followers and the card go by.
- The iPhone sends the snooze to the relay (`POST /v1/alerts/snooze {kind, minutes}`, relay 2.13.0)
  as well as keeping it for its own local alerts. If the relay can't be reached the phone says so in
  a quiet notification, since the push may still come. The Mac's snooze is its own (the Mac has no
  relay connection).

## Snoozed chip

While any alert is snoozed (by Snooze 30 min or by Log treatment), iPhone Today (under the reading)
and the Mac popover (under the hero card) show one small chip: "Low alerts snoozed until 2:30 pm ·
12 min · Resume". Tapping or clicking it turns every alert back on at once. Alert rules don't
change: a snoozed alert was let go of, so if it's still due it fires on the next reading.

- Wording (`AlertSnoozeChip` in `Sources/Core/AlertSnooze.swift`, tests in `AlertSnoozeTests`):
  each level by the button that snoozed it. A very-high snooze reads "High and very high" (it quiets
  highs too) and hides a shorter high snooze under it; snoozes ending at the same minute share one
  time ("Low and high alerts snoozed until 2:30 pm"), otherwise each says its own, soonest first.
  Minutes left round up, so it never says "0 min"; VoiceOver hears "…, 12 minutes left" and the hint
  "Turns these alerts back on now", then "Alerts are back on." after a tap.
- Motion: one fade in when a snooze starts and one shrink-and-fade out (toward its leading edge) when
  it ends or is resumed, instant under Reduce Motion. Nothing loops: the chip redraws once a minute and at each snooze's end
  (`AlertSnoozes.redrawDates`), and `AlertSnoozeStore` drops a snooze the moment it ends with one
  timer rather than polling.
- **The iPhone and the relay agree.** Relay 2.15.0 sends its running snoozes in every status
  (`snoozes`, `{}` when none) and has `POST /v1/alerts/resume` (empty body) to end them all. The
  phone takes the relay's snoozes as its own whenever a status arrives (`AlertSnoozeStore.adopt`),
  so the chip, the phone's local alerts and the pushes go by the same end times. A status asked for
  before a snooze or Resume on the phone is ignored for snoozes (`revision`), so it can't undo it.
  Resume clears the phone first, then the relay; if the relay can't be reached its snoozes still
  stand, so the phone puts them back and says "Couldn't reach GlucOS's server, so alerts are still
  snoozed" under the chip. With no relay, or one before 2.15.0, the phone's snoozes are its own.
- The Mac's chip covers the Mac's own snoozes (the Mac has no relay connection).

### Countdown ring

The bell on the chip sits in a ring that drains as the snooze runs out, on iPhone and Mac. It counts
down to the same end as the chip's minutes left (the last running snooze; a very-high snooze covers
a shorter high).

- `AlertSnoozeCountdown` (`Sources/Core/AlertSnooze.swift`, tests in `AlertSnoozeTests`) keeps when
  that snooze began, because the snoozes only hold end times. A new end gets the shortest snooze
  length that holds what's left (15, 30 or 60 minutes), which is exact for a snooze set on the device
  and a fair guess for one adopted from the relay part-way through. The same end keeps its start, so
  a redraw or relaunch never refills the ring; a longer snooze refills it, a shorter one keeps
  draining. `AlertSnoozeStore.countdown` holds it, saved next to the snoozes.
- Power: the ring moves only when the chip already redraws, once a minute. Each redraw glides the
  arc to its new length in one short animation; nothing loops.
- Reduce Motion: the ring holds still and steps once a minute, with the minutes left inside it in
  place of the bell.
- VoiceOver skips the ring. The chip's label already says "…, 12 minutes left" when it's read, so
  nothing is announced as the minutes tick down.
- View: `Sources/App/Views/AlertSnoozeChipView.swift` (shared by both apps).

## Snoozed on the Lock Screen

While the owner's alerts are snoozed, the Live Activity says so wherever the reading shows: the
Lock Screen card's top line and the expanded Dynamic Island read "Low · 🔕 until 2:30 pm" (a
`bell.slash.fill` and the clock time the last running snooze ends). VoiceOver hears it at the end
of the card's summary: "… Low alerts snoozed until 2:30 pm." It never appears on a follower's card,
since a snooze never changes what followers get, and alert rules are unchanged.

- Data: `GlucoseActivityState.snooze` (`SnoozeBadge` in `Sources/Shared/GlucoseActivityState.swift`:
  `until`, seconds since 1970, and the snoozed `levels`). The apps build it with
  `AlertSnoozes.badge(at:)`, the relay with `cardSnooze` in `core.ts`, by the same rule: soonest
  end first, and a very-high snooze hides a high one that ends no later. Tests: `AlertSnoozeTests`
  and "snooze: the card's badge …" / "snooze: the owner's card shows it …" in `checkins_test.ts`.
- **App closed:** relay 2.16.0 puts its running snoozes on the owner's card each tick (followers'
  cards never), so the card changes, and is pushed, when a snooze starts, ends or is resumed.
- **App running:** the phone adds its own snoozes (which have taken the relay's, see above) and
  redraws the card as soon as `AlertSnoozeStore` changes: a button, Resume, a relay status, or a
  snooze ending. Nothing ticks.
- A card drawn after the snooze ended but before the next update leaves the badge off
  (`GlucoseActivityState.runningSnooze(at:)`). It fades in and out once, instant under Reduce
  Motion. The Watch Smart Stack and CarPlay layout doesn't show it (too small).

## Snoozed in the menu bar

The Mac menu bar item shows a small bell-slash after the reading while any alert is snoozed, and
its tooltip and VoiceOver label end with "Low alerts snoozed until 2:30 pm". The popover (the
menu) already has the snoozed chip with Resume. `MenuBarGlance.snoozed` is only a yes or no, so the
item redraws when a snooze starts or ends, never for its minutes, so the menu bar stays cheap.
Hidden while the reading is stale, where the warning sign and age take
the space; the tooltip still says it.

## Log treatment

Called "I'm treating it" until round 31. Only the title changed: the action identifier
(`alert.treat`), the categories and what the button does are the same, so the relay and older
builds need nothing new.

- Opens the log sheet (iPhone: the app; Mac: the quick-log window). **It never logs anything by
  itself**: nothing is saved until you tap Log.
- **Low** (including urgent and predicted): filled in from your "Treat a low" usual
  (docs/UsualEntries.md) when you have one, food only and never a dose, and it still goes through
  `RepeatCheck` ("Already logged?") before it's logged. With no usual yet it opens on the food step
  tagged as a hypo treatment, the same as the low entry in Your usual.
- **High**: the dose step for a correction, with the bolus calculator and your usual correction one
  tap away. A dose amount is never filled in without a tap. The #54 double-dose check runs as for
  any dose, and a dose logged this way with no food is saved as a correction, so "Was that dose for
  a meal?" doesn't ask about it.
- It also quiets that alert while the treatment works: 15 minutes for a low (the usual recheck
  after fast carbs), 30 for a high. Never an urgent low.

## Chart on alerts

Low, high and forecast alerts (the ones with Log treatment and Snooze) carry a small chart: the
last 3 hours of readings coloured by range, the target band, and the forecast as a dashed line with
its likely range as a cone at the end. Other alerts (stale, sensor, rapid change) don't.

- **iPhone:** press and hold (or pull down) an alert to expand it. A notification content extension
  (`GlucOSNotification`, `Sources/iOSNotification`) draws the chart under the alert's text. The
  reading line draws in once; under Reduce Motion the finished chart appears at once. The buttons
  come from the alert's category as before, and the chart takes no touches.
- **Mac:** the chart is the alert's picture (a PNG attachment, on a dark card so it reads the same in
  light and dark mode).
- **VoiceOver** reads the chart as one element, in the same words as the app's charts: "Last 3
  hours. Now 3.4, low. Lowest 3.4, highest 5.0. 67 percent in range. Went below range once.
  Forecast, not a reading: about 3.1 in 30 minutes."
- **Where the values come from:** the Live Activity card the device already builds (3 hours of
  5-minute readings and the next hour of forecast), under `chart` in the notification's `userInfo`.
  The relay's pushes carry the same values from its own card (`alertChart` in core.ts, relay 2.18.0
  on), so the extension needs no app group, network or stored readings. Alerts from an older relay,
  or with fewer than 2 readings, simply show no chart. A follower's copy carries none.
- **Timing is unchanged:** the chart only adds to the alert; it is sent at the same moment, with the
  same priority, collapse id and expiry.
- Code: `AlertChart` (`Sources/Shared/AlertChart.swift`: payload, layout, VoiceOver summary, motion;
  tests `AlertChartTests`), `AlertChartView`, `AlertChartSource` (which alerts get one). The
  extension's App ID (`au.com.declanmayo.glucos.ios.notification`) has no capabilities, so export
  registers it; nothing to tick by hand.

## In-app banner

When one of your own low or high alerts fires while GlucOS is in front (iPhone: the app is open;
Mac: the popover or the dashboard is open and GlucOS is the active app), it slides down from the top
as a banner inside the app instead of the system banner (round 38). It shows the notification's own
title and body ("Low glucose — 3.6 mmol/L", "Falling") and the same buttons as the notification:
Log treatment and Snooze 30 min, or Log treatment alone for an urgent low.

- **Same buttons, same effect.** They run exactly what the notification's buttons run
  (`PhoneAlertActions.handle` on iPhone, so the snooze reaches the relay; `MacAlertActions.handle`
  on the Mac) and are recorded in the Logbook the same way ("Tapped Log treatment", "Snoozed 30
  min"). Log treatment still never logs by itself; urgent lows still can't be snoozed.
- **Sound and haptic stay.** The notification is presented with `[.list, .sound]` rather than
  `[.banner, .list, .sound]`, so it still plays its sound and still goes in Notification Center.
  iPhone plays the `alertBanner` haptic (warning, through `Haptics`); the Mac a level-change
  haptic on a Force Touch trackpad.
- **Only when it would be seen.** iPhone: the app is active and a host view is on screen. Mac:
  `NSApp.isActive` and a host's window is visible and not covered. Otherwise the system banner shows
  as before. Rapid change, no data, sensor and connection alerts, check-ins and a follower's copy of
  someone else's alert always keep the system banner.
- **Dismissing.** Tap the banner, swipe it up, or the close button; VoiceOver's escape gesture and
  a "Dismiss" action do the same. Dismissing only hides it: it never snoozes or logs anything, and
  the notification stays in Notification Center. Left alone it goes after 10 minutes (one timer at
  the next banner's end, nothing polls).
- **Swipe (round 59).** The banner follows the finger up one to one, and gives a little, resisting,
  when pulled down (`AlertBannerSwipe`). Let go past 30 pt, or flick it, and it carries on up and
  out; a shorter swipe springs back (`DSMotion.emphasized`). Under Reduce Motion it stays put and
  fades as it's swiped instead.
- **Stacking (round 59).** A second alert arriving while one shows stacks behind it rather than
  replacing it (`AlertBannerStack`): the newest goes in front, and up to two cards peek out 8 pt
  below, a little smaller and fainter. The front card says "1 more alert · Tap to show"; tapping it
  spreads the stack out, one card under another with a Show less button, and each card can then be
  swiped away or answered on its own. Dismissing the front card brings the next one forward. An
  urgent low always stays in front. A repeat of a kind already showing replaces it, and at most
  three show (the oldest goes first, never an urgent low ahead of the others). The stack folds back
  when one card is left. VoiceOver hears "1 more alert" on the front card and gets a "Show all
  alerts" action; cards behind are hidden from it until the stack is spread out.
- **Motion.** Slides down once (`DSMotion.emphasized`) and out once; cards move to their new places
  with the same spring as alerts arrive, leave or spread out. Under Reduce Motion every change
  cross-fades instead. Nothing loops or pulses.
- **VoiceOver.** Announced as it arrives: "Alert: Low glucose, 3.6 mmol/L. Falling. Log treatment or
  Snooze 30 minutes at the top of the screen."
- Where: rules and wording `Sources/Core/AlertBanner.swift` (tests `AlertBannerTests`); center, host
  and view `Sources/App/Views/AlertBannerView.swift` (`AlertBannerCenter`, `.alertBannerHost()` on
  `PhoneRootView`, the Mac popover and the dashboard); presentation in each app's `willPresent`.

## Log treatment in the app

The same button, inline: under the reading on iPhone Today and in the Mac popover (round 34). An
alert's button only helps while the notification is in front of you; open the app during a low and
logging the treatment was the log bar and three taps.

- **When**: the latest fresh reading is below your low line, or the forecast crosses it within the
  predicted low alert's lead time (the same rule, `PredictiveAlertRules`, on the same forecast,
  `Outlook.alertForecast`, and only while predicted low alerts are switched on). Never on a stale
  reading.
- **Gone** once any food or a hypo treatment tag is logged with a time in the last 15 minutes (a
  few minutes ahead counts too, for another device's clock), or once the reading is back at or
  above the line with no low predicted. Still low a quarter of an hour after treating, it comes
  back: the usual recheck.
- **What it does**: exactly the alert button's log sheet (`.treating(.low)`), filled in from your
  "Treat a low" usual, food only, through `RepeatCheck`. **It never logs anything by itself.** It
  doesn't snooze alerts: that is the notification's job, and a low you're looking at in the app
  should still alert if it carries on.
- **Words**: "Log treatment · Low now" / "· Low predicted in about 12 min". VoiceOver reads "Log
  treatment for this low" or "Log treatment. Low predicted in about 12 minutes", and the hint says
  the sheet opens filled in and nothing is logged until you log it.
- **Motion**: fades in once and out once; instant under Reduce Motion. Its caption redraws once a
  minute, nothing loops.
- **Keyboard (Mac)**: while it shows in the popover, ⌘L presses it instead of the toolbar's Log
  button (which keeps its click), and ⌘? lists "⌘L during a low".
- **Siri (iPhone)**: "Log treatment in GlucOS" opens the same sheet at any time (docs/iOS.md, "Siri
  and Shortcuts"). It never logs by itself either.
- Rules: `Sources/Engine/LowTreatButton.swift` (tests `LowTreatButtonTests`); view and app glue
  `Sources/App/Views/LowTreatButtonView.swift` (`LowTreatButton.current`), shared by both apps.
  Followers don't see it (their view is the follower screen, which has Check in).

## In the Logbook

Each low or high alert, and which button was tapped on it ("Tapped Log treatment", "Snoozed 30
min"), also shows as a quiet row in the
Logbook on both devices. See docs/AlertLog.md.

## Where it lives

- Rules and button titles: `Sources/Core/AlertSnooze.swift` (`AlertSnoozes.buttonTitles(for:)`,
  tests `AlertSnoozeTests`), relay copy in
  `supabase/functions/relay/core.ts` (`snoozeLevel`, `silences`, `ownerNotices`, `runningSnoozes`;
  tests "snooze: …" in `checkins_test.ts`). Resume: `RelayEngine.resumeAlerts`.
- Notification categories `glucos.alert` and `glucos.alert.urgent`, registered by both apps
  (`AlertNotifications` in `Sources/App/AlertManager.swift`) and named by the relay's pushes. A
  follower's copy of an alert never carries them: lows get Check in (`glucos.follow.low`), the rest
  no buttons.
- iPhone: `Sources/iOS/AlertActions.swift`; Mac: `AppDelegate`.
