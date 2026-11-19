#!/usr/bin/env python3
"""Meals logged ahead of eating: does the line rise too early? (ForecastAccuracy.md §93)

The engine starts a meal's carbs at log time (CarbAbsorptionCurve: 10-minute delay, 3 hours). A
meal logged 15+ minutes before glucose starts to climb (logged while ordering, before eating, or a
slow meal) would have its modelled rise come too early, so the line would run high at 15 and 30
minutes. This compares those meals with meals logged near the rise, and tries one forecast-only
onset hold, held out by day.

Usage: python3 -I scripts/early-logged-meals.py DIR
DIR holds:
  readings.json  [[unix, mgdl], ...]  glucos.readings where trend > 0
  logs.json      [[unix, kind, value, food, hypo], ...]  kind "meal" (value = carbs) or "rapid"
                 (value = units), from glucos.logbook (not deleted). hypo: a hypo context logged
                 within 2 minutes.
  points.json    (optional) clean shown 15/30/60-minute accuracy-log points:
                 [[unix, device, basis, minutes, line, lower, upper, actual, start, trend, limits], ...]

Meals: two meal entries within 15 minutes with the same carbs are one meal (a double log). A meal
of 45 g or less logged with a hypo tag or under 70 mg/dL is a low treatment (fast curve, 10 / 30
minutes, 1.5x, as LowTreatment) and is never an anchor. A meal's window runs from its log to 3 hours
after it or the next entry, whichever comes first; a rapid dose within 30 minutes of the meal is the
meal's own dose and doesn't end the window.

Rise onset: the reading trough before glucose first climbs 15 mg/dL above the lowest reading since
10 minutes before the log, looking 2 hours ahead. Lag = onset - log. "Logged early" = lag of 15
minutes or more; "near the rise" = under 15. Meals with no such climb are "no rise".

Replay: the engine's model forecast every 5 minutes in each window (20-minute least-squares trend
clamped at +/-4, faded over 30 minutes at the tuner's gain, the model rate K x carbs - S x insulin
weighted by 1 - fade, K 2.8 mg/dL/g, S 19.2 mg/dL/U, rapid curve 10-min delay / 75-min peak / 6 h),
scored at 15/30/60 minutes against the reading nearest the target (within 2 minutes). A point
whose target comes after a later entry is dropped (the accuracy log's after_log rule).

Fix tried (forecast only; COB, the carb curve itself, carb ratio and insulin are unchanged): an
onset hold. Until glucose has climbed R mg/dL above its lowest reading since the log, a meal's
carb clock is held at "eaten now minus c" (never earlier than the log); once it has, the clock
starts 10 minutes before the trough. The hold never moves a meal more than cap minutes. R, c and
cap are picked on the other Perth days and scored on the held-out one (leave one day out, over the
days with meal windows), by 15- plus 30-minute MAE in meal windows. Ship bar: better at 15 and 30
on most held-out days at every gain, 60 no worse, and early meals better without near-rise meals
getting worse.
"""
import bisect, datetime as dt, json, math, os, statistics as st, sys
from collections import defaultdict

d = sys.argv[1]
R = json.load(open(f"{d}/readings.json"))
L = json.load(open(f"{d}/logs.json"))
T = [r[0] for r in R]
K, S, FADE, MAX = 2.8, 19.2, 30.0, 4.0
GAINS = (0.45, 0.6, 0.7)
HS = (15, 30, 60)
EARLY = 15 * 60

def perth(t): return dt.datetime.fromtimestamp(t + 8 * 3600, dt.UTC)
def lab(t): return perth(t).strftime("%d Nov %H:%M")

def at(t, tol=120):
    i = bisect.bisect_left(T, t)
    c = [j for j in (i - 1, i) if 0 <= j < len(T)]
    if not c: return None
    j = min(c, key=lambda j: abs(T[j] - t))
    return R[j][1] if abs(T[j] - t) <= tol else None

def window(a, b): return R[bisect.bisect_left(T, a):bisect.bisect_right(T, b)]

