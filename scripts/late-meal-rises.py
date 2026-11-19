#!/usr/bin/env python3
"""Does the forecast miss the late rise 3-5 hours after a meal, and does fat or protein in the
logged food matter? Would a late-rise momentum carry-on help on days it wasn't fitted on?
(ForecastAccuracy.md §89)

Usage: python3 scripts/late-meal-rises.py DIR
DIR holds:
  readings.json  [[unix, mgdl], ...]  live readings (glucos.readings where trend > 0)
  logs.json      [[unix, kind, carbs, food], ...]  kind "meal", "rapid" or "treat" (a meal logged
                 beside a Hypo treatment tag) from glucos.logbook, not deleted
  points.json    (optional) the accuracy log's clean shown 15/30/60-minute points:
                 [[unix, device, basis, minutes, line, lower, upper, actual, start, trend], ...]

Meals: two meal entries within 15 minutes with the same carbs are one meal (a double log). Hypo
treatments are never anchors, but they count as "something logged".

A forecast belongs to a meal ("late window") when it is issued 3-5 hours after the meal and
nothing (meal, rapid dose, treatment) was logged from 15 minutes after the meal up to issue, so the
meal's own dose is allowed. Judged only from what the app has at issue time. A **late rise** is a
late-window forecast with an engine trend of +0.5 mg/dL a minute or more. Points with anything
logged in the hour after issue are dropped from every report, fit and score (the accuracy log's
after_log rule). A late rise whose readings in the hour before issue went under 70 is a rebound
from a low (likely an unlogged treatment) and is reported on its own, not as a late meal rise.

Fat and protein: the app stores only carbs (the food list has carbs per 100 g), so "fat/protein"
is judged from the food's name: burgers, eggs, meat, pastry, cheese, fried food (FP below).

Replay: the engine's trend forecast every 5 minutes (20-minute least-squares slope clamped at
±4, 30-minute fade, minute midpoint integration), at the tuner's gains 0.45, 0.6 and 0.7, scored
at 15, 30 and 60 minutes against the reading nearest the target (within 2 minutes). By 3 hours the
engine's carb curve (10-minute delay + 3 hours) has finished, so the live engine draws trend plus
the insulin tail here; the replay leaves the insulin tail out (as §65 and §88 do), so its line sits
a little higher than the app's. The accuracy log's live points are reported first for that reason.

Fix tried (forecast only, never the carb curve, carb ratio or insulin on board): on late rises
only, the trend carries on past the 30-minute fade at share b (rate += (1 - w) * b * trend) and
the gain is scaled by k in the first 30 minutes. Variant "fat/protein": only when the anchor meal
is FP. k and b are picked on the other Perth days and scored on the held-out one (leave one day
out, over the days that have late rises), by the sum of 30- and 60-minute MAE over all points.
Ship bar: better at 30 and 60 minutes on most held-out days at every gain, on the late rises and
over all points, and no extra false predicted-high crossings.
"""
import bisect, datetime as dt, json, os, statistics as st, sys
from collections import defaultdict

d = sys.argv[1]
R = json.load(open(f"{d}/readings.json"))
L = json.load(open(f"{d}/logs.json"))
T = [r[0] for r in R]
FADE, MAX, RISE = 30.0, 4.0, 0.5
GAINS = (0.45, 0.6, 0.7)
HS = (15, 30, 60)
FP = ("burger", "pounder", "brekkie", "burrito", "egg", "sausage", "pie", "meat", "cheese", "fried",
      "chips", "hash", "croissant", "fish", "bean curd")

def perth(t): return dt.datetime.fromtimestamp(t + 8 * 3600, dt.UTC)
def fp(food): return any(k in food.lower() for k in FP)

def at(t, tol=120):
    i = bisect.bisect_left(T, t)
    c = [j for j in (i - 1, i) if 0 <= j < len(T)]
    j = min(c, key=lambda j: abs(T[j] - t))
    return R[j][1] if abs(T[j] - t) <= tol else None

