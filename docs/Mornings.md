# Mornings: wake-ups and the post-wake rise

Many people's glucose rises after they wake up, from the dawn phenomenon and from getting up and
moving. GlucOS lets you log when you woke up, learns how your glucose usually moves afterwards, and
adds that to the forecast once it's shown to help.

## Logging a wake-up

A wake-up is a logbook event with the **Woke up** tag (`ContextTag.wokeUp`), so it syncs between the
Mac and the iPhone like every other entry. No new record kind or migration was needed.

- **iPhone log bar**: from 4 am to 1 pm, until a wake-up is logged (on any device) or you tap ✕,
  the bar shows "Woke up at 6:41?" with the time to adjust and a Log button. After logging it
  shows Undo and Change for a few seconds.
- **Lock Screen widget**: "Woke Up" (circular or rectangular). It opens `glucos://log/wake`, which
  logs a wake-up now, or says one is already logged if there was one in the last 3 hours.
- **Shortcuts, Siri and the Action button**: "I'm up in GlucOS" (`LogWakeIntent`). Works as a
  Personal Automation when an alarm is stopped.
- **Mac popover**: the same "Woke up at …?" prompt, under the notices.
- **Anywhere**: the log sheet's Event section has a Woke up chip, for logging or fixing a past one.

### The suggested time

GlucOS suggests the first time the device was used that morning, from 4 am on: on the iPhone when
the app first comes to the foreground, on the Mac when GlucOS launches, the screen wakes or you
switch back to your user. Nothing is logged until you tap Log. HealthKit sleep data would be more
accurate but needs the HealthKit capability on the App ID; it's a possible follow-up.

## What's learnt (`Sources/Engine/MorningPattern.swift`)

For each logged wake-up (one per morning; a second within 4 hours is ignored), the 3 hours after it
are cut into 15-minute steps. For every step the glucose change is measured, and the part that
logged insulin and carbs explain is taken away, using the effects the forecast already learnt
(`EffectProfileLearner`):

    residual = Δglucose + S × insulin acting − K × carbs absorbed

Steps are left out when insulin or carbs were acting but their effect isn't learnt yet, around food
without carbs or a hypo treatment, around lows, and across gaps in the readings. Mornings with
illness, alcohol or a site problem logged are left out. Exercise isn't: getting up and moving is
part of what's being learnt.

The pattern is the median residual at each step across mornings, shrunk towards zero while there
are few examples, and stops at the first step with fewer than 4 mornings.

## When it's used, and how sure it is

The pattern is checked by replaying the forecast after each past wake-up (10, 40, 70 and 100
minutes after, looking 30 and 60 minutes ahead), with a pattern learnt from the **other** mornings,
and again without it. It goes into the live forecast only with at least 5 mornings, 8 checks, and
at least 10% less error. Confidence:

| Confidence | Mornings | Error removed |
|---|---|---|
| High | 14+ (and 30+ checks) | 25%+ |
| Moderate | 8+ | 15%+ |
| Low | 5+ | 10%+ |

In the forecast, the learnt rate is blended in exactly like the insulin and carb effects (the trend
fades out over 30 minutes), only while inside the pattern's span after the latest wake-up, and not
when the forecast has fallen back to trend only because it can't trust the logbook. The forecast's
horizon and likely range are unchanged.

## Where it's shown

- Mac dashboard, Outlook: a **Mornings** card with the summary, the usual curve, the check result
  and the confidence; a line under the forecast when today's forecast includes it.
- iPhone: a **Mornings** card under the chart once a wake-up is logged; the forecast line and tile
  say when the morning adjustment is in.
- Charts: wake-ups are marked with a sunrise.

Wake-ups don't change the learnt insulin and carb effects or the logbook insights
(`ContextTag.affectsResponses` is false). The morning pattern is a forecast input only: it is never
shown as a setting and never used by the bolus calculator or any dose maths.
