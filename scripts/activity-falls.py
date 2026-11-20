#!/usr/bin/env python3
"""Forecasts in the 2 hours after an activity-like fall (ForecastAccuracy.md §108).

Usage: python3 scripts/activity-falls.py DIR
DIR holds readings.json ([[unix, mgdl], ...], live readings only, glucos.readings where trend > 0)
and logs.json ([[unix, "meal" | "dose"], ...], meals and rapid doses from glucos.logbook), as for
scripts/unassisted-falls.py (§82) and scripts/fast-falls-in-range.py (§100).

The app stores no HealthKit steps or workouts, and no Logbook entry is tagged Exercise (§57's
count), so activity is inferred from glucose alone, judged only from what the app has at issue time.
A reading is an **activity-like fall** when all of these hold:
  - Perth 06:00-22:00 (awake hours),
  - the reading is 80-180 and no reading above 180 landed in the 60 minutes before (so not §82's
    fall back from high, and not most of §100's fast falls),
  - the engine's 20-minute trend is -1 mg/dL a minute or steeper,
  - no rapid dose in the 3 hours before and no meal in the 2 hours before.
Forecasts issued at or within 2 hours after any activity-like fall reading are the **after** group
(the fall itself included); everything else is **rest**.

Replays the engine's trend forecast (20-minute least-squares slope clamped at +-4, 30-minute fade,
minute midpoint integration) every 5 minutes and scores it at 15, 30 and 60 minutes at the gains
the tuner fits (0.45 Mac/relay, 0.6, 0.7 iPhone). Bias = actual - forecast (+ = line ran low).

Tweak, fitted on all but one Perth day and scored on the left-out day (objective: miss at 30 + 60
on the after group): the trend of after-group forecasts is scaled by w (1 = as ships). Ship bar:
better held out at both 30 and 60 minutes on most days at every gain, and no low warning later.
"""
import bisect, datetime as dt, json, statistics as st, sys

d = sys.argv[1]
R = json.load(open(f"{d}/readings.json"))
L = json.load(open(f"{d}/logs.json"))
T = [r[0] for r in R]
G = {r[0]: r[1] for r in R}
meals = sorted(t for t, k in L if k == "meal")
doses = sorted(t for t, k in L if k == "dose")
FADE, TREND_W, MAX = 30.0, 20, 4.0
GAINS = (0.45, 0.6, 0.7)
H = (15, 30, 60)
WS = (0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.35, 1.5)


def window(t, minutes):
    i, j = bisect.bisect_left(T, t - minutes * 60), bisect.bisect_right(T, t)
    return [((T[k] - t) / 60, R[k][1]) for k in range(i, j)]


def slope(pts, span=9):
    if len(pts) < 3 or pts[-1][0] - pts[0][0] < span: return None
    mx = st.mean(p[0] for p in pts); my = st.mean(p[1] for p in pts)
    sxx = sum((p[0] - mx) ** 2 for p in pts)
    return max(-MAX, min(MAX, sum((p[0] - mx) * (p[1] - my) for p in pts) / sxx)) if sxx else None


def line(g, trend, gain, minutes=60):
    out, u = {}, 0
    while u < minutes:
        w = max(0, 1 - (u + 0.5) / FADE)
        g += w * gain * trend
        u += 1
        out[u] = min(401, max(39, g))
    return out


def at(t, tol=90):
    i = bisect.bisect_left(T, t)
    best = min((j for j in (i - 1, i) if 0 <= j < len(T)), key=lambda j: abs(T[j] - t), default=None)
    return R[best][1] if best is not None and abs(T[best] - t) <= tol else None


def perth(t, f="%d"): return dt.datetime.fromtimestamp(t + 8 * 3600, dt.UTC).strftime(f)


def recent(xs, t, secs):
    j = bisect.bisect_right(xs, t) - 1
    return j >= 0 and t - xs[j] < secs


def activity_fall(t):
    g = G[t]
    if not (80 <= g <= 180) or not (6 <= int(perth(t, "%H")) < 22): return False
    tr = slope(window(t, TREND_W))
    if tr is None or tr > -1: return False
    if max(v for _, v in window(t, 60)) > 180: return False
    return not recent(doses, t, 3 * 3600) and not recent(meals, t, 2 * 3600)


falls = [t for t in T if activity_fall(t)]


def after(t):
    j = bisect.bisect_right(falls, t) - 1
    return j >= 0 and t - falls[j] <= 2 * 3600


# Episodes: activity-like fall readings no more than 15 minutes apart.
eps = []
for t in falls:
    if eps and t - eps[-1][-1] <= 15 * 60: eps[-1].append(t)
    else: eps.append([t])

pts = []
for slot in range(T[0] - T[0] % 300 + 300, T[-1] - 3600, 300):
    i = bisect.bisect_right(T, slot) - 1
    if i < 0 or slot - T[i] >= 60: continue
    t = T[i]
    tr = slope(window(t, TREND_W))
    if tr is None: continue
    act = {h: at(t + h * 60, 120) for h in H}
    if None in act.values(): continue
    pts.append(dict(t=t, g=G[t], tr=tr, act=act, day=perth(t), aft=after(t),
                    falling=activity_fall(t), awake=6 <= int(perth(t, "%H")) < 22))
days = sorted({p["day"] for p in pts})
A = [p for p in pts if p["aft"]]
REST = [p for p in pts if not p["aft"]]
AWAKE_REST = [p for p in REST if p["awake"]]


def pred(p, h, gain, w=1.0):
    return line(p["g"], p["tr"] * (w if p["aft"] else 1), gain)[h]


