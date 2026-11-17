#!/usr/bin/env python3
"""Do 30/60-minute forecasts fall short when glucose climbs fast with no meal logged? (ForecastAccuracy.md §65)

Usage: python3 scripts/unannounced-rise.py DIR
DIR holds readings.json ([[unix, mgdl], ...], live readings only, from glucos.readings where trend > 0)
and logs.json ([[unix, "meal" | "rapid" | "long"], ...] from glucos.logbook), as for §45's script.

Replays the engine's trend forecast (20-minute least-squares slope clamped at ±4, 30-minute fade,
minute midpoint integration, so the line is flat after 30 minutes) every 5 minutes, issued at the
latest reading in each slot, at the gains the tuner has fitted (0.45 Mac/relay, 0.6, 0.7 iPhone),
scored at 30 and 60 minutes against the reading nearest the target (within 2 minutes).

An "unannounced rise" is a forecast whose trend is at least T mg/dL/min with no meal logged in the
hour before it was issued. The candidate is a damped momentum boost for those forecasts only: the
rate becomes w·gain·tr + b·tr·exp(−u/τ), so a share b of the trend carries on past the 30-minute
fade and dies away with time constant τ. The "still" variant boosts only when the last 5 minutes
rise at least as fast as the 20-minute trend (not already turning, §45). Every other forecast is
untouched, and a rising line is only ever raised, so low warnings can't move. T, b, τ and the
variant are picked on the other Perth days and scored on the held-out one (leave one day out),
by the sum of 30- and 60-minute mean absolute error over all points.

Then predicted highs: the 30-minute line crossing 250 (urgent high) from below, and whether the
reading actually reached 250 within 45 minutes.
"""
import bisect, datetime as dt, itertools, json, math, statistics as st, sys

d = sys.argv[1]
R = json.load(open(f"{d}/readings.json"))
L = json.load(open(f"{d}/logs.json"))
T = [r[0] for r in R]
meals = sorted(t for t, k in L if k == "meal")
rapids = sorted(t for t, k in L if k == "rapid")
FADE, MAX = 30.0, 4.0
GAINS = (0.45, 0.6, 0.7)
HS = (30, 60)

def window(t, minutes):
    i, j = bisect.bisect_left(T, t - minutes * 60), bisect.bisect_right(T, t)
    return [((T[k] - t) / 60, R[k][1]) for k in range(i, j)]

def slope(pts, span=9):
    if len(pts) < 3 or pts[-1][0] - pts[0][0] < span: return None
    mx = st.mean(p[0] for p in pts); my = st.mean(p[1] for p in pts)
    sxx = sum((p[0] - mx) ** 2 for p in pts)
    return max(-MAX, min(MAX, sum((p[0] - mx) * (p[1] - my) for p in pts) / sxx)) if sxx else None

def at(t, tol=120):
    i = bisect.bisect_left(T, t)
    best = min((j for j in (i - 1, i) if 0 <= j < len(T)), key=lambda j: abs(T[j] - t), default=None)
    return R[best][1] if best is not None and abs(T[best] - t) <= tol else None

def meal_within(t0, t1, ts=None):
    ts = meals if ts is None else ts
    i = bisect.bisect_left(ts, t0)
    return i < len(ts) and ts[i] <= t1

def line(g, tr, gain, b=0.0, tau=30.0, minutes=60):
    out, u = {}, 0
    while u < minutes:
        m = u + 0.5
        g += max(0, 1 - m / FADE) * gain * tr + b * tr * math.exp(-m / tau)
        u += 1
        out[u] = g
    return out

def perth(t): return dt.datetime.fromtimestamp(t + 8 * 3600, dt.UTC)

pts = []
for slot in range(T[0] - T[0] % 300 + 300, T[-1] - 3600, 300):
    i = bisect.bisect_right(T, slot) - 1
    if i < 0 or slot - T[i] >= 300: continue
    t = T[i]
    tr = slope(window(t, 20))
    if tr is None: continue
    short = slope(window(t, 5), span=3)
    act = {h: at(t + h * 60) for h in HS}
    if any(v is None for v in act.values()): continue
    peak45 = max((R[k][1] for k in range(i, bisect.bisect_right(T, t + 45 * 60))), default=0)
    pts.append(dict(t=t, day=perth(t).strftime("%d"), g=R[i][1], tr=tr, short=short, act=act,
                    meal1h=meal_within(t - 3600, t), dose=meal_within(t - 3 * 3600, t + 3600, rapids), mealafter=meal_within(t, t + 3600), peak45=peak45))

def unannounced(p, T_):
    return p["tr"] >= T_ and not p["meal1h"]

def forecast(p, gain, prm):
    T_, b, tau, still = prm
    boost = b > 0 and unannounced(p, T_) and (not still or (p["short"] is not None and p["short"] >= p["tr"]))
    ln = line(p["g"], p["tr"], gain, b if boost else 0.0, tau)
    return ln, boost

GRID = [(0, 0.0, 30.0, False)] + list(itertools.product((1.0, 1.5, 2.0), (0.1, 0.2, 0.35, 0.5), (15.0, 30.0, 60.0), (False, True)))
days = sorted({p["day"] for p in pts})

def score(sub, gain, prm):
    e = {h: [] for h in HS}; bias = {h: [] for h in HS}
    for p in sub:
        ln, _ = forecast(p, gain, prm)
        for h in HS:
            e[h].append(abs(p["act"][h] - ln[h])); bias[h].append(p["act"][h] - ln[h])
    return {h: st.mean(e[h]) if e[h] else float("nan") for h in HS}, {h: st.mean(bias[h]) if bias[h] else float("nan") for h in HS}

