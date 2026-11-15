# "Was that dose for a meal?"

A fast-acting dose with no food logged near it reads as a correction: the forecast expects the
insulin's whole drop, and the effect learner takes the glucose that follows as insulin alone. When
the dose was really for a meal nobody logged, the forecast runs low and the learnt insulin effect
comes out weaker than it is. [ForecastAccuracy.md §7](ForecastAccuracy.md) found four such doses
(1.5–10 U) on 14–15 Nov 2026.

So GlucOS asks, once per dose, whether it was for a meal or a correction.

## When it asks

Rules: `Sources/Engine/DoseMealCheck.swift` (tests: `DoseMealCheckTests`).

- A rapid, ultra-rapid or short-acting dose of at least 0.5 u.
- No food (with or without carbs) or hypo treatment logged within 30 minutes either side.
- Not from the bolus calculator, which already knows what the dose was for.
- Not yet answered or dismissed (`InsulinDose.purpose` is nil).
- From 30 minutes after the dose (so food logged just after it is seen first) until 12 hours after.

## Where it asks

- **iPhone:** a strip above the log bar's buttons (`PhoneDoseStrip`): "4 u NovoRapid at 9:12 am.
  Was it for a meal?" with **Meal**, **Correction** and a close button.
- **Mac:** the same question in the menu bar popover (`PopoverDosePrompt`).
- **Notification**, for when the app isn't open: the device the dose was logged on schedules one,
  half an hour after the dose, with Meal and Correction buttons that answer without opening or
  unlocking (`DoseQuestion`). No sound. Clearing the notification counts as dismissing the question.

Each answer is one tap. In the app it is confirmed with **Undo**, and after Meal with **Add Food**,
which opens the log sheet on food at the dose's time. The close button (or clearing the notification)
stores `unsure`, so the dose is never asked about again. The answer syncs with the logbook, and every
device takes its notification back as soon as the dose is answered, food is logged near it, or it
is deleted. The logbook shows "For a meal" or "Correction" with the dose.

## What the answer changes

- **Meal**, with still no food logged from 30 minutes before to 90 minutes after the dose
  (`DoseMealCheck.unloggedMealTimes`): treated everywhere like food logged without carbs. The
  forecast follows the trend instead of expecting the full drop (limitation `uncountedFood`), the
  carbs on board card says food isn't counted, and the effect learner, the morning pattern, the
  Insights correction figures and the bolus settings review leave the dose out. Logging the food
  afterwards (Add Food) puts it back in, now with its carbs.
- **Correction:** read as GlucOS already reads a dose with no food near it, now with the user's word
  for it: modelled in the forecast, and used by the learner and the correction insights.
- **Dismissed** (`unsure`): read like no answer.

The answer never feeds a dose: the bolus calculator doesn't read it.
