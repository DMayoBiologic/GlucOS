#!/usr/bin/env python3
"""High plateaus: when glucose has sat above 180 mg/dL for 45 minutes or more with a flat trend,
does the forecast line drift up or down off the readings, and is the likely range too wide or too
narrow at 15, 30 and 60 minutes, compared with flat runs inside the target range? One plateau
tweak tried leave one day out. (ForecastAccuracy.md §91)

Usage: python3 scripts/high-plateaus.py DIR
DIR holds (same export as scripts/rebound-highs.py, §90):
  readings.json  [[unix, mgdl], ...]  live readings (glucos.readings where trend > 0)
  logs.json      [[unix, kind, carbs, food], ...]  kind "meal", "rapid" or "treat" from
                 glucos.logbook, not deleted
  points.json    (optional) the accuracy log's clean shown 15/30/60-minute points:
                 [[unix, device, basis, minutes, line, lower, upper, actual, start, trend], ...]

Plateau, judged only from what the app has at issue time: every reading in the 45 minutes before
issue is over 180, the least-squares slope over those 45 minutes is under 0.5 mg/dL a minute either
way, and so is the engine's own 20-minute trend at issue. **In-range flat run**: the same, with every
reading in the 45 minutes between 70 and 180. Each plateau point is compared with the mean of up to
5 in-range flat points with the nearest trend (within 0.2 mg/dL a minute) and the same "anything
logged in the 2 hours before issue" flag.

Replay: the engine's trend forecast every 5 minutes (20-minute least-squares slope clamped at ±4,
30-minute fade, minute midpoint integration), at the tuner's gains 0.45, 0.6 and 0.7, scored
against the reading nearest the target (within 2 minutes). It leaves out carbs and insulin, which
the live engine draws (correction doses included), so the live accuracy log is reported first.
Points with anything logged in the hour after issue are dropped (the accuracy log's after_log rule).
Range in the replay: the 10th-90th percentile of every other day's errors at that horizon, the same
band for every start, as the app's own range is an offset in mg/dL that doesn't grow with glucose
(only §41's lower-side widening at 60 minutes does, which the live log shows).

Fix tried (forecast line only, never the insulin curve, sensitivity or carbs): on plateau points,
the trend's gain is scaled by k (0 to 1.5, 1 is as ships) and the line moves by a fixed drift d
mg/dL a minute (-0.4 to +0.2, faded in over 30 minutes), picked on the other Perth days and scored
on the held-out one (leave one day out over the days with plateau points), by 30- plus 60-minute
MAE over all points. Ship bar: better at 30 and 60 minutes on most held-out days at every gain, on
the plateau points and on all points, and no extra false predicted-high crossings (line crossing
250 at 30 minutes from below with no reading at 250+ in the next 45 minutes).
"""
import bisect, datetime as dt, json, os, statistics as st, sys

d = sys.argv[1]
R = json.load(open(f"{d}/readings.json"))
L = json.load(open(f"{d}/logs.json"))
T = [r[0] for r in R]
FADE, MAX = 30.0, 4.0
GAINS = (0.45, 0.6, 0.7)
HS = (15, 30, 60)
WIN = 45 * 60

def perth(t): return dt.datetime.fromtimestamp(t + 8 * 3600, dt.UTC)
def at(t, tol=120):
    i = bisect.bisect_left(T, t)
    c = [j for j in (i - 1, i) if 0 <= j < len(T)]
    j = min(c, key=lambda j: abs(T[j] - t))
    return R[j][1] if abs(T[j] - t) <= tol else None

def ls(t, span, need, cover):
    i, j = bisect.bisect_left(T, t - span), bisect.bisect_right(T, t)
    pts = [((T[k] - t) / 60, R[k][1]) for k in range(i, j)]
    if len(pts) < need or pts[-1][0] - pts[0][0] < cover: return None, pts
    mx = st.mean(p[0] for p in pts); my = st.mean(p[1] for p in pts)
    sxx = sum((p[0] - mx) ** 2 for p in pts)
    return (sum((p[0] - mx) * (p[1] - my) for p in pts) / sxx if sxx else None), pts