print(f"{len(pts)} forecasts, Perth days {days}")
print("\n== The lean (what ships, gain 0.45): bias = actual − forecast, + = ran low ==")
for name, f in (("fast rise ≥1.5, no meal 1 h", lambda p: unannounced(p, 1.5)),
                ("rise 1.0–1.5, no meal 1 h", lambda p: 1.0 <= p["tr"] < 1.5 and not p["meal1h"]),
                ("fast rise ≥1.5, meal in 1 h", lambda p: p["tr"] >= 1.5 and p["meal1h"]),
                ("everything else", lambda p: not (p["tr"] >= 1.0 and not p["meal1h"]))):
    sub = [p for p in pts if f(p)]
    mae, bias = score(sub, 0.45, GRID[0])
    lows = {h: 100 * sum(p["act"][h] > line(p["g"], p["tr"], 0.45)[h] for p in sub) / max(1, len(sub)) for h in HS}
    meds = {h: st.median([p["act"][h] - line(p["g"], p["tr"], 0.45)[h] for p in sub]) if sub else float("nan") for h in HS}
    print(f"{name:30s} n={len(sub):4d} days={len({p['day'] for p in sub})}  "
          + "  ".join(f"{h}m bias {bias[h]:+6.1f} (med {meds[h]:+6.1f}) low {lows[h]:3.0f}% mae {mae[h]:5.1f}" for h in HS))

for name, f in (("fast rise ≥1.5, no meal, meal logged in next hour", lambda p: unannounced(p, 1.5) and p["mealafter"]),
                ("fast rise ≥1.5, no meal before or after", lambda p: unannounced(p, 1.5) and not p["mealafter"]),
                ("fast rise ≥1.5, no meal, no rapid dose 3 h before to 1 h after", lambda p: unannounced(p, 1.5) and not p["dose"])):
    sub = [p for p in pts if f(p)]
    mae, bias = score(sub, 0.45, GRID[0])
    print(f"  {name:62s} n={len(sub):3d} " + "  ".join(f"{h}m bias {bias[h]:+6.1f} mae {mae[h]:5.1f}" for h in HS))

print("\n  per day, fast rise ≥1.5 no meal 1 h (gain 0.45): n, 30m bias, 60m bias")
for dd in days:
    sub = [p for p in pts if p["day"] == dd and unannounced(p, 1.5)]
    if sub:
        _, bias = score(sub, 0.45, GRID[0])
        print(f"    {dd} Nov n={len(sub):3d}  {bias[30]:+6.1f}  {bias[60]:+6.1f}")

def highs(sub, gain, prm, level=250):
    warned = fa = 0
    for p in sub:
        ln, _ = forecast(p, gain, prm)
        if p["g"] < level <= ln[30]:
            warned += 1
            if p["peak45"] < level: fa += 1
    return warned, fa

for gain in GAINS:
    print(f"\n== Gain {gain}: leave one Perth day out ==")
    rows = []
    for dd in days:
        train = [p for p in pts if p["day"] != dd]; test = [p for p in pts if p["day"] == dd]
        best = min(GRID, key=lambda prm: sum(score(train, gain, prm)[0].values()))
        base, _ = score(test, gain, GRID[0]); cand, _ = score(test, gain, best)
        aff = [p for p in test if forecast(p, gain, best)[1]]
        ab, _ = score(aff, gain, GRID[0]); ac, _ = score(aff, gain, best)
        rows.append((dd, best, base, cand, len(test), len(aff), ab, ac))
        print(f"  {dd} Nov picks T={best[0]} b={best[1]} τ={best[2]} still={best[3]}: n={len(test)} "
              f"30m {base[30]:.2f}→{cand[30]:.2f}  60m {base[60]:.2f}→{cand[60]:.2f}  "
              f"| boosted {len(aff)}: 30m {ab[30]:.1f}→{ac[30]:.1f} 60m {ab[60]:.1f}→{ac[60]:.1f}")
    for h in HS:
        b0 = sum(r[2][h] * r[4] for r in rows) / sum(r[4] for r in rows)
        b1 = sum(r[3][h] * r[4] for r in rows) / sum(r[4] for r in rows)
        better = sum(r[3][h] < r[2][h] - 1e-9 for r in rows); worse = sum(r[3][h] > r[2][h] + 1e-9 for r in rows)
        print(f"  all held out {h}m: {b0:.2f} → {b1:.2f} ({100 * (b1 - b0) / b0:+.1f}%), better on {better}, worse on {worse} of {len(rows)} days")
    full = min(GRID, key=lambda prm: sum(score(pts, gain, prm)[0].values()))
    print(f"  fitted on all days: {full}; urgent-high warnings (warned, false) ships {highs(pts, gain, GRID[0])} → {highs(pts, gain, full)}")

print("\n== Fixed candidates on all points, gain 0.45 (in-sample) ==")
base, _ = score(pts, 0.45, GRID[0])
for prm in [(1.5, 0.2, 30.0, False), (1.5, 0.35, 30.0, True), (2.0, 0.5, 30.0, True), (1.0, 0.2, 60.0, False)]:
    m, _ = score(pts, 0.45, prm)
    sub = [p for p in pts if forecast(p, 0.45, prm)[1]]
    sb, bb = score(sub, 0.45, GRID[0]); sc, bc = score(sub, 0.45, prm)
    print(f"  {prm}: all 30m {base[30]:.2f}→{m[30]:.2f} 60m {base[60]:.2f}→{m[60]:.2f}; boosted n={len(sub)} "
          f"30m {sb[30]:.1f}→{sc[30]:.1f} (bias {bb[30]:+.1f}→{bc[30]:+.1f}) 60m {sb[60]:.1f}→{sc[60]:.1f} (bias {bb[60]:+.1f}→{bc[60]:+.1f})")
