#!/usr/bin/env python3
"""Rebound highs after lows: in the 2 hours after a reading climbs back out of <70 (treated or
not), does the forecast run low and miss the rebound? Scored at 15/30/60 minutes against matched
starts that weren't near a low, and one rebound tweak tried leave one day out.
(ForecastAccuracy.md §90)

Usage: python3 scripts/rebound-highs.py DIR
DIR holds (same export as scripts/late-meal-rises.py):
  readings.json  [[unix, mgdl], ...]  live readings (glucos.readings where trend > 0)
  logs.json      [[unix, kind, carbs, food], ...]  kind "meal", "rapid" or "treat" (a meal logged
                 beside a Hypo treatment tag) from glucos.logbook, not deleted
  points.json    (optional) the accuracy log's clean shown 15/30/60-minute points:
                 [[unix, device, basis, minutes, line, lower, upper, actual, start, trend], ...]

Lows: a run of readings under 70; it **ends** at the first reading at 70 or more, and must stay
there 10 minutes (a dip back under 70 inside 10 minutes joins the same low). An episode is
**treated** if a meal or treatment was logged from 30 minutes before the low started to its end
plus 20 minutes. Rebound window: forecasts issued 0-120 minutes after the end. A **rebound high**
is a reading over 180 inside that window.

Matched starts: every other forecast issued at least 3 hours after any reading under 70, matched
to each rebound forecast by start glucose (±15 mg/dL), trend (±0.5 mg/dL a minute) and whether
anything was logged in the 2 hours before issue. Each rebound point is compared with the mean of
up to 5 nearest matches, so the two groups have the same start and trend mix.

Replay: the engine's trend forecast every 5 minutes (20-minute least-squares slope clamped at ±4,
30-minute fade), at gains 0.45, 0.6 and 0.7, scored against the reading nearest the target (within
2 minutes). It leaves out carbs and insulin, which the live engine draws (including §37's fast
curve for treatments), so the live accuracy log is reported first. Points with anything logged in
the hour after issue are dropped (the accuracy log's after_log rule), except in the "including
treatments after issue" line.

Fix tried (forecast only, never the carb curve, carb ratio or insulin on board): in the first hour
of the rebound window (where the line runs low), on points with trend ≥ 0, the gain is scaled by k in the first 30 minutes and the trend
carries on past the fade at share b. k and b are picked on the other Perth days and scored on the
held-out day (leave one day out over days with rebound points), by 30 + 60-minute MAE over all
points. Ship bar: better at 30 and 60 minutes on most held-out days at every gain, over rebound
points and all points, and no extra false predicted-high crossings.
"""
import bisect, datetime as dt, json, os, statistics as st, sys
from collections import defaultdict

d = sys.argv[1]
R = json.load(open(f"{d}/readings.json"))
L = json.load(open(f"{d}/logs.json"))
T = [r[0] for r in R]
FADE, MAX = 30.0, 4.0
GAINS = (0.45, 0.6, 0.7)
HS = (15, 30, 60)
WINDOW = 7200

def perth(t): return dt.datetime.fromtimestamp(t + 8 * 3600, dt.UTC)
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

logged = sorted(l[0] for l in L if l[1] in ("meal", "rapid", "treat"))
food = sorted(l[0] for l in L if l[1] in ("meal", "treat"))
def any_in(xs, a, b):
    i = bisect.bisect_left(xs, a)
    return i < len(xs) and xs[i] <= b

# Low episodes
eps, start, k = [], None, 0
while k < len(R):
    if R[k][1] < 70 and start is None: start = k
    if start is not None and R[k][1] >= 70:
        j = k
        while j < len(R) and T[j] - T[k] < 600 and R[j][1] >= 70: j += 1
        if j < len(R) and T[j] - T[k] < 600 and T[j] - T[j - 1] < 600:   # dipped back under 70
            k = j; continue
        nadir = min(R[x][1] for x in range(start, k))
        treated = any_in(food, T[start] - 1800, T[k] + 1200)
        win = [R[x][1] for x in range(k, bisect.bisect_right(T, T[k] + WINDOW))]
        eps.append(dict(s=T[start], e=T[k], nadir=nadir, treated=treated, peak=max(win), high=max(win) > 180,
                        cover=len(win)))
        start = None
    k += 1