def slope(t):
    i, j = bisect.bisect_left(T, t - 1200), bisect.bisect_right(T, t)
    pts = [((T[k] - t) / 60, R[k][1]) for k in range(i, j)]
    if len(pts) < 3 or pts[-1][0] - pts[0][0] < 9: return None
    mx = st.mean(p[0] for p in pts); my = st.mean(p[1] for p in pts)
    sxx = sum((p[0] - mx) ** 2 for p in pts)
    return max(-MAX, min(MAX, sum((p[0] - mx) * (p[1] - my) for p in pts) / sxx)) if sxx else None

meals = []
for l in sorted(L):
    if l[1] != "meal": continue
    if meals and l[0] - meals[-1][0] < 900 and abs(l[2] - meals[-1][2]) < 1: continue
    meals.append(l)
logged = sorted(l[0] for l in L if l[1] in ("meal", "rapid", "treat"))

def logged_in(a, b):
    i = bisect.bisect_right(logged, a)
    return i < len(logged) and logged[i] <= b

def anchor(t):
    c = [m for m in meals if 3 * 3600 <= t - m[0] <= 5 * 3600]
    if not c: return None
    m = c[-1]
    if any(m[0] < m2[0] < t for m2 in meals) or logged_in(m[0] + 900, t): return None
    return m

def line(g, tr, gain, k=1.0, b=0.0, minutes=60):
    out = {}
    for u in range(minutes):
        w = max(0, 1 - (u + 0.5) / FADE)
        g += w * gain * k * tr + (1 - w) * b * tr
        out[u + 1] = g
    return out

# Meals and their late rises
print("Meals with nothing logged from 15 min after to 6 h after (late rise = biggest trough-to-peak climb inside 3-5 h):")
for m in meals:
    t = m[0]
    if t < T[0] + 1200 or logged_in(t + 900, t + 6 * 3600): continue
    i, j = bisect.bisect_left(T, t + 3 * 3600), bisect.bisect_right(T, t + 5 * 3600)
    best, lo = (0, None, None), None
    for k in range(i, j):
        if lo is None or R[k][1] < R[lo][1]: lo = k
        if R[k][1] - R[lo][1] > best[0]: best = (R[k][1] - R[lo][1], lo, k)
    first = max((R[k][1] for k in range(bisect.bisect_left(T, t), i)), default=0)
    rise, a, b = best
    kind = ("rebound from a low" if a is not None and R[a][1] < 70 else
            "second rise" if a is not None and first - R[a][1] >= 20 else "continued climb")
    print(f"  {perth(t).strftime('%d Nov %H:%M')} {m[2]:5.1f} g {'FP ' if fp(m[3]) else '   '}{m[3][:40]:40s} "
          f"first-3h peak {first}; late {rise:+d} ({R[a][1]}→{R[b][1]}, {(T[a]-t)/3600:.1f}-{(T[b]-t)/3600:.1f} h) {kind}")

# Live accuracy log
if os.path.exists(f"{d}/points.json"):
    P = json.load(open(f"{d}/points.json"))
    g = defaultdict(list)
    for t, dev, basis, m, f, lo, hi, a, s, tr in P:
        an = anchor(t)
        if not an: continue
        reb = any(R[k][1] < 70 for k in range(bisect.bisect_left(T, t - 3600), bisect.bisect_right(T, t)))
        grp = "rebound" if reb else ("late rise" if tr is not None and tr >= RISE else "late, not rising")
        g[(grp, m)].append((a - f, a - s, lo is not None and lo <= a <= hi, a < (lo or -1), an[0], fp(an[3])))
    print("\nLive accuracy log, clean shown points 3-5 h after a meal (bias = actual - line):")
    for k in sorted(g):
        v = g[k]
        print(f"  {k[0]:17s} {k[1]:2d}m n={len(v):3d} meals={len({x[4] for x in v})} FP pts={sum(x[5] for x in v):3d} "
              f"mae {st.mean(abs(x[0]) for x in v):5.1f} no change {st.mean(abs(x[1]) for x in v):5.1f} "
              f"bias {st.mean(x[0] for x in v):+6.1f} inside {100*st.mean(x[2] for x in v):3.0f}% below {100*st.mean(x[3] for x in v):3.0f}%")

