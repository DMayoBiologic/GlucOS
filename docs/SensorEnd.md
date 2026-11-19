# Sensor end countdown

A sensor's last day and its end, on iPhone Today and the Mac popover, built on the warm-up
countdown (round 19, PR #140; Mac round 26, PR #169). Timing and words are in
`Sources/Engine/SensorEnd.swift`, tested in `SensorEndTests` (Perth, Sydney and New York, both
daylight-saving changes).

- **Last 24 hours.** A quiet line under the reading: "Sensor day 15 of 15 · 6 h 12 min left".
  Secondary text, the warning colour for the last 2 hours. The day counts whole 24-hour periods
  since the sensor started (wear time is real hours, so a daylight-saving change doesn't move it).
  Minutes round up, so it never says 0 while time is left. VoiceOver hears it as part of the
  reading: "Sensor day 15 of 15, 6 hours 12 minutes left. Ends at 8:59 pm." iPhone redraws on the
  hero's 15-second clock; the Mac line waits for the 24-hour mark without ticking, then redraws
  once a minute while it shows. The figure rolls (`.numericText`), at once under Reduce Motion.
- **Ended.** Once the end has passed and nothing newer has come in, the top card becomes "Your
  sensor has ended", with when it ended, what to do ("Apply a new sensor and start it in the
  LibreLink app…"), the old last reading in small grey type and Check Again. Readings still
  arriving past the nominal end (a grace period, or the wrong lifetime in Settings) keep the usual
  card until they stop. When LibreLinkUp reports the new sensor, its warm-up countdown fades in over
  the ended card, then the first reading over that. The Mac's stale notice is hidden while it
  shows, and the popover's old "Sensor ends in…" / "Sensor has ended" notices are gone: the top
  card says both. The Mac popover redraws at the end moment, so an open popover changes over.
  Its schedule starts with now (`GlucoseSnapshot.heroRedrawMoments`, `RedrawMoments.explicit`):
  `TimelineView(.explicit(_:))` draws its first date straight away even when it's in the future,
  so a schedule of only the end moment showed the ended card from the moment the popover opened,
  with the live reading labelled "Yesterday" (`RedrawMomentsTests`). The
  countdown line's wait, the Mac warm-up card and the snooze chip go through the same helper.
- **Evening-before reminder.** Opt-in, off by default (`sensorEndReminderEnabled`, per device).
  iPhone: Settings → Sensor → Sensor change reminder. Mac: Settings → Alerts → Sensor. One local
  notification at 7 pm by the clock on the day before the end day, under the identifier
  `glucos.sensorEnd`: "Your sensor ends tomorrow" / "It ends at 8:59 pm tomorrow. Have a new
  sensor ready…". An end before 5 am says "tonight" instead. Not an alert: no sound, a Focus holds
  it back. `Sources/App/SensorEndReminderScheduler.swift` re-adds it only when the sensor's end
  moves (a new sensor replaces the old reminder) and removes it when switched off or signed out.
  Followers never get one. It's separate from the existing "Sensor ending" alert (under 24 hours
  left, every 6 hours), which the relay also sends; nothing in `AlertPlanner` or the relay changed.