lows = [T[x] for x in range(len(R)) if R[x][1] < 70]
def since_low(t):
    i = bisect.bisect_right(lows, t) - 1
    return t - lows[i] if i >= 0 else 1e12
def rebound_of(t):
    for e in eps:
        if 0 <= t - e["e"] <= WINDOW: return e
    return None

print(f"Readings {len(R)} from {perth(T[0]):%d %b %H:%M} to {perth(T[-1]):%d %b %H:%M} Perth")
print(f"Low episodes (<70, ended at a reading ≥70 held 10 min): {len(eps)}")
for e in eps:
    print(f"  {perth(e['s']):%d %b %H:%M}-{perth(e['e']):%H:%M} nadir {e['nadir']:3d} {'treated  ' if e['treated'] else 'untreated'}"
          f" peak 2 h after {e['peak']:3d}{'  REBOUND HIGH' if e['high'] else ''}")
print(f"  treated {sum(e['treated'] for e in eps)}, rebound highs {sum(e['high'] for e in eps)} "
      f"(treated {sum(e['high'] and e['treated'] for e in eps)}, untreated {sum(e['high'] and not e['treated'] for e in eps)})")

def matched(sub, ctrl, key):
    """For each point in sub, mean of key over up to 5 nearest controls."""
    out = []
    for p in sub:
        c = [q for q in ctrl if q["m"] == p["m"] and abs(q["s"] - p["s"]) <= 15 and abs(q["tr"] - p["tr"]) <= 0.5
             and q["fed"] == p["fed"]]
        if not c: continue
        c.sort(key=lambda q: abs(q["s"] - p["s"]) / 15 + abs(q["tr"] - p["tr"]) / 0.5)
        out.append((key(p), st.mean(key(q) for q in c[:5])))
    return out

# Live accuracy log
if os.path.exists(f"{d}/points.json"):
    P = json.load(open(f"{d}/points.json"))
    live = []
    for t, dev, basis, m, f, lo, hi, a, s, tr in P:
        if f is None or a is None or s is None or tr is None: continue
        e = rebound_of(t)
        grp = ("rebound" if e else "control" if since_low(t) >= 3 * 3600 else "near")
        live.append(dict(t=t, m=m, f=f, lo=lo, hi=hi, a=a, s=s, tr=tr, grp=grp, ep=e["e"] if e else None,
                         treated=bool(e and e["treated"]), high=bool(e and e["high"]),
                         fed=any_in(logged, t - 7200, t)))
    print("\nLive accuracy log, clean shown points (bias = actual - line; matched = same start/trend/logged mix):")
    for m in HS:
        ctrl = [p for p in live if p["grp"] == "control" and p["m"] == m]
        for name, f in (("rebound window, all", lambda p: True), ("  treated lows", lambda p: p["treated"]),
                        ("  untreated lows", lambda p: not p["treated"]), ("  ended in a rebound high", lambda p: p["high"]),
                        ("  rising (trend ≥ 0.5)", lambda p: p["tr"] >= 0.5)):
            sub = [p for p in live if p["grp"] == "rebound" and p["m"] == m and f(p)]
            if not sub: continue
            mb = matched(sub, ctrl, lambda p: p["a"] - p["f"])
            mi = matched(sub, ctrl, lambda p: (p["lo"] is not None and p["lo"] <= p["a"] <= p["hi"]))
            ins = [p["lo"] is not None and p["lo"] <= p["a"] <= p["hi"] for p in sub]
            above = [p["hi"] is not None and p["a"] > p["hi"] for p in sub]
            print(f"  {m:2d}m {name:26s} n={len(sub):3d} lows={len({p['ep'] for p in sub})} mae {st.mean(abs(p['a']-p['f']) for p in sub):5.1f}"
                  f" no change {st.mean(abs(p['a']-p['s']) for p in sub):5.1f} bias {st.mean(p['a']-p['f'] for p in sub):+6.1f}"
                  f" inside {100*st.mean(ins):3.0f}% above {100*st.mean(above):3.0f}%"
                  + (f" | matched n={len(mb)} bias {st.mean(x[0] for x in mb):+6.1f} vs {st.mean(x[1] for x in mb):+6.1f},"
                     f" inside {100*st.mean(x[0] for x in mi):3.0f}% vs {100*st.mean(x[1] for x in mi):3.0f}%" if mb else ""))
        print(f"  {m:2d}m {'all other (≥3 h from a low)':26s} n={len(ctrl):3d} bias {st.mean(p['a']-p['f'] for p in ctrl):+6.1f}"
              f" inside {100*st.mean(p['lo'] is not None and p['lo'] <= p['a'] <= p['hi'] for p in ctrl):3.0f}%")