def slope(t):
    pts = [((x - t) / 60, g) for x, g in window(t - 1200, t)]
    if len(pts) < 3 or pts[-1][0] - pts[0][0] < 9: return None
    mx = st.mean(p[0] for p in pts); my = st.mean(p[1] for p in pts)
    sxx = sum((p[0] - mx) ** 2 for p in pts)
    return max(-MAX, min(MAX, sum((p[0] - mx) * (p[1] - my) for p in pts) / sxx)) if sxx else None

def carb_rate(e, delay=600, absorb=10800):
    x = (e - delay) / absorb
    rise, fall = 0.15, 0.5
    sc = 2 / (1 + fall - rise)
    u = 0 if x <= 0 or x >= 1 else sc * x / rise if x < rise else sc if x < fall else sc * (1 - x) / (1 - fall)
    return u / (absorb / 60)          # share per minute

def insulin_activity(e):
    delay, peak, dur = 600.0, 75 * 60.0, 6 * 3600.0
    tau = peak * (1 - peak / dur) / (1 - 2 * peak / dur)
    a = 2 * tau / dur
    s = 1 / (1 - a + (1 + a) * math.exp(-dur / tau))
    t = e - delay
    if t <= 0 or t >= dur: return 0
    return max(0, (s / tau ** 2) * t * (1 - t / dur) * math.exp(-t / tau)) * 60

# Entries
meals, doses = [], []
for t, k, v, food, hypo in sorted(L, key=lambda x: (x[0], x[1])):
    if k == "rapid": doses.append((t, v)); continue
    if meals and t - meals[-1]["t"] < 900 and abs(v - meals[-1]["g"]) < 1: continue
    g0 = at(t, 600)
    treat = v <= 45 and (hypo or (g0 is not None and g0 < 70))
    meals.append(dict(t=t, g=v, food=food, treat=treat))
entries = sorted([m["t"] for m in meals] + [x[0] for x in doses])

def onset(m, R_=15, upto=None):
    """Trough before the first R_ climb since 10 min before the log (only readings <= upto)."""
    end = m["t"] + 7200 if upto is None else min(upto, m["t"] + 7200)
    lo = None
    for x, g in window(m["t"] - 600, end):
        if lo is None or g < lo[1]: lo = (x, g)
        if g - lo[1] >= R_: return lo[0]
    return None

for m in meals:
    m["on"] = onset(m)
    m["lag"] = None if m["on"] is None else m["on"] - m["t"]
    own = [x for x in doses if abs(x[0] - m["t"]) <= 1800]
    nxt = [e for e in entries if e > m["t"] + 1 and not any(abs(e - o[0]) < 1 for o in own)]
    m["end"] = min([m["t"] + 3 * 3600] + nxt)
    m["grp"] = ("treatment" if m["treat"] else "no readings" if not window(m["t"] - 600, m["t"] + 1800) else
                "no rise" if m["lag"] is None else
                "logged early" if m["lag"] >= EARLY else "near the rise")

print("Meals (lag = rise onset - log; window = clean minutes after the log):")
for m in meals:
    lag = "   -  " if m["lag"] is None else f"{m['lag']/60:+5.0f}m"
    print(f"  {lab(m['t'])} {m['g']:5.1f} g {m['food'][:34]:34s} start {at(m['t'], 600)} lag {lag} "
          f"window {(m['end']-m['t'])/60:4.0f}m  {m['grp']}")

def meal_time(m, t0, prm):
    """Effective log time for the forecaster at issue t0."""
    if prm is None or m["treat"]: return m["t"]
    R_, c, cap = prm
    o = onset(m, R_, upto=t0)
    eff = (o - 600) if o is not None else (t0 - c * 60)
    return min(max(m["t"], eff), m["t"] + cap * 60)

def forecast(t0, g0, tr, gain, prm=None, h=60):
    known = [m for m in meals if m["t"] <= t0 and t0 - m["t"] < 4 * 3600]
    eff = [(meal_time(m, t0, prm), m) for m in known]
    ds = [x for x in doses if x[0] <= t0 and t0 - x[0] < 6.5 * 3600]
    g, out = g0, {}
    for u in range(h):
        mid = t0 + (u + 0.5) * 60
        w = max(0, 1 - (u + 0.5) / FADE)
        rate = 0.0
        for te, m in eff:
            if m["treat"]: rate += 1.5 * K * m["g"] * carb_rate(mid - te, 600, 1800)
            else: rate += K * m["g"] * carb_rate(mid - te)
        for tx, un in ds: rate -= S * un * insulin_activity(mid - tx)
        g += w * gain * tr + (1 - w) * rate
        out[u + 1] = max(39, min(401, g))
    return out

