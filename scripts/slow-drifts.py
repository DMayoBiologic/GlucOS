#!/usr/bin/env python3
"""Slow drifts: when glucose has been easing steadily down or up inside the target range at
0.5-1 mg/dL a minute for an hour or more, does the forecast line fade the trend too early and
under-call where glucose ends up at 15, 30 and 60 minutes, compared with flat in-range runs? One
drift tweak tried leave one day out. (ForecastAccuracy.md §92)

Usage: python3 scripts/slow-drifts.py DIR
DIR holds (same export as scripts/high-plateaus.py, §91):
  readings.json  [[unix, mgdl], ...]  live readings (glucos.readings where trend > 0)
  logs.json      [[unix, kind, carbs, food], ...]  kind "meal", "rapid" or "treat" from
                 glucos.logbook, not deleted
The live accuracy log is checked with the SQL in §92, not here.

Drift, judged only from what the app has at issue time: every reading in the 60 minutes before
issue is between 70 and 180, the least-squares slope over those 60 minutes is 0.5 to 1 mg/dL a
minute (up or down), the engine's own 20-minute trend has the same sign and is within 0.5 of it,
and the 60 minutes fit a straight line well (residual SD under 6 mg/dL), so it is steady rather than
a turn or a bump. **Flat in-range run**: every reading in the 60 minutes between 70 and 180 and the
60-minute slope under 0.2 either way. Bias is signed along the drift: (actual - line) x direction,
so positive means glucose went further than the line said (an under-call). Each drift point is
compared with the mean of up to 5 flat points with the nearest start (within 20 mg/dL) and the same
"anything logged in the 2 hours before issue" flag, using the plain signed error for flat points
(their direction is meaningless) and |error| for MAE.

Replay: the engine's trend forecast every 5 minutes (20-minute least-squares slope clamped at ±4,
30-minute fade, minute midpoint integration), at the tuner's gains 0.45, 0.6 and 0.7, scored
against the reading nearest the target (within 2 minutes). It leaves out carbs and insulin, which
the live engine draws. Points with anything logged in the hour after issue are dropped (the accuracy
log's after_log rule). Range: the 10th-90th percentile of every other day's errors at that horizon.

Fix tried (forecast line only, never the insulin curve, sensitivity or carbs): on drift points with
nothing logged in the 3 hours before, the trend fades over F minutes instead of 30 (30 to 120) with
its gain scaled by k (0.5 to 1.5), picked on the other Perth days and scored on the held-out one by
30- plus 60-minute MAE over all points. Ship bar: better at 30 and 60 minutes on most held-out
days at every gain, on drift points and on all points, a stable pick, and no extra false
predicted-low crossings (line crossing 70 at 30 minutes from above with no reading under 70 in the
next 45 minutes).
"""
import bisect, datetime as dt, json, statistics as st, sys

d = sys.argv[1]
R = json.load(open(f"{d}/readings.json"))
L = json.load(open(f"{d}/logs.json"))
T = [r[0] for r in R]
MAX = 4.0
GAINS = (0.45, 0.6, 0.7)
HS = (15, 30, 60)
WIN = 60 * 60

def perth(t): return dt.datetime.fromtimestamp(t + 8 * 3600, dt.UTC)
def at(t, tol=120):
    i = bisect.bisect_left(T, t)
    c = [j for j in (i - 1, i) if 0 <= j < len(T)]
    j = min(c, key=lambda j: abs(T[j] - t))
    return R[j][1] if abs(T[j] - t) <= tol else None

def ls(t, span, need, cover):
    i, j = bisect.bisect_left(T, t - span), bisect.bisect_right(T, t)
    pts = [((T[k] - t) / 60, R[k][1]) for k in range(i, j)]
    if len(pts) < need or pts[-1][0] - pts[0][0] < cover: return None, None, pts
    mx = st.mean(p[0] for p in pts); my = st.mean(p[1] for p in pts)
    sxx = sum((p[0] - mx) ** 2 for p in pts)
    if not sxx: return None, None, pts
    s = sum((p[0] - mx) * (p[1] - my) for p in pts) / sxx
    res = st.pstdev([p[1] - (my + s * (p[0] - mx)) for p in pts])
    return s, res, pts

def slope(t):
    s, _, _ = ls(t, 1200, 3, 9)
    return None if s is None else max(-MAX, min(MAX, s))

def kind_at(t, tr):
    """'drift', 'flat' (both in range), or None, from the 60 minutes before t and the trend at t."""
    if tr is None: return None, 0
    s60, res, pts = ls(t, WIN, 30, 55)
    if s60 is None or not all(70 <= p[1] <= 180 for p in pts): return None, 0
    if abs(s60) < 0.2: return "flat", 0
    if 0.5 <= abs(s60) <= 1.0 and tr * s60 > 0 and abs(tr - s60) <= 0.5 and res < 6:
        return "drift", (1 if s60 > 0 else -1)
    return None, 0

logged = sorted(l[0] for l in L if l[1] in ("meal", "rapid", "treat"))
def any_in(xs, a, b):
    i = bisect.bisect_left(xs, a)
    return i < len(xs) and xs[i] <= b

