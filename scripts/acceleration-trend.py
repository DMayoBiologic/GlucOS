#!/usr/bin/env python3
"""Does a damped acceleration term help the trend forecast? (ForecastAccuracy.md §39)

Usage: python3 scripts/acceleration-trend.py DIR
DIR holds readings.json ([[unix, mgdl], ...], live readings only, one per minute, from
glucos.readings where trend > 0) and logs.json ([[unix, kind], ...] meals from glucos.logbook).

Replays the engine's trend forecast (20-minute least-squares slope, 30-minute fade, 60% gain,
minute midpoint integration) every 5 minutes and scores it at 15 and 30 minutes. The candidate adds
the curvature of the last W minutes (quadratic fit, acceleration = 2c, mg/dL per minute squared) to
the slope as it fades: rate(u) = w(u)·gain·(trend + k·accel·min(u + W/2, cap)). The W/2 is because the
least-squares slope is the slope at the middle of its window, not now. k, cap and W are fitted on the
other Perth days (leave one day out) and scored on the held-out day. Then the same for low
warnings: every minute in the 90 minutes before each low (under 70), when did the trend carried 30
minutes first go under 70?
"""
import bisect, datetime as dt, itertools, json, statistics as st, sys

d = sys.argv[1]
R = json.load(open(f"{d}/readings.json"))
L = json.load(open(f"{d}/logs.json"))
T = [r[0] for r in R]
G = {r[0]: r[1] for r in R}
meals = sorted(t for t, k in L if k == "meal")
GAIN, FADE, TREND_W, MAX = 0.6, 30.0, 20, 4.0

def window(t, minutes):
    i, j = bisect.bisect_left(T, t - minutes * 60), bisect.bisect_right(T, t)
    return [((T[k] - t) / 60, R[k][1]) for k in range(i, j)]

def slope(pts):
    if len(pts) < 2 or pts[-1][0] - pts[0][0] < 9: return None
    mx = st.mean(p[0] for p in pts); my = st.mean(p[1] for p in pts)
    sxx = sum((p[0] - mx) ** 2 for p in pts)
    return max(-MAX, min(MAX, sum((p[0] - mx) * (p[1] - my) for p in pts) / sxx)) if sxx else None

def accel(pts):
    """2c from a least-squares quadratic; needs 10+ readings over 12+ minutes."""
    if len(pts) < 10 or pts[-1][0] - pts[0][0] < 12: return None
    import numpy as np
    x = np.array([p[0] for p in pts]); y = np.array([p[1] for p in pts])
    return 2 * float(np.polyfit(x, y, 2)[0])

def forecast(g, trend, acc=0.0, k=0.0, cap=0.0, w_acc=20, minutes=30):
    out, u = {}, 0
    while u < minutes:
        mid = u + 0.5
        w = max(0, 1 - mid / FADE)
        s = trend + k * acc * min(mid + w_acc / 2, cap)
        g += w * GAIN * max(-MAX, min(MAX, s))
        u += 1
        out[u] = g
    return out

def at(t, tol=120):
    i = bisect.bisect_left(T, t)
    best = min((j for j in (i - 1, i) if 0 <= j < len(T)), key=lambda j: abs(T[j] - t), default=None)
    return R[best][1] if best is not None and abs(T[best] - t) <= tol else None

def perth_day(t): return dt.datetime.fromtimestamp(t + 8 * 3600, dt.UTC).strftime("%d")

# Build the 5-minute forecast points.
pts = []
for t in range(T[0] - T[0] % 300 + 300, T[-1] - 1800, 300):
    if t not in G: continue
    tr = slope(window(t, TREND_W))
    if tr is None: continue
    a15, a20 = accel(window(t, 15)), accel(window(t, 20))
    if a15 is None or a20 is None: continue
    act = {h: at(t + h * 60) for h in (15, 30)}
    if None in act.values(): continue
    tr_later = slope(window(t + 900, TREND_W))
    i = bisect.bisect_right(meals, t) - 1
    after_meal = i >= 0 and t - meals[i] < 3 * 3600
    turning = tr_later is not None and abs(tr) >= 0.5 and tr * tr_later < 0
    pts.append(dict(t=t, g=G[t], tr=tr, acc={15: a15, 20: a20}, act=act, day=perth_day(t),
                    meal=after_meal, turning=turning))
days = sorted({p["day"] for p in pts})
GRID = list(itertools.product((0, .1, .2, .3, .5, .75, 1.0), (5, 10, 15, 20, 30), (15, 20)))

def pred(p, prm, h):
    k, cap, w = prm
    return forecast(p["g"], p["tr"], p["acc"][w], k, cap, w)[h]