def mae(s, h, f): return st.mean(abs(p["act"][h] - f(p)) for p in s)


print(f"{len(R)} live readings, {len(pts)} forecast points over {len(days)} Perth days ({days[0]}–{days[-1]} Nov)")
print(f"{len(falls)} activity-like fall readings in {len(eps)} episodes on {len({perth(e[0]) for e in eps})} days")
for e in eps:
    g0, g1 = G[e[0]], G[e[-1]]
    nadir = min(G[x] for x in T[bisect.bisect_left(T, e[0]):bisect.bisect_right(T, e[-1] + 7200)])
    print(f"   {perth(e[0], '%d %H:%M')}–{perth(e[-1], '%H:%M')}  {g0}->{g1}  lowest in 2 h after {nadir}")
print(f"after group {len(A)} points on {len({p['day'] for p in A})} days (during the fall {sum(p['falling'] for p in A)}); "
      f"rest {len(REST)} (awake rest {len(AWAKE_REST)})")
print(f"   mean start after {st.mean(p['g'] for p in A):.0f}, trend {st.mean(p['tr'] for p in A):+.2f}; "
      f"awake rest {st.mean(p['g'] for p in AWAKE_REST):.0f}, {st.mean(p['tr'] for p in AWAKE_REST):+.2f}")

print("\n== Miss: no change / ships (bias = actual - ships)")
for gain in GAINS:
    print(f"-- gain {gain}")
    for name, s in (("after", A), ("  during fall", [p for p in A if p["falling"]]),
                    ("  after, not falling", [p for p in A if not p["falling"]]),
                    ("awake rest", AWAKE_REST), ("all rest", REST)):
        print(f"   {name:21s} {len(s):5d}  " + "  ".join(
            f"{h}: {mae(s, h, lambda p: p['g']):5.1f} / {mae(s, h, lambda p: pred(p, h, gain)):5.1f} "
            f"({st.mean(p['act'][h] - pred(p, h, gain) for p in s):+5.1f})" for h in H))

print("\n== After group by Perth day, gain 0.45: n, bias 30 / 60, share of readings under 70 at 60")
for dd in days:
    s = [p for p in A if p["day"] == dd]
    if s:
        print(f"   {dd} Nov: {len(s):3d}  {st.mean(p['act'][30] - pred(p, 30, .45) for p in s):+6.1f} / "
              f"{st.mean(p['act'][60] - pred(p, 60, .45) for p in s):+6.1f}   {100 * st.mean(p['act'][60] < 70 for p in s):3.0f}%")

print("\n== Held out (leave one Perth day out): trend x w on the after group")
for gain in GAINS:
    held, picks = {}, {}
    for dd in days:
        tr_ = [p for p in A if p["day"] != dd]
        w = min(WS, key=lambda w: (sum(abs(p["act"][h] - pred(p, h, gain, w)) for p in tr_ for h in (30, 60)), abs(w - 1)))
        picks[dd] = w
        for p in pts:
            if p["day"] == dd:
                for h in H: held[(p["t"], h)] = abs(p["act"][h] - pred(p, h, gain, w))
    print(f"-- gain {gain}: picks " + ", ".join(f"{k}:{v}" for k, v in picks.items()))
    ad = [dd for dd in days if any(p["day"] == dd for p in A)]
    for h in H:
        b = mae(pts, h, lambda p: pred(p, h, gain)); a = st.mean(held[(p["t"], h)] for p in pts)
        ba = mae(A, h, lambda p: pred(p, h, gain)); aa = st.mean(held[(p["t"], h)] for p in A)
        per = [(st.mean(held[(p["t"], h)] for p in A if p["day"] == dd),
                mae([p for p in A if p["day"] == dd], h, lambda p: pred(p, h, gain))) for dd in ad]
        print(f"   {h:2d} min  all {b:6.2f} -> {a:6.2f} ({(a / b - 1) * 100:+5.2f}%)   after {ba:5.1f} -> {aa:5.1f} "
              f"({(aa / ba - 1) * 100:+5.1f}%)   days better/worse {sum(x < y - 1e-9 for x, y in per)}/"
              f"{sum(x > y + 1e-9 for x, y in per)} of {len(ad)}")

print("\n== Fixed w on the after group, all days, gain 0.45: miss 15 / 30 / 60")
for w in WS:
    print(f"   w={w:4}: " + " / ".join(f"{mae(A, h, lambda p: pred(p, h, .45, w)):5.1f}" for h in H))

# Lows inside the after window and how early a 30-minute predicted-low check fires on them.
lows, below = [], False
for t, g in R:
    if g < 70 and not below and (not lows or t - lows[-1] > 3600): lows.append(t)
    below = g < 70
al = [l for l in lows if after(l)]


def lead(low, w, gain):
    for t in T[bisect.bisect_left(T, low - 90 * 60):bisect.bisect_right(T, low)]:
        if G[t] < 70: continue
        tr = slope(window(t, TREND_W))
        if tr is None or tr > -0.3: continue
        if after(t): tr *= w
        if min(line(G[t], tr, gain, 30).values()) < 70: return (low - t) / 60
    return 0.0


print(f"\n== Lows: {len(lows)} under 70, {len(al)} inside an after window: " + ", ".join(perth(l, "%d %H:%M") for l in al))
for gain in GAINS:
    for w in (0.8, 1.0, 1.2, 1.35):
        print(f"   gain {gain} w={w}: leads " + ", ".join(f"{lead(l, w, gain):.0f}" for l in al))