def line(g, tr, gain, k=1.0, b=0.0, minutes=60):
    out = {}
    for u in range(minutes):
        w = max(0, 1 - (u + 0.5) / FADE)
        g += w * gain * k * tr + (1 - w) * b * tr
        out[u + 1] = g
    return out

# Replay
pts, pts_all = [], []
for slot in range(T[0] - T[0] % 300 + 1500, T[-1] - 3900, 300):
    i = bisect.bisect_right(T, slot) - 1
    if i < 0 or slot - T[i] >= 300: continue
    t = T[i]
    tr = slope(t)
    if tr is None: continue
    act = {h: at(t + h * 60) for h in HS}
    if any(v is None for v in act.values()): continue
    e = rebound_of(t)
    grp = "rebound" if e else ("control" if since_low(t) >= 3 * 3600 else "near")
    pk = max(R[k][1] for k in range(i, bisect.bisect_right(T, t + 45 * 60)))
    p = dict(t=t, day=perth(t).strftime("%d"), g=R[i][1], s=R[i][1], tr=tr, act=act, grp=grp,
             ep=e["e"] if e else None, treated=bool(e and e["treated"]), high=bool(e and e["high"]),
             mins=(t - e["e"]) / 60 if e else None, peak45=pk, fed=any_in(logged, t - 7200, t))
    pts_all.append(p)
    if not any_in(logged, t, t + 3600): pts.append(p)
days = sorted({p["day"] for p in pts})
rdays = sorted({p["day"] for p in pts if p["grp"] == "rebound"})
print(f"\nReplay: {len(pts)} clean forecasts on Perth days {days}; rebound days {rdays}")

def tweaked(p): return p["grp"] == "rebound" and p["mins"] < 60 and p["tr"] >= 0

def err(p, gain, h, prm=(1.0, 0.0)):
    k, b = prm
    if tweaked(p) and (k != 1 or b):
        return p["act"][h] - line(p["g"], p["tr"], gain, k, b)[h]
    return p["act"][h] - line(p["g"], p["tr"], gain)[h]

def quantiles(sub, gain):
    q = {}
    for h in HS:
        e = sorted(err(p, gain, h) for p in sub)
        q[h] = (e[int(0.1 * (len(e) - 1))], e[int(0.9 * (len(e) - 1))])
    return q

for gain in GAINS:
    qd = {dd: quantiles([p for p in pts if p["day"] != dd], gain) for dd in days}
    print(f"\n== Gain {gain}: as ships (band = 10th-90th pct of the other days' errors) ==")
    for h in HS:
        ctrl = [dict(p, m=h) for p in pts if p["grp"] == "control"]
        for name, src, f in (("rebound window, all", pts, lambda p: True),
                             ("  first hour after the low", pts, lambda p: p["mins"] < 60),
                             ("  second hour", pts, lambda p: p["mins"] >= 60),
                             ("  treated lows", pts, lambda p: p["treated"]),
                             ("  untreated lows", pts, lambda p: not p["treated"]),
                             ("  ended in a rebound high", pts, lambda p: p["high"]),
                             ("  rising (trend ≥ 0.5)", pts, lambda p: p["tr"] >= 0.5),
                             ("  incl. treatments after issue", pts_all, lambda p: True)):
            sub = [dict(p, m=h) for p in src if p["grp"] == "rebound" and f(p)]
            if not sub: continue
            e = [err(p, gain, h) for p in sub]
            ins = [qd[p["day"]][h][0] <= x <= qd[p["day"]][h][1] for p, x in zip(sub, e)]
            ab = [x > qd[p["day"]][h][1] for p, x in zip(sub, e)]
            mb = matched(sub, ctrl, lambda p: err(p, gain, h))
            ma = matched(sub, ctrl, lambda p: abs(err(p, gain, h)))
            print(f"  {h:2d}m {name:30s} n={len(sub):3d} lows={len({p['ep'] for p in sub})} mae {st.mean(abs(x) for x in e):5.1f}"
                  f" no change {st.mean(abs(p['act'][h]-p['g']) for p in sub):5.1f} bias {st.mean(e):+6.1f}"
                  f" inside {100*st.mean(ins):3.0f}% above {100*st.mean(ab):3.0f}%"
                  + (f" | matched n={len(mb)} bias {st.mean(x[0] for x in mb):+6.1f} vs {st.mean(x[1] for x in mb):+6.1f}"
                     f" mae {st.mean(x[0] for x in ma):5.1f} vs {st.mean(x[1] for x in ma):5.1f}" if mb else ""))
        c = [err(p, gain, h) for p in ctrl]
        print(f"  {h:2d}m {'all other (≥3 h from a low)':30s} n={len(c):3d} mae {st.mean(abs(x) for x in c):5.1f} bias {st.mean(c):+6.1f}")
    if gain == 0.45:
        print("  per low, rebound points: n, bias 15/30/60")
        for ep in sorted({p["ep"] for p in pts if p["grp"] == "rebound"}):
            sub = [p for p in pts if p["ep"] == ep]
            print(f"    low ending {perth(ep):%d %b %H:%M} n={len(sub):2d} "
                  + " ".join(f"{st.mean(err(p, gain, h) for p in sub):+6.1f}" for h in HS)
                  + f" start {st.mean(p['g'] for p in sub):.0f} trend {st.mean(p['tr'] for p in sub):+.2f}")