cache = {}
def err(p, prm, h):
    key = (p["t"], prm, h)
    if key not in cache: cache[key] = abs(pred(p, prm, h) - p["act"][h])
    return cache[key]
BASE = (0, 5, 20)

print(f"{len(pts)} forecast points over {len(days)} Perth days ({days[0]}–{days[-1]} Nov); "
      f"{sum(p['turning'] for p in pts)} at turning points, {sum(p['meal'] for p in pts)} within 3 h of a meal")

held = {}  # (t, h) -> held-out error
picks = []
for day in days:
    tr = [p for p in pts if p["day"] != day]; te = [p for p in pts if p["day"] == day]
    best = min(GRID, key=lambda prm: sum(err(p, prm, 15) + err(p, prm, 30) for p in tr))
    picks.append((day, best))
    for p in te:
        for h in (15, 30): held[(p["t"], h)] = err(p, best, h)
print("fitted (k, cap, W) by held-out day:", ", ".join(f"{d}:{b}" for d, b in picks))

def row(name, sel):
    s = [p for p in pts if sel(p)]
    if not s: return
    cells = []
    for h in (15, 30):
        nc = st.mean(abs(p["act"][h] - p["g"]) for p in s)
        b = st.mean(err(p, BASE, h) for p in s)
        c = st.mean(held[(p["t"], h)] for p in s)
        cells.append(f"{nc:5.1f} {b:5.1f} {c:5.1f}")
    print(f"{name:26s} n={len(s):4d}  15 min: no change/now/accel {cells[0]}   30 min: {cells[1]}")

print("\nheld-out mean miss, mg/dL")
row("all", lambda p: True)
row("quiet (no meal in 3 h)", lambda p: not p["meal"])
row("within 3 h of a meal", lambda p: p["meal"])
row("turning points", lambda p: p["turning"])
row("falling (trend < -1)", lambda p: p["tr"] < -1)
row("rising (trend > 1)", lambda p: p["tr"] > 1)
for day in days:
    row(f"day {day}", lambda p, d=day: p["day"] == d)

print("\nfixed settings, all days (no hold-out), 15 / 30 min")
for prm in [(0, 5, 20), (.1, 10, 15), (.2, 10, 15), (.3, 15, 15), (.5, 15, 20), (1.0, 30, 20)]:
    print(f"  k={prm[0]:<4} cap={prm[1]:<2} W={prm[2]}  "
          f"{st.mean(err(p, prm, 15) for p in pts):5.2f} {st.mean(err(p, prm, 30) for p in pts):5.2f}   "
          f"turning {st.mean(err(p, prm, 15) for p in pts if p['turning']):5.2f} "
          f"{st.mean(err(p, prm, 30) for p in pts if p['turning']):5.2f}")

# Low warnings: tick every minute.
lows, below = [], False
for t, g in R:
    if g < 70 and not below and (not lows or t - lows[-1] > 3600): lows.append(t)
    below = g < 70
def warn_at(t, prm):
    tr = slope(window(t, TREND_W))
    if tr is None or t not in G: return False
    k, cap, w = prm
    a = accel(window(t, w)) if k else 0.0
    if a is None: a = 0.0
    f = forecast(G[t], tr, a, k, cap, w)
    return min(f.values()) < 70
def first_warning(low, prm):
    for t in range(low - 90 * 60, low + 60, 60):
        if t in G and G[t] >= 70 and warn_at(t, prm): return (low - t) / 60
    return 0.0
cands = sorted({b for _, b in picks} | {(.2, 10, 15), (.5, 15, 20)})
print(f"\n{len(lows)} lows under 70 (an hour apart); minutes of warning from the trend carried 30 min")
print("low (Perth)        " + "  ".join(f"{str(c):>14s}" for c in [BASE] + cands))
for low in lows:
    ws = [first_warning(low, c) for c in [BASE] + cands]
    print(dt.datetime.fromtimestamp(low + 8 * 3600, dt.UTC).strftime("%d %b %H:%M") + "       " +
          "  ".join(f"{w:14.0f}" for w in ws))
# False alarms: warnings (start of a run of warned minutes) with no reading under 70 in the next 45 min.
for c in [BASE] + cands:
    fa = n = 0; prev = False
    for t in range(T[0] + 1200, T[-1] - 2700, 60):
        w = t in G and G[t] >= 70 and warn_at(t, c)
        if w and not prev:
            n += 1
            if min((g for tt, g in R[bisect.bisect_left(T, t):bisect.bisect_right(T, t + 2700)]), default=999) >= 70: fa += 1
        prev = w
    print(f"{str(c):14s} warnings {n:3d}, false alarms {fa:3d}")