def line(g, tr, gain, k=1.0, fade=30.0, minutes=60):
    out = {}
    for u in range(minutes):
        w = max(0, 1 - (u + 0.5) / fade)
        g += w * gain * k * tr
        out[u + 1] = g
    return out

print(f"Readings {len(R)} from {perth(T[0]):%d %b %H:%M} to {perth(T[-1]):%d %b %H:%M} Perth")

pts = []
for slot in range(T[0] - T[0] % 300 + WIN, T[-1] - 3900, 300):
    i = bisect.bisect_right(T, slot) - 1
    if i < 0 or slot - T[i] >= 300: continue
    t = T[i]
    tr = slope(t)
    if tr is None: continue
    act = {h: at(t + h * 60) for h in HS}
    if any(v is None for v in act.values()): continue
    if any_in(logged, t, t + 3600): continue
    k, sg = kind_at(t, tr)
    lo45 = min(R[x][1] for x in range(i, bisect.bisect_right(T, t + 45 * 60)))
    pts.append(dict(t=t, day=perth(t).strftime("%d"), g=R[i][1], tr=tr, act=act, k=k, sg=sg, lo45=lo45,
                    fed=any_in(logged, t - 7200, t), idle=not any_in(logged, t - 3 * 3600, t), hour=perth(t).hour))
days = sorted({p["day"] for p in pts})
ddays = sorted({p["day"] for p in pts if p["k"] == "drift"})
print(f"\nReplay: {len(pts)} clean forecasts on Perth days {days}; drift days {ddays}")
for dd in ddays:
    sub = [p for p in pts if p["day"] == dd and p["k"] == "drift"]
    print(f"  {dd} Nov: {len(sub):3d} drift points (down {sum(p['sg'] < 0 for p in sub)}, up {sum(p['sg'] > 0 for p in sub)}),"
          f" start {min(p['g'] for p in sub)}-{max(p['g'] for p in sub)}, hours {sorted({p['hour'] for p in sub})}")

def drift(p): return p["k"] == "drift"
def tweaked(p): return drift(p) and p["idle"]
def err(p, gain, h, prm=(1.0, 30.0)):
    if tweaked(p) and prm != (1.0, 30.0):
        return p["act"][h] - line(p["g"], p["tr"], gain, *prm)[h]
    return p["act"][h] - line(p["g"], p["tr"], gain)[h]
def serr(p, gain, h, prm=(1.0, 30.0)): return err(p, gain, h, prm) * (p["sg"] or 1)

def matched(sub, ctrl, key_d, key_c):
    out = []
    for p in sub:
        c = [q for q in ctrl if abs(q["g"] - p["g"]) <= 20 and q["fed"] == p["fed"]]
        if not c: continue
        c.sort(key=lambda q: abs(q["g"] - p["g"]))
        out.append((key_d(p), st.mean(key_c(q) for q in c[:5])))
    return out

def band(sub, gain, h):
    e = sorted(err(p, gain, h) for p in sub)
    return e[int(0.1 * (len(e) - 1))], e[int(0.9 * (len(e) - 1))]

flat = [p for p in pts if p["k"] == "flat"]
for gain in GAINS:
    qd = {dd: {h: band([p for p in pts if p["day"] != dd], gain, h) for h in HS} for dd in days}
    print(f"\n== Gain {gain}: as ships (bias along the drift; band = 10th-90th pct of the other days' errors) ==")
    for h in HS:
        for name, f in (("drift, all", lambda p: True), ("  falling", lambda p: p["sg"] < 0),
                        ("  rising", lambda p: p["sg"] > 0), ("  nothing logged in 3 h", lambda p: p["idle"]),
                        ("  overnight (0-6 am)", lambda p: p["hour"] < 6), ("  daytime", lambda p: p["hour"] >= 6)):
            sub = [p for p in pts if drift(p) and f(p)]
            if not sub: continue
            e = [err(p, gain, h) for p in sub]; se = [serr(p, gain, h) for p in sub]
            ins = [qd[p["day"]][h][0] <= x <= qd[p["day"]][h][1] for p, x in zip(sub, e)]
            # "short" = landed outside the range on the drift's side (further than the range allowed)
            sh = [(x > qd[p["day"]][h][1]) if p["sg"] > 0 else (x < qd[p["day"]][h][0]) for p, x in zip(sub, e)]
            mb = matched(sub, flat, lambda p: serr(p, gain, h), lambda q: err(q, gain, h))
            ma = matched(sub, flat, lambda p: abs(err(p, gain, h)), lambda q: abs(err(q, gain, h)))
            moved = st.mean((p["act"][h] - p["g"]) * p["sg"] for p in sub)
            drawn = st.mean((line(p["g"], p["tr"], gain)[h] - p["g"]) * p["sg"] for p in sub)
            carry = st.mean(abs(p["act"][h] - (p["g"] + p["tr"] * h)) for p in sub)
            print(f"  {h:2d}m {name:24s} n={len(sub):3d} days={len({p['day'] for p in sub})} mae {st.mean(abs(x) for x in e):5.1f}"
                  f" no change {st.mean(abs(p['act'][h]-p['g']) for p in sub):5.1f} full trend {carry:5.1f}"
                  f" bias {st.mean(se):+6.1f} moved {moved:+6.1f} drawn {drawn:+5.1f}"
                  f" inside {100*st.mean(ins):3.0f}% short {100*st.mean(sh):3.0f}%"
                  + (f" | matched n={len(mb)} bias {st.mean(x[0] for x in mb):+6.1f} vs flat {st.mean(x[1] for x in mb):+6.1f}"
                     f" mae {st.mean(x[0] for x in ma):5.1f} vs {st.mean(x[1] for x in ma):5.1f}" if mb else ""))
        e = [err(p, gain, h) for p in flat]
        ins = [qd[p["day"]][h][0] <= x <= qd[p["day"]][h][1] for p, x in zip(flat, e)]
        print(f"  {h:2d}m {'flat in-range runs':24s} n={len(flat):3d} days={len({p['day'] for p in flat})} mae {st.mean(abs(x) for x in e):5.1f}"
              f" bias {st.mean(e):+6.1f} inside {100*st.mean(ins):3.0f}%")
    if gain == 0.45:
        print("  per day, drift points: n, bias along drift 15/30/60")
        for dd in ddays:
            sub = [p for p in pts if p["day"] == dd and drift(p)]
            print(f"    {dd} Nov n={len(sub):3d} " + " ".join(f"{st.mean(serr(p, gain, h) for p in sub):+6.1f}" for h in HS)
                  + f" start {st.mean(p['g'] for p in sub):.0f} trend {st.mean(p['tr'] for p in sub):+.2f}")

