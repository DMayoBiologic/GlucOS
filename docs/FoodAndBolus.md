# Food search and the bolus calculator

## Food search

The log sheet's **Search foods** (Mac and iPhone) finds foods and works out their carbs from a
portion.

- **Built-in list:** AUSNUT 2023 from Food Standards Australia New Zealand: 3,741 foods with
  9,000+ household measures (slice, cup, medium banana…). Carbs are *available carbohydrate
  without sugar alcohols* per 100 g, which leaves out fibre, as carb counting does. Licensed
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/); the app credits FSANZ under the
  results. Bundled as `Sources/Food/ausnut-foods.json`, built by `scripts/food/build_ausnut.py`
  in the **Food data** workflow (run it by hand to pick up a new FSANZ release).
- **Packaged products:** an optional online search of Open Food Facts (ODbL), Australian
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

at or above target:  total = food + max(0, correction − insulin on board)
below target:        total = max(0, food + correction − insulin on board)
no fresh reading,
or falling fast:     total = max(0, food − insulin on board)    (no correction)

then: cap at the maximum, round DOWN to the dose step
```

Insulin on board is the engine's figure from logged fast-acting doses (long-acting and NPH aren't
counted). The glucose forecast is never used.

**Safety gates:**

| Situation | What happens |
|---|---|
| Glucose below the low threshold | No suggestion: treat the low first |
| Falling fast (≤ −2 mg/dL/min) and heading under the low threshold within 20 min | No suggestion |
| Falling fast but high | Correction left out; insulin on board comes off the food dose |
| Last reading older than 15 min, or none | No correction; a finger-prick value can be typed in |
| Above the maximum | Capped, and says so |
| Very high (≥ 16.7 mmol/L) | Check ketones / site |
| Low or hypo treatment in the last hour, recent bolus, exercise, pump user | Notes |

**Use** only fills in the dose; logging it asks for confirmation, and the dose keeps the
calculator's working (`InsulinDose.calculation`). Every view says it's not medical advice.

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
