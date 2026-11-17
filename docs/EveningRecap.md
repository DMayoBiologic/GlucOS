# Evening recap

One opt-in notification a day on the Mac and iPhone: today's time in range, average glucose, lows
and highs, at a time the person picks. Off until turned on.

- **Settings.** Mac: Settings → Alerts → Daily Recap. iPhone: Settings → Daily recap. A switch and
  a time (9 pm unless changed). Each device keeps its own switch and time
  (`eveningRecapEnabled`, `eveningRecapMinute` in UserDefaults), so someone with both can choose
  which one sends it.
- **What it says.** Title "Evening recap", subtitle "Midnight to 8:55 pm" (the hours covered), body
  "78% in range, average 7.4 mmol/L. 1 low and no highs." No sound; an ordinary notification, so a
  Focus holds it back.
- **How it's counted.** `Sources/Engine/EveningRecap.swift`, tested in `EveningRecapTests`. Midnight
  to the newest reading at or before the recap time, read as *Today so far* reads it: 5-minute
  buckets, at least an hour of the day gone and readings in half of its 15-minute slots, or there's
  no recap that day. Lows and highs are runs of 15 minutes or more outside the target, a gap of over
  30 minutes ending one (the Insights Lows and Highs rule).
- **How it's scheduled.** `Sources/App/EveningRecapScheduler.swift`. A local notification's words
  are fixed when it's added, so each publish of the store (a reading, a settings change, relay
  readings on iPhone) adds it again under the identifier `glucos.recap` when the figures could have
  moved: at most once per 5 minutes of readings. What fires is the latest figures the app had, and
  the subtitle says which hours they cover, so an iPhone that stopped refreshing at 6 pm says
  "Midnight to 6 pm". Once the time has passed nothing more is scheduled until tomorrow's readings.
  Turning it off removes the pending one. Followers (no account) never get one.
- **Tapping it.** `userInfo["kind"] = "recap"`. `EveningRecapRoute` holds the tap (with when the
  notification went out) until a screen takes it, so a tap that launched the app still works.
  iPhone pushes `PhoneRoute.insightsToday`, zooming from the Insights row; Mac opens the dashboard
  on Insights. Both put `EveningRecapCardView`, a Today card with the same four figures over the
  same hours, on top of Insights. On the Mac it goes when another section is picked.

Observational only, like the rest of Insights: it never suggests a change to insulin or settings.