def slope(t):
    s, _ = ls(t, 1200, 3, 9)
    return None if s is None else max(-MAX, min(MAX, s))

def kind_at(t, tr):
    """'plateau', 'flat' (in range), or None, from the 45 minutes before t and the trend at t."""
    if tr is None or abs(tr) >= 0.5: return None
    s45, pts = ls(t, WIN, 20, 40)
    if s45 is None or abs(s45) >= 0.5: return None
    if all(p[1] > 180 for p in pts): return "plateau"
    if all(70 <= p[1] <= 180 for p in pts): return "flat"
    return None

logged = sorted(l[0] for l in L if l[1] in ("meal", "rapid", "treat"))
rapid = sorted(l[0] for l in L if l[1] == "rapid")
def any_in(xs, a, b):
    i = bisect.bisect_left(xs, a)
    return i < len(xs) and xs[i] <= b

def matched(sub, ctrl, key):
    out = []
    for p in sub:
        c = [q for q in ctrl if abs(q["tr"] - p["tr"]) <= 0.2 and q["fed"] == p["fed"]]
        if not c: continue
        c.sort(key=lambda q: abs(q["tr"] - p["tr"]))
        out.append((key(p), st.mean(key(q) for q in c[:5])))
    return out

print(f"Readings {len(R)} from {perth(T[0]):%d %b %H:%M} to {perth(T[-1]):%d %b %H:%M} Perth")

# Live accuracy log
if os.path.exists(f"{d}/points.json"):
    P = json.load(open(f"{d}/points.json"))
    live = []
    for t, dev, basis, m, f, lo, hi, a, s, tr in P:
        if None in (f, lo, hi, a, s, tr): continue
        k = kind_at(t, tr)
        if not k: continue
        live.append(dict(t=t, m=m, f=f, lo=lo, hi=hi, a=a, s=s, tr=tr, k=k, day=perth(t).strftime("%d"),
                         fed=any_in(logged, t - 7200, t), dosed=any_in(rapid, t - 3 * 3600, t)))
    print("\nLive accuracy log, clean shown points (bias = actual - line; drift = line - start):")
    for m in HS:
        for k in ("plateau", "flat"):
            sub = [p for p in live if p["m"] == m and p["k"] == k]
            if not sub: continue
            ins = [p["lo"] <= p["a"] <= p["hi"] for p in sub]
            print(f"  {m:2d}m {k:8s} n={len(sub):3d} days={len({p['day'] for p in sub})} mae {st.mean(abs(p['a']-p['f']) for p in sub):5.1f}"
                  f" no change {st.mean(abs(p['a']-p['s']) for p in sub):5.1f} bias {st.mean(p['a']-p['f'] for p in sub):+6.1f}"
                  f" drift {st.mean(p['f']-p['s'] for p in sub):+6.1f} inside {100*st.mean(ins):3.0f}%"
                  f" above {100*st.mean(p['a'] > p['hi'] for p in sub):3.0f}% below {100*st.mean(p['a'] < p['lo'] for p in sub):3.0f}%"
                  f" width {st.mean(p['hi']-p['lo'] for p in sub):5.1f} (below line {st.mean(p['f']-p['lo'] for p in sub):4.1f},"
                  f" above {st.mean(p['hi']-p['f'] for p in sub):4.1f}) dosed 3h {sum(p['dosed'] for p in sub)}")

def line(g, tr, gain, k=1.0, dr=0.0, minutes=60):
    out = {}
    for u in range(minutes):
        w = max(0, 1 - (u + 0.5) / FADE)
        g += w * gain * k * tr + (1 - w) * dr
        out[u + 1] = g
    return out

