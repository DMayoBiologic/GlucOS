#!/usr/bin/env python3
"""How far can a small logged meal move the forecast line? (ForecastAccuracy.md §83)

Usage: python3 scripts/small-meals.py [K]
K is the learnt carb effect in mg/dL per gram (2.8 on this history). Mirrors the engine: the
standard carb curve (10-min delay, 3-h absorption, rise to 15%, fall from 50%), the 5 g tail below
which carbs don't count (CarbActivity.tailGrams), and the model weight (1 - w) under the 30-minute
trend fade. Prints the carb part of the line at 30 and 60 minutes for meals of 5-20 g, issued
0-180 minutes after eating. Before 60 minutes the line is trend only (freshLog) unless this
device's fresh-model checks allow it, so both are shown.
"""
import sys
K = float(sys.argv[1]) if len(sys.argv) > 1 else 2.8
DELAY, ABS, RISE, FALL = 10, 180, 0.15, 0.5
SCALE = 2 / (1 + FALL - RISE)

def frac(t):
    x = (t - DELAY) / ABS
    if x <= 0: return 0
    if x < RISE: return 0.5 * SCALE * x * x / RISE
    if x < FALL: return SCALE * (x - 0.5 * RISE)
    if x < 1: return SCALE * (FALL - 0.5 * RISE + (x - FALL) * (1 - 0.5 * (x - FALL) / (1 - FALL)))
    return 1

def carb_part(grams, after, horizon, fade=30):
    if grams * (1 - frac(after)) < 5: return 0.0   # under the tail: the forecast ignores it
    return sum(max(0, min(1, (u + 0.5) / fade)) * K * grams * (frac(after + u + 1) - frac(after + u))
               for u in range(horizon))

print(f"K = {K} mg/dL per g. Carb part of the line, 30 / 60 min, by minutes since the meal")
print("grams  " + "  ".join(f"{a:>3d} min  " for a in (0, 30, 60, 90, 120, 150)))
for g in (5, 6, 8, 10, 12, 15, 20):
    print(f"{g:5d}  " + "  ".join(f"{carb_part(g, a, 30):4.1f}/{carb_part(g, a, 60):4.1f}" for a in (0, 30, 60, 90, 120, 150)))
