# Food search and the bolus calculator

## Food search

The log sheet's **Search or describe your meal** (Mac and iPhone) turns what you ate into carbs
without filling anything in by hand:

- **Describe it.** "2 slices of toast and a banana", "200g rice, chicken curry", "can of coke".
  `MealDescription` splits it into foods, reads each amount (numbers, words, fractions, grams/ml,
  measures like slice/cup/large) and matches each food, your own foods first. Every match shows
  its amount and carbs, with other matches one tap away, then **Add all**. A weight is never
  invented for a solid food: if the measure said isn't one the food has, it asks how much. An
  amount it had to assume is marked.
- **Search it.** Everyday and overseas names ("fries", "oatmeal", "coke", "weetbix", "flat
  white"), plurals, filler words and one-letter typos all find the food, and a plain word starts
  on the everyday version ("rice" is cooked white rice). The **+** on a row adds the usual amount
  (or the one used last time) in one tap; the name opens the portion to change it.
- **Extending it.** New names go in `FoodAliases`, the everyday default for a word in
  `FoodStaples` (both in `Sources/Food/FoodSearch.swift`). Another online food list is an
  `OnlineFoodSource` added to `FoodSources.online` (`Sources/Food/OpenFoodFactsClient.swift`).

Where the foods come from:

- **Built-in list:** AUSNUT 2023 from Food Standards Australia New Zealand: 3,741 foods with
  9,000+ household measures (slice, cup, medium banana…). Carbs are *available carbohydrate
  without sugar alcohols* per 100 g, which leaves out fibre, as carb counting does. Licensed
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/); the app credits FSANZ under the
  results. Bundled as `Sources/Food/ausnut-foods.json`, built by `scripts/food/build_ausnut.py`
  in the **Food data** workflow (run it by hand to pick up a new FSANZ release).
- **Packaged products:** looked up in Open Food Facts (ODbL) as you type a search, Australian
  products first. Only the search words are sent. Community data, so the app says to check the label.
- **Your own foods:** name, carbs per serve and (optionally) the serve's weight.
- **Favourites and recents:** star any food. Recents come from meals logged with foods.
  Favourites, your own foods and the foods in each meal sync between devices with the logbook
  (record kinds `food` and `meal`).

A meal keeps its foods (`MealEntry.items`), but its `carbs` is what the user confirmed, so a
hand-edited total wins.

## Bolus calculator

Like a pump's bolus calculator. Off until the user enters **and confirms** their carb ratio,
correction factor and target (optionally by time of day), dose step and maximum bolus. These
settings sync between devices (record kind `bolusSettings`).

```
food        = carbs ÷ carb ratio
correction  = (glucose − target) ÷ correction factor        (negative below target)
trend       = shift ÷ correction factor, where shift is where the measured rate takes glucose
              in 30 min, counting only beyond ±0.5 mg/dL/min and up to 3 (so at most ±75 mg/dL).
              Falling: always counted (the arrow is used if there are too few readings for a rate).
              Rising: only with a measured rate, and only if "Add insulin when glucose is rising" is on.

at or above target:  total = food + max(0, correction + trend − insulin on board)
                     (if a fall takes correction + trend under 0, the below-target line applies)
below target:        total = max(0, food + correction + trend − insulin on board)
no fresh reading:    total = max(0, food − insulin on board)    (no correction, no trend)
falling fast:        total = max(0, food + trend − insulin on board)    (correction left out)

then: take off the exercise reduction the user picked (none, 25% or 50%),
      cap at the maximum, round DOWN to the dose step
```

The trend step is the published trend-arrow adjustment (Pettus & Edelman 2017; Aleppo et al.
2017), done with the rate measured over the last 15 minutes rather than a table. It is not the
glucose forecast.

Insulin on board is the engine's figure from logged fast-acting doses (long-acting and NPH aren't
counted). The glucose forecast is never used.

**Safety gates:**

