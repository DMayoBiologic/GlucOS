# Alert buttons: Snooze 30 min and I'm treating it

Low and high alerts on the iPhone and the Mac carry two buttons. They work the same whether the
alert came from the relay as a push or from the device itself.

| Alert | Buttons |
| --- | --- |
| Low, predicted low | I'm treating it, Snooze 30 min |
| High, very high, predicted high, predicted very high | I'm treating it, Snooze 30 min |
| Urgent low, predicted urgent low | I'm treating it (never snoozable) |
| Rapid change, no data, sensor, connection | none |

## Snooze 30 min

- Quiets that alert's level for 30 minutes: lows (low and predicted low), highs (high and predicted
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

## I'm treating it

- Opens the log sheet (iPhone: the app; Mac: the quick-log window).
- **Low** (including urgent): food tagged as a hypo treatment. When you have a "Treat a low" usual
  (docs/UsualEntries.md) it's filled in straight away, food only and never a dose, and it still
  goes through `RepeatCheck` ("Already logged?") before it's logged.
- **High**: the dose step for a correction, with the bolus calculator and your usual correction one
  tap away. A dose amount is never filled in without a tap. The #54 double-dose check runs as for
  any dose, and a dose logged this way with no food is saved as a correction, so "Was that dose for
  a meal?" doesn't ask about it.
- It also quiets that alert while the treatment works: 15 minutes for a low (the usual recheck
  after fast carbs), 30 for a high. Never an urgent low.

## In the Logbook

Each low or high alert, and which button was tapped on it, also shows as a quiet row in the
Logbook on both devices. See docs/AlertLog.md.

## Where it lives

- Rules: `Sources/Core/AlertSnooze.swift` (tests `AlertSnoozeTests`), relay copy in
  `supabase/functions/relay/core.ts` (`snoozeLevel`, `silences`, `ownerNotices`; tests "snooze: …"
  in `checkins_test.ts`).
- Notification categories `glucos.alert` and `glucos.alert.urgent`, registered by both apps
  (`AlertNotifications` in `Sources/App/AlertManager.swift`) and named by the relay's pushes. A
  follower's copy of an alert never carries them: lows get Check in (`glucos.follow.low`), the rest
  no buttons.
- iPhone: `Sources/iOS/AlertActions.swift`; Mac: `AppDelegate`.