# Replay points in meal windows
pts = []
for m in meals:
    if m["treat"] or m["grp"] == "treatment": continue
    for k in range(5, 181, 5):
        t_iss = m["t"] + k * 60
        if t_iss >= m["end"]: break
        i = bisect.bisect_right(T, t_iss) - 1
        if i < 0 or t_iss - T[i] >= 300 or T[i] < m["t"]: continue
        t0, g0 = R[i]
        tr = slope(t0)
        if tr is None: continue
        act = {}
        for h in HS:
            if t0 + h * 60 > m["end"] and any(t0 < e <= t0 + h * 60 for e in entries): continue
            a = at(t0 + h * 60)
            if a is not None: act[h] = a
        if not act: continue
        pts.append(dict(t0=t0, g0=g0, tr=tr, act=act, m=m, since=(t0 - m["t"]) / 60,
                        pre=m["on"] is not None and t0 < m["on"], day=perth(m["t"]).strftime("%d")))
days = sorted({p["day"] for p in pts})
print(f"\nReplay: {len(pts)} forecasts in {len({id(p['m']) for p in pts})} meal windows on Perth days {days}")

cache = {}
def line(p, gain, prm=None):
    key = (id(p), gain, prm)
    if key not in cache: cache[key] = forecast(p["t0"], p["g0"], p["tr"], gain, prm)
    return cache[key]

def stats(sub, gain, h, prm=None):
    e = [p["act"][h] - line(p, gain, prm)[h] for p in sub if h in p["act"]]
    nc = [abs(p["act"][h] - p["g0"]) for p in sub if h in p["act"]]
    if not e: return None
    return len(e), st.mean(abs(x) for x in e), st.mean(e), st.mean(nc)

GROUPS = [
    ("logged early, all", lambda p: p["m"]["grp"] == "logged early"),
    ("logged early, before onset", lambda p: p["m"]["grp"] == "logged early" and p["pre"]),
    ("logged early, 0-60 min", lambda p: p["m"]["grp"] == "logged early" and p["since"] <= 60),
    ("logged early, 60-180 min", lambda p: p["m"]["grp"] == "logged early" and p["since"] > 60),
    ("near the rise, all", lambda p: p["m"]["grp"] == "near the rise"),
    ("near the rise, 0-60 min", lambda p: p["m"]["grp"] == "near the rise" and p["since"] <= 60),
    ("near the rise, 60-180 min", lambda p: p["m"]["grp"] == "near the rise" and p["since"] > 60),
    ("no rise", lambda p: p["m"]["grp"] == "no rise"),
    ("all meal windows", lambda p: True),
]
for gain in GAINS:
    print(f"\n== Gain {gain}, as ships (bias = actual - line; negative = line high) ==")
    for name, f in GROUPS:
        sub = [p for p in pts if f(p)]
        if not sub: continue
        cells = []
        for h in HS:
            s = stats(sub, gain, h)
            cells.append(f"{h}m n={s[0]:3d} mae {s[1]:5.1f} nc {s[3]:5.1f} bias {s[2]:+6.1f}" if s else f"{h}m -")
        print(f"  {name:28s} meals={len({id(p['m']) for p in sub}):2d} | " + " | ".join(cells))

