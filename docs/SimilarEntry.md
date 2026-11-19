# Similar entry note

While a new meal or insulin dose is being filled in, the log sheet on iPhone and Mac looks at the
last 10 minutes of the Logbook. If the same kind of entry with about the same amount is there, one
quiet line shows above Log:

> You logged a similar meal 3 min ago · View

View shows the earlier entry in place ("12:41 · 45 g · Toast"), so nothing typed into the sheet is
lost. It's the usual way an entry ends up in the Logbook twice: said to Siri and then typed into the
app, or logged on the iPhone and then on the Mac.

## Rules (`Sources/Engine/SimilarEntry.swift`, tests `SimilarEntryTests`)

- Only new meals and doses with an amount. Never notes, events, site changes, or an entry being edited.
- The earlier entry is timed in the last 10 minutes (up to a minute ahead, for another device's clock)
  and within 10 minutes of the time picked in the sheet.
- Doses: same kind of insulin, the same insulin when both name one, units within 0.5 u or 10%.
- Meals: carbs within 5 g or 10%, the same food when both name one. A meal with no carbs matches only
  the same named food with none.
- The closest in time wins. When the meal and the dose both match, the line says "meal and dose" and
  View shows the more recent one.
- Followers never see it.

## What it never does

It never blocks Log, never changes an amount, never deletes anything and never logs on its own. It
sits alongside the two checks that were already there: "Already logged?" at Log for one-tap fills
(`RepeatCheck`, docs/UsualEntries.md) and "Logged twice?" with Undo after saving (docs/DoubleLog.md).

## Motion

The line fades and slides up into place, and View's detail drops in under it. With Reduce Motion on,
both simply fade. The minutes redraw every 15 seconds, and the line goes once the earlier entry is
more than 10 minutes old. VoiceOver reads "You logged a similar meal 3 minutes ago", then View.