GRID = [(k, f) for k in (0.5, 0.75, 1.0, 1.25, 1.5) for f in (30.0, 45.0, 60.0, 90.0, 120.0)]
def mae(sub, gain, prm, hs=(30, 60)):
    return {h: st.mean(abs(err(p, gain, h, prm)) for p in sub) for h in hs}
def lows(sub, gain, prm, level=70):
    w = r = 0
    for p in sub:
        f = line(p["g"], p["tr"], gain, *prm)[30] if tweaked(p) else line(p["g"], p["tr"], gain)[30]
        if p["g"] > level >= f:
            w += 1; r += p["lo45"] < level
    return w, r

BASE = (1.0, 30.0)
for gain in GAINS:
    print(f"\n== Gain {gain}: drift gain k / fade F min (nothing logged in 3 h), leave one Perth day out"
          f" (scored on days with 3+ such points) ==")
    wins = {30: 0, 60: 0}; dwins = {30: 0, 60: 0}; picks = []; n = 0
    for dd in ddays:
        train = [p for p in pts if p["day"] != dd]; test = [p for p in pts if p["day"] == dd]
        pt = [p for p in test if tweaked(p)]
        if len(pt) < 3: continue
        n += 1
        best = min(GRID, key=lambda prm: sum(mae(train, gain, prm).values())); picks.append(best)
        a0, a1 = mae(test, gain, BASE), mae(test, gain, best)
        r0, r1 = mae(pt, gain, BASE), mae(pt, gain, best)
        for h in (30, 60):
            wins[h] += a1[h] < a0[h] - 1e-9; dwins[h] += r1[h] < r0[h] - 1e-9
        print(f"  {dd} picks k={best[0]} F={best[1]:.0f}: all n={len(test)} 30m {a0[30]:.2f}→{a1[30]:.2f} 60m {a0[60]:.2f}→{a1[60]:.2f}"
              f" | drift n={len(pt)} 30m {r0[30]:.1f}→{r1[30]:.1f} 60m {r0[60]:.1f}→{r1[60]:.1f}")
    print(f"  better held out, all points: 30m {wins[30]}/{n}, 60m {wins[60]}/{n}; drift points: 30m {dwins[30]}/{n}, 60m {dwins[60]}/{n}")
    if not picks: continue
    prm = max(set(picks), key=picks.count)
    a0, a1 = mae(pts, gain, BASE), mae(pts, gain, prm)
    l0, l1 = lows(pts, gain, BASE), lows(pts, gain, prm)
    print(f"  most-picked k={prm[0]} F={prm[1]:.0f}: all-point MAE 30m {a0[30]:.2f}→{a1[30]:.2f} 60m {a0[60]:.2f}→{a1[60]:.2f};"
          f" predicted-low crossings {l0[0]} ({l0[1]} came true) → {l1[0]} ({l1[1]})")
    print("  in-sample drift-point MAE 30/60 over the grid (k down, F across):")
    dp = [p for p in pts if tweaked(p)]
    for k in (0.5, 0.75, 1.0, 1.25, 1.5):
        print(f"    k={k:<4} " + " ".join(f"F{f:.0f} {mae(dp, gain, (k, f))[30]:5.1f}/{mae(dp, gain, (k, f))[60]:5.1f}"
                                         for f in (30.0, 45.0, 60.0, 90.0, 120.0)))
