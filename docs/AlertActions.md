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
- Motion: one fade in when a snooze starts and one fade out when it ends or is resumed, instant under
  Reduce Motion. Nothing loops: the chip redraws once a minute and at each snooze's end
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
