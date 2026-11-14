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

A change is offered for a time block only with at least 5 examples, a spread (IQR ÷ median) of
0.5 or less, and a difference of 10% or more. It moves at most 20% at a time, comes with the
evidence and a confidence level, and is applied only if the user taps **Try it**, re-confirms
and saves.

Tests: `BolusCalculatorTests`, `BolusSettingsReviewTests` (simulated people with known ratios),
`FoodDatabaseTests`, and the sync tests.