# Replay
pts = []
for slot in range(T[0] - T[0] % 300 + 1500, T[-1] - 3900, 300):
    i = bisect.bisect_right(T, slot) - 1
    if i < 0 or slot - T[i] >= 300: continue
    t = T[i]
    tr = slope(t)
    if tr is None: continue
    act = {h: at(t + h * 60) for h in HS}
    if any(v is None for v in act.values()) or logged_in(t, t + 3600): continue
    an = anchor(t)
    reb = any(R[k][1] < 70 for k in range(bisect.bisect_left(T, t - 3600), i + 1))
    hr = perth(t).hour
    unlogged5 = not logged_in(t - 5 * 3600, t)
    if an and tr >= RISE: grp = "rebound" if reb else "late"
    elif an: grp = "late-flat"
    elif unlogged5 and tr >= RISE and 9 <= hr < 22 and not reb: grp = "day"
    else: grp = "other"
    pk = max(R[k][1] for k in range(i, bisect.bisect_right(T, t + 45 * 60)))
    pts.append(dict(t=t, day=perth(t).strftime("%d"), g=R[i][1], tr=tr, act=act, grp=grp, peak45=pk,
                    meal=an[0] if an else None, fp=bool(an and fp(an[3]))))
days = sorted({p["day"] for p in pts})
late_days = sorted({p["day"] for p in pts if p["grp"] == "late"})
print(f"\nReplay: {len(pts)} clean forecasts on Perth days {days}; late-rise days {late_days}")

def quantiles(sub, gain):
    q = {}
    for h in HS:
        e = sorted(p["act"][h] - line(p["g"], p["tr"], gain)[h] for p in sub)
        q[h] = (e[int(0.1 * (len(e) - 1))], e[int(0.9 * (len(e) - 1))])
    return q

SCOPES = {"all late rises": lambda p: p["grp"] == "late", "fat/protein late rises": lambda p: p["grp"] == "late" and p["fp"]}
def fc(p, gain, prm, scope=None):
    k, b = prm
    if scope and scope(p) and (k != 1 or b): return line(p["g"], p["tr"], gain, k, b)
    return line(p["g"], p["tr"], gain)

def report(sub, gain, qd, prm=(1.0, 0.0), scope=None):
    out = {}
    for h in HS:
        err = [p["act"][h] - fc(p, gain, prm, scope)[h] for p in sub]
        lo = [qd[p["day"]][h][0] for p in sub]; hi = [qd[p["day"]][h][1] for p in sub]
        out[h] = dict(mae=st.mean(abs(e) for e in err), bias=st.mean(err),
                      ins=100 * st.mean(l <= e <= u for e, l, u in zip(err, lo, hi)),
                      below=100 * st.mean(e < l for e, l in zip(err, lo)),
                      above=100 * st.mean(e > u for e, u in zip(err, hi)),
                      nc=st.mean(abs(p["act"][h] - p["g"]) for p in sub))
    return out

def delivered(sub, gain, h=30):
    return st.median((p["act"][h] - p["g"]) / (line(p["g"], p["tr"], gain)[h] - p["g"]) for p in sub)

