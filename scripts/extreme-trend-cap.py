#!/usr/bin/env python3
"""ForecastAccuracy §50: does a tighter cap on the trend (below the shipped ±4 mg/dL a minute)
lower 30- and 60-minute forecast error?

Input: a JSON list of points exported with the SQL in docs/ForecastAccuracy.md §50, each
{"day": "MMDD" (Perth), "h": 30|60, "lg": bool (meal/rapid dose within 3 h before → target),
 "v0": start mg/dL, "sl": 20-min least-squares slope (uncapped), "a": actual at target}.

Usage: python3 scripts/extreme-trend-cap.py pts.json
"""
import json
import sys

CAPS = [1.5, 2, 2.5, 3, 3.5, 4]  # 4 is what ships (GlucoseForecaster.maxTrendPerMinute)
R = json.load(open(sys.argv[1]))


def clamp(s, c):
    return max(-c, min(c, s))


def forecast(p, gain, cap):
    # Trend-only line: the trend fades over 30 min, so it adds gain × trend × 15 at 30 and 60 min.
    # Like the engine, the central line is held to one past the sensor range (40...400).
    return min(401, max(39, p["v0"] + gain * 15 * clamp(p["sl"], cap)))


def mae(ps, gain, cap):
    return sum(abs(p["a"] - forecast(p, gain, cap)) for p in ps) / len(ps) if ps else float("nan")


for gain in (0.45, 0.6, 0.7):
    print(f"gain {gain}")
    for h in (30, 60):
        for label, keep in (("clean", lambda p: not p["lg"]), ("all", lambda p: True)):
            ps = [p for p in R if p["h"] == h and keep(p)]
            fast = [p for p in ps if abs(p["sl"]) > 3]
            cells = " ".join(f"c{c}:{mae(ps, gain, c):.2f}/{mae(fast, gain, c):.1f}" for c in CAPS)
            print(f"  {h} min {label} n={len(ps)} fast={len(fast)}  {cells}")

print("held out by Perth day (clean), cap picked on the other days")
days = sorted({p["day"] for p in R})
for gain in (0.45, 0.6):
    for h in (30, 60):
        ps = [p for p in R if p["h"] == h and not p["lg"]]
        shipped = capped = 0.0
        for d in days:
            train = [p for p in ps if p["day"] != d]
            test = [p for p in ps if p["day"] == d]
            if not test:
                continue
            cap = min(CAPS, key=lambda c: (mae(train, gain, c), -c))
            shipped += sum(abs(p["a"] - forecast(p, gain, 4)) for p in test)
            capped += sum(abs(p["a"] - forecast(p, gain, cap)) for p in test)
        print(f"  gain {gain} {h} min: {shipped / len(ps):.2f} -> {capped / len(ps):.2f}"
              f" ({(capped / shipped - 1) * 100:+.1f}%)")

print("lows: forecast points (both horizons) on falls faster than 3 that ended under 70,"
      " line under 90 (cap 4 / cap 3)")
for gain in (0.45, 0.6):
    lows = [p for p in R if p["sl"] < -3 and p["a"] < 70]
    print(f"  gain {gain}: {len(lows)} points,"
          f" {sum(forecast(p, gain, 4) < 90 for p in lows)} / {sum(forecast(p, gain, 3) < 90 for p in lows)}")