# Replay
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
    pk = max(R[x][1] for x in range(i, bisect.bisect_right(T, t + 45 * 60)))
    pts.append(dict(t=t, day=perth(t).strftime("%d"), g=R[i][1], tr=tr, act=act, k=kind_at(t, tr),
                    peak45=pk, fed=any_in(logged, t - 7200, t), dosed=any_in(rapid, t - 3 * 3600, t),
                    idle=not any_in(logged, t - 4 * 3600, t), hour=perth(t).hour))
days = sorted({p["day"] for p in pts})
pdays = sorted({p["day"] for p in pts if p["k"] == "plateau"})
print(f"\nReplay: {len(pts)} clean forecasts on Perth days {days}; plateau days {pdays}")
for dd in pdays:
    sub = [p for p in pts if p["day"] == dd and p["k"] == "plateau"]
    print(f"  {dd} Nov: {len(sub):3d} plateau points, start {min(p['g'] for p in sub)}-{max(p['g'] for p in sub)},"
          f" hours {sorted({p['hour'] for p in sub})}, dosed in 3 h {sum(p['dosed'] for p in sub)}")

def plat(p): return p["k"] == "plateau"
def tweaked(p): return plat(p) and p["idle"]
def err(p, gain, h, prm=(1.0, 0.0)):
    k, dr = prm
    if tweaked(p) and (k != 1 or dr):
        return p["act"][h] - line(p["g"], p["tr"], gain, k, dr)[h]
    return p["act"][h] - line(p["g"], p["tr"], gain)[h]

def band(sub, gain, h):
    e = sorted(err(p, gain, h) for p in sub)
    return e[int(0.1 * (len(e) - 1))], e[int(0.9 * (len(e) - 1))]

for gain in GAINS:
    qd = {dd: {h: band([p for p in pts if p["day"] != dd], gain, h) for h in HS} for dd in days}
    print(f"\n== Gain {gain}: as ships (band = 10th-90th pct of the other days' errors) ==")
    for h in HS:
        flat = [p for p in pts if p["k"] == "flat"]
        for name, f in (("plateau, all", lambda p: True), ("  dosed in the 3 h before", lambda p: p["dosed"]),
                        ("  no dose in 3 h", lambda p: not p["dosed"]),
                        ("  nothing logged in 4 h", lambda p: p["idle"]),
                        ("  overnight (0-6 am)", lambda p: p["hour"] < 6), ("  daytime", lambda p: p["hour"] >= 6)):
            sub = [p for p in pts if plat(p) and f(p)]
            if not sub: continue
            e = [err(p, gain, h) for p in sub]
            ins = [qd[p["day"]][h][0] <= x <= qd[p["day"]][h][1] for p, x in zip(sub, e)]
            ab = [x > qd[p["day"]][h][1] for p, x in zip(sub, e)]
            be = [x < qd[p["day"]][h][0] for p, x in zip(sub, e)]
            mb = matched(sub, flat, lambda p: err(p, gain, h))
            ma = matched(sub, flat, lambda p: abs(err(p, gain, h)))
            se = sorted(e)
            spread = se[int(0.9 * (len(se) - 1))] - se[int(0.1 * (len(se) - 1))]
            print(f"  {h:2d}m {name:26s} n={len(sub):3d} days={len({p['day'] for p in sub})} mae {st.mean(abs(x) for x in e):5.1f}"
                  f" no change {st.mean(abs(p['act'][h]-p['g']) for p in sub):5.1f} bias {st.mean(e):+6.1f}"
                  f" inside {100*st.mean(ins):3.0f}% above {100*st.mean(ab):3.0f}% below {100*st.mean(be):3.0f}%"
                  f" spread {spread:5.1f}"
                  + (f" | matched n={len(mb)} bias {st.mean(x[0] for x in mb):+6.1f} vs {st.mean(x[1] for x in mb):+6.1f}"
                     f" mae {st.mean(x[0] for x in ma):5.1f} vs {st.mean(x[1] for x in ma):5.1f}" if mb else ""))
        e = [err(p, gain, h) for p in flat]; se = sorted(e)
        ins = [qd[p["day"]][h][0] <= x <= qd[p["day"]][h][1] for p, x in zip(flat, e)]
        print(f"  {h:2d}m {'in-range flat runs':26s} n={len(flat):3d} days={len({p['day'] for p in flat})} mae {st.mean(abs(x) for x in e):5.1f}"
              f" bias {st.mean(e):+6.1f} inside {100*st.mean(ins):3.0f}%"
              f" spread {se[int(0.9*(len(se)-1))]-se[int(0.1*(len(se)-1))]:5.1f}")
        b = qd[days[0]][h]
        print(f"  {h:2d}m band from all other points (first day out) {b[0]:+.1f} to {b[1]:+.1f}")
    if gain == 0.45:
        print("  per day, plateau points: n, bias 15/30/60")
        for dd in pdays:
            sub = [p for p in pts if p["day"] == dd and plat(p)]
            print(f"    {dd} Nov n={len(sub):3d} " + " ".join(f"{st.mean(err(p, gain, h) for p in sub):+6.1f}" for h in HS)
                  + f" start {st.mean(p['g'] for p in sub):.0f} trend {st.mean(p['tr'] for p in sub):+.2f}")