for gain in GAINS:
    qd = {dd: quantiles([p for p in pts if p["day"] != dd], gain) for dd in days}
    print(f"\n== Gain {gain}: as ships (band = 10th-90th pct of the other days' errors) ==")
    for name, f in (("late rise, all", lambda p: p["grp"] == "late"),
                    ("late rise, fat/protein", lambda p: p["grp"] == "late" and p["fp"]),
                    ("late rise, other food", lambda p: p["grp"] == "late" and not p["fp"]),
                    ("late, not rising", lambda p: p["grp"] == "late-flat"),
                    ("rebound from a low", lambda p: p["grp"] == "rebound"),
                    ("day rise, nothing logged 5 h", lambda p: p["grp"] == "day"),
                    ("everything", lambda p: True)):
        sub = [p for p in pts if f(p)]
        if not sub: continue
        r = report(sub, gain, qd)
        print(f"  {name:30s} n={len(sub):4d} meals={len({p['meal'] for p in sub if p['meal']})} days={len({p['day'] for p in sub})}"
              f" trend {st.mean(p['tr'] for p in sub):.2f} start {st.mean(p['g'] for p in sub):.0f}"
              + (f" delivered {delivered(sub, gain):.2f} of drawn 30m rise" if "rise" in name else ""))
        for h in HS:
            x = r[h]
            print(f"      {h:2d}m mae {x['mae']:5.1f} (no change {x['nc']:5.1f}) bias {x['bias']:+6.1f} "
                  f"inside {x['ins']:3.0f}% below {x['below']:3.0f}% above {x['above']:3.0f}%")
    if gain == 0.45:
        print("  per meal, late rises: n, bias 15/30/60, inside 30/60")
        for mt in sorted({p["meal"] for p in pts if p["grp"] == "late"}):
            sub = [p for p in pts if p["grp"] == "late" and p["meal"] == mt]
            r = report(sub, gain, qd)
            print(f"    {perth(mt).strftime('%d Nov %H:%M')} {'FP' if sub[0]['fp'] else '  '} n={len(sub):3d} "
                  f"{r[15]['bias']:+6.1f} {r[30]['bias']:+6.1f} {r[60]['bias']:+6.1f}  {r[30]['ins']:3.0f}% {r[60]['ins']:3.0f}% "
                  f"start {st.mean(p['g'] for p in sub):.0f} trend {st.mean(p['tr'] for p in sub):.2f}")

GRID = [(k, b) for k in (0.5, 0.75, 1.0, 1.25, 1.5) for b in (0.0, 0.1, 0.2, 0.35, 0.5)]
def mae(sub, gain, prm, scope, hs=(30, 60)):
    return {h: st.mean(abs(p["act"][h] - fc(p, gain, prm, scope)[h]) for p in sub) for h in hs}

def highs(sub, gain, prm, scope, level=250):
    warned = real = 0
    for p in sub:
        if p["g"] < level <= fc(p, gain, prm, scope)[30]:
            warned += 1; real += p["peak45"] >= level
    return warned, real

for sname, scope in SCOPES.items():
    for gain in GAINS:
        print(f"\n== Gain {gain}: trend scale k / carry-on b on {sname}, leave one Perth day out ==")
        wins = {30: 0, 60: 0}; lwins = {30: 0, 60: 0}; picks = []; tdays = 0
        for dd in late_days:
            train = [p for p in pts if p["day"] != dd]
            test = [p for p in pts if p["day"] == dd]
            lt = [p for p in test if scope(p)]
            if not lt: continue
            tdays += 1
            best = min(GRID, key=lambda prm: sum(mae(train, gain, prm, scope).values())); picks.append(best)
            b0, b1 = mae(test, gain, (1.0, 0.0), scope), mae(test, gain, best, scope)
            l0, l1 = mae(lt, gain, (1.0, 0.0), scope), mae(lt, gain, best, scope)
            for h in (30, 60):
                wins[h] += b1[h] < b0[h] - 1e-9; lwins[h] += l1[h] < l0[h] - 1e-9
            print(f"  {dd} Nov picks k={best[0]} b={best[1]}: all n={len(test)} 30m {b0[30]:.2f}→{b1[30]:.2f} 60m {b0[60]:.2f}→{b1[60]:.2f}"
                  f" | late rises n={len(lt)} 30m {l0[30]:.1f}→{l1[30]:.1f} 60m {l0[60]:.1f}→{l1[60]:.1f}")
        print(f"  better held out, all points: 30m {wins[30]}/{tdays}, 60m {wins[60]}/{tdays}; late rises: 30m {lwins[30]}/{tdays}, 60m {lwins[60]}/{tdays}")
        prm = max(set(picks), key=picks.count)
        a0, a1 = mae(pts, gain, (1.0, 0.0), scope), mae(pts, gain, prm, scope)
        h0, h1 = highs(pts, gain, (1.0, 0.0), scope), highs(pts, gain, prm, scope)
        print(f"  most-picked k={prm[0]} b={prm[1]}: all-point MAE 30m {a0[30]:.2f}→{a1[30]:.2f} 60m {a0[60]:.2f}→{a1[60]:.2f}; "
              f"predicted-high crossings {h0[0]} ({h0[1]} came true) → {h1[0]} ({h1[1]})")