# The carb part's own contribution before onset: how much rise the model drew that hadn't come
for gain in GAINS[:1]:
    sub = [p for p in pts if p["pre"] and p["m"]["grp"] == "logged early"]
    if sub:
        drawn = [line(p, gain)[30] - forecast(p["t0"], p["g0"], p["tr"], gain, (999, 0, 999))[30] for p in sub]
        for m in sorted({id(p["m"]): p["m"] for p in sub}.values(), key=lambda m: m["t"]):
            q = [p for p in sub if p["m"] is m]
            print(f"  {lab(m['t'])} {m['food'][:24]:24s} pre-onset pts {len(q):2d} 30-min bias as ships "
                  f"{st.mean(p['act'][30] - line(p, gain)[30] for p in q if 30 in p['act']):+6.1f}, held to now "
                  f"{st.mean(p['act'][30] - forecast(p['t0'], p['g0'], p['tr'], gain, (999, 0, 999))[30] for p in q if 30 in p['act']):+6.1f}")
        print(f"\nBefore onset on early meals (gain {gain}): onset hold changes the 30-min line by "
              f"{st.mean(drawn):+.1f} mg/dL on average (n={len(sub)})")

# Live accuracy log
if os.path.exists(f"{d}/points.json"):
    P = json.load(open(f"{d}/points.json"))
    g = defaultdict(list)
    for t, dev, basis, mins, f, lo, hi, a, s, tr, lim in P:
        c = [m for m in meals if not m["treat"] and m["t"] <= t < m["end"]]
        if not c: continue
        m = c[-1]
        if (t + mins * 60) > m["end"] and any(t < e <= t + mins * 60 for e in entries): continue
        phase = "0-60" if t - m["t"] <= 3600 else "60-180"
        g[(m["grp"], phase, mins)].append((a - f, a - s, lo is not None and lo <= a <= hi, basis, "freshLog" in (lim or "")))
    print("\nLive accuracy log in meal windows (bias = actual - line):")
    for k in sorted(g):
        v = g[k]
        print(f"  {k[0]:14s} {k[1]:6s} {k[2]:2d}m n={len(v):3d} mae {st.mean(abs(x[0]) for x in v):5.1f} "
              f"nc {st.mean(abs(x[1]) for x in v):5.1f} bias {st.mean(x[0] for x in v):+6.1f} "
              f"inside {100*st.mean(x[2] for x in v):3.0f}% model {sum(x[3]=='trendInsulinCarbs' for x in v)} fresh-trend {sum(x[4] for x in v)}")

# Held out: onset hold
GRID = [(r, c, cap) for r in (10, 15, 20) for c in (0, 10, 20) for cap in (20, 40, 60, 90)]
def score(sub, gain, prm, hs=(15, 30)):
    tot = 0
    for h in hs:
        s = stats(sub, gain, h, prm)
        tot += s[1] if s else 0
    return tot

for gain in GAINS:
    print(f"\n== Held out, gain {gain}: onset hold (R, c, cap) picked on the other days ==")
    picks, better = defaultdict(int), defaultdict(lambda: [0, 0])
    rows = []
    for dd in days:
        train = [p for p in pts if p["day"] != dd]; test = [p for p in pts if p["day"] == dd]
        best = min(GRID + [None], key=lambda prm: score(train, gain, prm))
        picks[best] += 1
        line_ = [dd, best]
        for scope, f in (("all", lambda p: True), ("early", lambda p: p["m"]["grp"] == "logged early"),
                         ("near", lambda p: p["m"]["grp"] == "near the rise")):
            sub = [p for p in test if f(p)]
            for h in HS:
                a, b = stats(sub, gain, h), stats(sub, gain, h, best)
                if a:
                    line_.append(f"{scope}{h} {a[1]:.1f}->{b[1]:.1f}")
                    if scope == "all": better[h][0 if b[1] < a[1] - 1e-9 else 1] += 1
        rows.append(line_)
    for r_ in rows: print("  ", *r_)
    print("  better on held-out days (all points):", {h: f"{better[h][0]}/{sum(better[h])}" for h in HS})
    print("  picks:", dict(picks))
    for prm in ((15, 0, 60), (15, 10, 60), (10, 0, 40)):
        print(f"  fixed {prm} in-sample:", " ".join(
            f"{n}{h} {stats([p for p in pts if f(p)], gain, h)[1]:.1f}->{stats([p for p in pts if f(p)], gain, h, prm)[1]:.1f}"
            for n, f in (("early", lambda p: p['m']['grp'] == 'logged early'), ("near", lambda p: p['m']['grp'] == 'near the rise'))
            for h in HS if stats([p for p in pts if f(p)], gain, h)))
