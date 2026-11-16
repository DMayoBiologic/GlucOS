#!/usr/bin/env python3
"""Forecasts after back-to-back meals (ForecastAccuracy.md §43).

Usage: python3 scripts/stacked-meals.py DIR [FADE_MINUTES]
DIR holds readings.txt: one line of epoch:mgdl pairs, comma separated, live readings (trend > 0)
from glucos.readings over the stacked meals and the 2 hours after the second, e.g.

  select string_agg(extract(epoch from at)::bigint || ':' || round(mgdl), ',' order by at)
  from glucos.readings where trend > 0 and at between '2026-11-12 05:00+00' and '2026-11-12 11:10+00';

The meal and dose times below are the only stacked pair so far (12 Nov 14:09 sushi, 53.9 g;
15:23 green juice, 16.6 g; NovoRapid 7 U at the sushi and 4 U at 14:43; the 19:08 burrito bowl ends
scoring). Edit them for a new pair. Replays the engine's maths every 5 minutes for 2 hours after
the second meal (20-minute trend, 60% gain, fade, K 2.8 mg/dL per g on the meal curve, S 19.2 mg/dL
per unit on the rapid curve) and scores 15-90 minutes against the readings, for the shipped
two-curve model and ways of combining the two meals' absorption.
"""
import bisect, math, statistics as st, sys
raw = open(sys.argv[1] + '/readings.txt').read().strip()
R = sorted((int(a), float(b)) for a, b in (x.split(':') for x in raw.split(',')))
T = [r[0] for r in R]
SUSHI, JUICE, BURRITO = 1794463743, 1794468191, 1794481712
doses = [(1794463743, 7), (1794465801, 4), (1794481712, 4)]
K, S, GAIN = 2.8, 19.2, 0.6
def carb_rate(el, grams, delay=600, absorb=3*3600):  # grams per minute
    x = (el - delay) / absorb
    if x <= 0 or x >= 1: return 0
    sc = 2 / (1 + 0.5 - 0.15)
    pu = sc * x / 0.15 if x < 0.15 else sc if x < 0.5 else sc * (1 - x) / 0.5
    return grams * pu / absorb * 60
def frac_absorbed(el, delay=600, absorb=3*3600):
    x = (el - delay) / absorb; sc = 2 / 1.35
    if x <= 0: return 0
    if x < .15: return .5 * sc * x * x / .15
    if x < .5: return sc * (x - .075)
    if x < 1: return sc * (.5 - .075 + (x - .5) * (1 - .5 * (x - .5) / .5))
    return 1
# insulin exponential rapid
def ins_act(el, delay=600, peak=75*60, dur=6*3600):
    t = el - delay
    if t <= 0 or t >= dur: return 0
    tau = peak * (1 - peak / dur) / (1 - 2 * peak / dur); a = 2 * tau / dur; s = 1 / (1 - a + (1 + a) * math.exp(-dur / tau))
    return (s / tau ** 2) * t * (1 - t / dur) * math.exp(-t / tau) * 60  # per minute
def slope(t):
    i, j = bisect.bisect_left(T, t - 1200), bisect.bisect_right(T, t)
    p = [((T[k] - t) / 60, R[k][1]) for k in range(i, j)]
    if len(p) < 2: return None
    mx = st.mean(x for x, _ in p); my = st.mean(y for _, y in p)
    sxx = sum((x - mx) ** 2 for x, _ in p)
    return max(-4, min(4, sum((x - mx) * (y - my) for x, y in p) / sxx))
def at(t, tol=150):
    i = bisect.bisect_left(T, t)
    c = [j for j in (i - 1, i) if 0 <= j < len(T)]
    j = min(c, key=lambda j: abs(T[j] - t))
    return R[j][1] if abs(T[j] - t) <= tol else None
def variants():
    yield 'ships (two curves)', lambda t: carb_rate(t - SUSHI, 53.9) + carb_rate(t - JUICE, 16.6)
    for ab in (4, 5):
        yield f'second meal over {ab} h', lambda t, ab=ab: carb_rate(t - SUSHI, 53.9) + carb_rate(t - JUICE, 16.6, absorb=ab*3600)
    for d in (30, 60, 90):
        yield f'second meal waits {d} min', lambda t, d=d: carb_rate(t - SUSHI, 53.9) + carb_rate(t - JUICE, 16.6, delay=600 + d*60)
    # queue: second meal starts when first is 80% absorbed
    el = 0
    while frac_absorbed(el) < .8: el += 60
    q = SUSHI + el - JUICE
    yield f'queued behind first (starts at 80% absorbed, +{q//60} min)', lambda t: carb_rate(t - SUSHI, 53.9) + carb_rate(t - JUICE, 16.6, delay=600 + q)
    # merged: both as one meal from the first log, absorbed over 3h + gap
    gap = JUICE - SUSHI
    yield 'merged into one meal, stretched', lambda t: carb_rate(t - SUSHI, 53.9 + 16.6, absorb=3*3600 + gap)
    for ab in (4, 5):
        yield f'both meals over {ab} h', lambda t, ab=ab: carb_rate(t - SUSHI, 53.9, absorb=ab*3600) + carb_rate(t - JUICE, 16.6, absorb=ab*3600)
    yield 'no change (flat)', None
def forecast(t0, carbs, fade):
    g = at(t0, 60); tr = slope(t0)
    if g is None or tr is None: return None
    out = {}
    if carbs is None: return {m: g for m in (15, 30, 45, 60, 90)}
    for m in range(90):
        mid = m + .5; tt = t0 + mid * 60; w = max(0, 1 - mid / fade)
        model = K * carbs(tt) - S * sum(u * ins_act(tt - d) for d, u in doses)
        g += w * GAIN * tr + (1 - w) * model
        if (m + 1) in (15, 30, 45, 60, 90): out[m + 1] = g
    return out
fade = float(sys.argv[2]) if len(sys.argv) > 2 else 30
H = (15, 30, 45, 60, 90)
print(f'fade {fade}; forecasts every 5 min from juice log to +2h')
for name, c in variants():
    errs = {h: [] for h in H}; lows = 0
    for t0 in range(JUICE, JUICE + 7201, 300):
        f = forecast(t0, c, fade)
        if not f: continue
        if c is not None and min(v for h, v in f.items() if h <= 30) < 70: lows += 1
        for h in H:
            if t0 + h * 60 >= BURRITO: continue
            a = at(t0 + h * 60)
            if a is not None: errs[h].append(f[h] - a)
    s = ' | '.join(f'{h}: {st.mean(map(abs, e)):5.1f} ({st.mean(e):+5.1f}) n{len(e)}' for h, e in errs.items() if e)
    print(f'{name:48s} {s}  lowwarn {lows}')