| Situation | What happens |
|---|---|
| Glucose below the low threshold | No suggestion: treat the low first |
| Falling (≤ −1 mg/dL/min) and heading under the low threshold within 20 min | No suggestion |
| Falling fast but high | Correction left out; insulin on board comes off the food dose |
| Last reading older than 15 min, or none | No correction; a finger-prick value can be typed in |
| Above the maximum | Capped, and says so |
| Very high (≥ 16.7 mmol/L) | Check ketones / site |
| ≥ 13.9 mmol/L and no lower than at a fast-acting dose (≥ 0.5 u, taken at ≥ 11.1 mmol/L) 1½–4 h ago | Check site or pen, ketones; pump users consider a pen injection |
| A calculator dose for carbs within 10% of these in the last 45 min | Possibly the same meal logged twice: don't dose again |
| Low or hypo treatment in the last hour, recent bolus, exercise, pump user | Notes |

**Use** only fills in the dose; logging it asks for confirmation, and the dose keeps the
calculator's working (`InsulinDose.calculation`). The working shows each step, including the trend and any
exercise reduction, and the dose keeps them (`BolusCalculation.trendUnits`, `.reduction`). Every view
says it's not medical advice.

## Suggested setting changes

The settings editor reviews the last 45 days for clean examples: a meal with a bolus within
20 minutes, nothing else eaten or injected from 3 hours before to 4 hours after, no context tags,
no low, readings at both ends; or a correction from at least 2 mmol/L above target with no food.

- Meal: the ratio that would have ended level is `carbs ÷ (units + Δ ÷ CF − insulin left at 4 h)`.
- Correction: the factor shown is `(start − 4 h later) ÷ (units acted by 4 h)`.

A meal logged twice (same food and carbs within 10%, within 45 minutes; `LogCleanup.mealsWithoutRepeats`) counts once.

A change is offered for a time block only with at least 5 examples, a spread (IQR ÷ median) of
0.5 or less, and a difference of 10% or more. It moves at most 20% at a time, comes with the
evidence and a confidence level, and is applied only if the user taps **Try it**, re-confirms
and saves.

Tests: `BolusCalculatorTests`, `BolusSettingsReviewTests` (simulated people with known ratios),
`FoodDatabaseTests`, and the sync tests.

## Do logged carbs match the rise? (15 Nov 2026)

The question: for meals logged in the last 14 days, especially through food search, does the
glucose rise match the carbs, given the insulin acting? If some foods are consistently
under- or over-counted, food search could correct them or say "this usually raises you more
than its carbs suggest".

**Answer: not yet, and nothing was changed.** No food has been eaten often enough, cleanly
enough, to say how it treats this user. The analysis is below so the next look can start from it.

### What was there

The server's readings start on 10 Nov 2026, so "14 days" is really 5. The logbook holds 15
meals; 3 are from before the readings start and one is the same breakfast logged twice (counted
once, as `LogCleanup.mealsWithoutRepeats` does), leaving 10 meals with readings. Seven came
through food search, one is the user's own food and two are typed totals. Only one food (hash
browns) appears in more than one meal.

### How it was checked

For each meal: glucose at 60–180 minutes after it, minus glucose when it was logged, against
what the engine's curves expected (standard 3-hour carb absorption with a 10-minute delay,
rapid insulin peaking at 75 minutes, every rapid dose from 4 hours before to the end of the
window, and the replay's learnt effects from §11 of ForecastAccuracy.md: 2.8 mg/dL per gram,
19.2 mg/dL per unit). The window stops at the next logged carbs. "Implied carbs" is what the
logged carbs would have to have been for the curves to match.