GRID = [(k, b) for k in (0.5, 0.75, 1.0, 1.25, 1.5, 2.0) for b in (0.0, 0.1, 0.2, 0.35, 0.5)]
def mae(sub, gain, prm, hs=(30, 60)):
    return {h: st.mean(abs(err(p, gain, h, prm)) for p in sub) for h in hs}
def highs(sub, gain, prm, level=250):
    w = r = 0
    for p in sub:
        k, b = prm
        f = line(p["g"], p["tr"], gain, k, b)[30] if tweaked(p) else line(p["g"], p["tr"], gain)[30]
        if p["g"] < level <= f:
            w += 1; r += p["peak45"] >= level
    return w, r

for gain in GAINS:
    print(f"\n== Gain {gain}: rebound trend scale k / carry-on b, leave one Perth day out ==")
    wins = {30: 0, 60: 0}; rwins = {30: 0, 60: 0}; picks = []; n = 0
    for dd in rdays:
        train = [p for p in pts if p["day"] != dd]; test = [p for p in pts if p["day"] == dd]
        rt = [p for p in test if tweaked(p)]
        if not rt: continue
        n += 1
        best = min(GRID, key=lambda prm: sum(mae(train, gain, prm).values())); picks.append(best)
        a0, a1 = mae(test, gain, (1.0, 0.0)), mae(test, gain, best)
        r0, r1 = mae(rt, gain, (1.0, 0.0)), mae(rt, gain, best)
        for h in (30, 60):
            wins[h] += a1[h] < a0[h] - 1e-9; rwins[h] += r1[h] < r0[h] - 1e-9
        print(f"  {dd} picks k={best[0]} b={best[1]}: all n={len(test)} 30m {a0[30]:.2f}→{a1[30]:.2f} 60m {a0[60]:.2f}→{a1[60]:.2f}"
              f" | rebound first hour n={len(rt)} 30m {r0[30]:.1f}→{r1[30]:.1f} 60m {r0[60]:.1f}→{r1[60]:.1f}")
    print(f"  better held out, all points: 30m {wins[30]}/{n}, 60m {wins[60]}/{n}; rebound points: 30m {rwins[30]}/{n}, 60m {rwins[60]}/{n}")
    prm = max(set(picks), key=picks.count)
    a0, a1 = mae(pts, gain, (1.0, 0.0)), mae(pts, gain, prm)
    h0, h1 = highs(pts, gain, (1.0, 0.0)), highs(pts, gain, prm)
    print(f"  most-picked k={prm[0]} b={prm[1]}: all-point MAE 30m {a0[30]:.2f}→{a1[30]:.2f} 60m {a0[60]:.2f}→{a1[60]:.2f};"
          f" predicted-high crossings {h0[0]} ({h0[1]} came true) → {h1[0]} ({h1[1]})")