GRID = [(k, dr) for k in (0.0, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5) for dr in (-0.8, -0.6, -0.5, -0.4, -0.3, -0.2, -0.1, 0.0, 0.1, 0.2)]
def mae(sub, gain, prm, hs=(30, 60)):
    return {h: st.mean(abs(err(p, gain, h, prm)) for p in sub) for h in hs}
def highs(sub, gain, prm, level=250):
    w = r = 0
    for p in sub:
        k, dr = prm
        f = line(p["g"], p["tr"], gain, k, dr)[30] if tweaked(p) else line(p["g"], p["tr"], gain)[30]
        if p["g"] < level <= f:
            w += 1; r += p["peak45"] >= level
    return w, r

for gain in GAINS:
    print(f"\n== Gain {gain}: plateau trend scale k / drift d (nothing logged in 4 h), leave one Perth day out"
          f" (scored on days with 3+ such points) ==")
    wins = {30: 0, 60: 0}; pwins = {30: 0, 60: 0}; picks = []; n = 0
    for dd in pdays:
        train = [p for p in pts if p["day"] != dd]; test = [p for p in pts if p["day"] == dd]
        pt = [p for p in test if tweaked(p)]
        if len(pt) < 3: continue
        n += 1
        best = min(GRID, key=lambda prm: sum(mae(train, gain, prm).values())); picks.append(best)
        a0, a1 = mae(test, gain, (1.0, 0.0)), mae(test, gain, best)
        r0, r1 = mae(pt, gain, (1.0, 0.0)), mae(pt, gain, best)
        for h in (30, 60):
            wins[h] += a1[h] < a0[h] - 1e-9; pwins[h] += r1[h] < r0[h] - 1e-9
        print(f"  {dd} picks k={best[0]} d={best[1]:+}: all n={len(test)} 30m {a0[30]:.2f}→{a1[30]:.2f} 60m {a0[60]:.2f}→{a1[60]:.2f}"
              f" | plateau n={len(pt)} 30m {r0[30]:.1f}→{r1[30]:.1f} 60m {r0[60]:.1f}→{r1[60]:.1f}")
    print(f"  better held out, all points: 30m {wins[30]}/{n}, 60m {wins[60]}/{n}; plateau points: 30m {pwins[30]}/{n}, 60m {pwins[60]}/{n}")
    prm = max(set(picks), key=picks.count)
    a0, a1 = mae(pts, gain, (1.0, 0.0)), mae(pts, gain, prm)
    h0, h1 = highs(pts, gain, (1.0, 0.0)), highs(pts, gain, prm)
    print(f"  most-picked k={prm[0]} d={prm[1]:+}: all-point MAE 30m {a0[30]:.2f}→{a1[30]:.2f} 60m {a0[60]:.2f}→{a1[60]:.2f};"
          f" predicted-high crossings {h0[0]} ({h0[1]} came true) → {h1[0]} ({h1[1]})")