| Meal (Perth time) | Logged | How | Start | 120 min seen / expected | Implied at 120 / 180 min | What else was going on |
| --- | --- | --- | --- | --- | --- | --- |
| Wed 06:12 hash browns ×3, breakfast burrito | 30 g, 10 U | typed | 113 | −24 / −31 | 1.1× / 1.2× | went low 2½ h later |
| Wed 09:29 3 hash browns, 2 pancakes, orange juice | 40 g, 8 U | typed | 116 | +208 / −37 | 3.8× / 3.4× | logged after eating (+62 in the 30 min before), after a low of 54 |
| Thu 07:26 Big Brekkie Burger | 54 g, 7.5 U | own food | 113 | +52 / +45 | 1.1× / 1.0× | clean |
| Thu 14:09 sushi (inari, fish) | 53.9 g, 7 + 4 U | search | 92 | (60 min) +41 / +21 | 1.4× at 60 | green juice 74 min later |
| Thu 15:23 green juice | 16.6 g | search | 106 | +45 / −86 | 4.6× / 3.1× | 11 U of the sushi doses still acting |
| Thu 19:08 burrito bowl | 37.5 g, 4 U | search | 69 | +175 / +43 | 2.6× / 1.9× | started low |
| Thu 23:42 sports drink 600 ml | 36.8 g | search | 68 | +92 / +80 | 1.2× / 0.7× | hypo treatment |
| Fri 09:58 2 eggs, 2 hash browns | 35.8 g, 6 U | search | 210 | −90 / +20 | below 0 | high and falling before it |
| Fri 19:27 sports drink (powder) 437 ml | 21.4 g | search | 55 | +144 / +46 | 3.1× / 3.3× | hypo treatment, kept rising for 4 h |
| Sat 17:04 Big Mac | 38.5 g, 5 U | search | 176 | +2 / +36 | 0.6× / 1.2× | rising +68 in the 30 min before (eaten before logging) |

Glucose in mg/dL.

### What it shows

- **The two clean meals match.** The Big Brekkie Burger (own food) and the first breakfast came
  within 10–20% of what their carbs predicted. That's evidence the curves and learnt effects are
  roughly right for this user, not evidence about any food.
- **Every meal that started low rose 2–4× more than its carbs.** The burrito bowl, both sports
  drinks and the pancake breakfast all began at 55–69 mg/dL or straight after a low. That's
  the body's own rebound from a low adding to the food, plus food not logged while treating it.
  It isn't a carb-counting fault, so a per-food correction learnt from these would be wrong:
  it would tell the user a sports drink "raises you more" when it was the low.
- **The big under-count was a typed total, not food search.** "3 hash browns, 2 pancakes, orange
  juice" was typed as 40 g. Describing it in food search gives about 112 g (3 takeaway hash
  browns 53 g, 2 homemade pancakes 41 g, a 250 ml juice 18 g), which matches the 3–4× rise
  seen. Food search was closer than the typed number.
- **Everything else is tangled up**: two meals and four doses within two hours, meals logged
  after they were eaten, or a falling high before the meal. ForecastAccuracy.md §12 found the
  same: with every dose given at a meal, about ten meals can't separate the carbs' rise from
  the insulin's fall, so a meal's "implied carbs" moves with whatever insulin effect is assumed.

### When a per-food note would be safe

A note on a food ("this usually raises you more than its carbs suggest") should need, for the
same food (`foodID`), at least 3 meals that each:

- start in range (about 80–180 mg/dL) and not moving fast in the 30 minutes before,
- have no low in the 2 hours before, no hypo-treatment tag, and no other carbs or extra dose
  within 3 hours after,
- were logged within 15 minutes of eating (no rise in the 30 minutes before),

and all of them pointing the same way by more than about 30%. Even then it should be a note
only: it never changes the food's carbs, the meal's total or anything the bolus calculator
works out, and the double-dose warning is untouched. With this logging pace (about 2 meals a
day, mostly different foods), the first food to qualify is likely weeks away.

### Worth doing sooner

- **Check a typed total against its description.** When the user types foods and a total, food
  search can already read the words. If it finds much more (say 1.5× or more), it could show
  "These foods usually come to about 112 g" next to the total, without changing it.
- **Keep hypo treatments apart.** A meal tagged as hypo treatment, or eaten under about 70 mg/dL,
  should never count towards a food's note, or towards the carb effect the forecast learns.
