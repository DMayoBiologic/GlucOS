#!/usr/bin/env python3
"""Does the forecast lag dawn rises, and is its range as well calibrated there as on daytime unlogged
rises? Would a time-of-day trend boost help on mornings it wasn't fitted on? (ForecastAccuracy.md §88)

Usage: python3 scripts/dawn-rises.py DIR
DIR holds readings.json ([[unix, mgdl], ...], live readings only, from glucos.readings where
trend > 0) and logs.json ([[unix, "meal" | "rapid"], ...] from glucos.logbook), as for §65's
scripts/unannounced-rise.py.

Replays the engine's trend forecast (20-minute least-squares slope clamped at ±4, 30-minute fade,
minute midpoint integration, so the line is flat after 30 minutes) every 5 minutes, issued at the
latest reading in each slot, at the tuner's gains (0.45 Mac/relay, 0.6, 0.7 iPhone), scored at 15,
30 and 60 minutes against the reading nearest the target (within 2 minutes).

Groups, judged only from what the app has at issue time:
  rise          engine trend >= 0.5 mg/dL a minute
  unlogged      no meal and no rapid dose logged in the 4 hours before issue
  dawn rise     an unlogged rise issued 03:00-07:59 Perth
  day rise      an unlogged rise issued 09:00-21:59 Perth (the §65 comparison, slower rises included)
Dawn and day points with a meal logged in the hour after issue are dropped from every report, fit
and score (the rise may be a late-logged meal); the tweak itself can't see that and never uses it.

Range: the app draws the 10th-90th percentile of its own past errors around the line
(ForecastCalibration). The replay does the same: the band is the line plus the 10th and 90th
percentiles of the replayed forecasts' errors at that horizon on the other Perth days (leave one day
out, so no point helps set its own band). "Inside" should be ~80% if the range is calibrated.

Lag: the median share of the line's drawn 30-minute rise that the reading actually delivered. Over 1
means the reading rose further than drawn (the line lags the rise); under 1 means it stalled sooner.

Tweak, fitted leave-one-Perth-morning-out (objective: sum of 30- and 60-minute MAE over all points
of the training days): for dawn rises only, the gain is multiplied by k in the first 30 minutes (k < 1 damps, k > 1
boosts) and the trend carries on past the fade at share b (rate += (1 - w) * b * trend). Every
other forecast is untouched. A rising line only moves on a rise, so low warnings move only if a
damped line starting near range would have crossed under 70, which the script counts.
Ship bar: better held out at both 30 and 60 minutes on most mornings at every gain, on the dawn
rises themselves and over all points.
"""
import bisect, datetime as dt, itertools, json, statistics as st, sys

d = sys.argv[1]
R = json.load(open(f"{d}/readings.json"))
L = json.load(open(f"{d}/logs.json"))
T = [r[0] for r in R]
logs = sorted(t for t, k in L if k in ("meal", "rapid"))
meals = sorted(t for t, k in L if k == "meal")
FADE, MAX = 30.0, 4.0
GAINS = (0.45, 0.6, 0.7)
HS = (15, 30, 60)
RISE = 0.5

def perth(t): return dt.datetime.fromtimestamp(t + 8 * 3600, dt.UTC)

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

def any_in(ts, t0, t1):
    i = bisect.bisect_left(ts, t0)
    return i < len(ts) and ts[i] <= t1

def line(g, tr, gain, k=1.0, b=0.0, minutes=60):
    out = {}
    for u in range(minutes):
        m = u + 0.5
        w = max(0, 1 - m / FADE)
        g += w * gain * k * tr + (1 - w) * b * tr
        out[u + 1] = g
    return out

pts = []
for slot in range(T[0] - T[0] % 300 + 300, T[-1] - 5400, 300):
    i = bisect.bisect_right(T, slot) - 1
    if i < 0 or slot - T[i] >= 300: continue
    t = T[i]
    tr = slope(window(t, 20))
    if tr is None: continue
    act = {h: at(t + h * 60) for h in HS}
    if any(v is None for v in act.values()): continue
    hr = perth(t).hour
    unlogged = not any_in(logs, t - 4 * 3600, t)
    rise = tr >= RISE and unlogged
    grp = "dawn" if rise and 3 <= hr < 8 else "day" if rise and 9 <= hr < 22 else "other"
    path = [(T[k] - t) / 60 for k in range(i, bisect.bisect_right(T, t + 90 * 60))]
    pk = max((R[k][1] for k in range(i, bisect.bisect_right(T, t + 45 * 60))), default=0)
    pts.append(dict(t=t, day=perth(t).strftime("%d"), hr=hr, g=R[i][1], tr=tr, act=act, grp=grp, rise=rise, peak45=pk,
                    mealafter=any_in(meals, t, t + 3600), path=[(u, R[i + n][1]) for n, u in enumerate(path)]))

days = sorted({p["day"] for p in pts})
dawn_days = sorted({p["day"] for p in pts if p["grp"] == "dawn"})
print(f"{len(pts)} forecasts, Perth days {days}; dawn-rise mornings {dawn_days}")

SCOPE = {"dawn": ("dawn",), "all unlogged rises": ("dawn", "day", "rise")}
scope = SCOPE["dawn"]

def fc(p, gain, prm):
    k, b = prm
    if (p["grp"] in scope or ("rise" in scope and p["rise"])) and (k != 1 or b): return line(p["g"], p["tr"], gain, k, b)
    return line(p["g"], p["tr"], gain)

def quantiles(sub, gain):
    q = {}
    for h in HS:
        e = sorted(p["act"][h] - line(p["g"], p["tr"], gain)[h] for p in sub)
        q[h] = (e[int(0.1 * (len(e) - 1))], e[int(0.9 * (len(e) - 1))])
    return q

def day_quantiles(gain):
    """Bands for each Perth day from the other days' errors only, so coverage is out of sample."""
    return {dd: quantiles([p for p in pts if p["day"] != dd], gain) for dd in days}

def report(sub, gain, qd, prm=(1.0, 0.0)):
    out = {}
    for h in HS:
        err = [p["act"][h] - fc(p, gain, prm)[h] for p in sub]
        lo = [qd[p["day"]][h][0] for p in sub]; hi = [qd[p["day"]][h][1] for p in sub]
        out[h] = dict(n=len(err), mae=st.mean(abs(e) for e in err), bias=st.mean(err), med=st.median(err),
                      ins=100 * st.mean(l <= e <= u for e, l, u in zip(err, lo, hi)),
                      above=100 * st.mean(e > u for e, u in zip(err, hi)),
                      below=100 * st.mean(e < l for e, l in zip(err, lo)),
                      nc=st.mean(abs(p["act"][h] - p["g"]) for p in sub))
    return out

def delivered(sub, gain, h=30):
    """Median share of the line's drawn rise that the reading delivered by h minutes. Over 1: the
    reading rose further than drawn, so the line lags the rise; under 1: the rise stalled sooner."""
    return st.median((p["act"][h] - p["g"]) / (line(p["g"], p["tr"], gain)[h] - p["g"]) for p in sub)

for gain in GAINS:
    q = quantiles(pts, gain); qd = day_quantiles(gain)
    print(f"\n== Gain {gain}: as ships (band = 10th-90th pct of the other days' errors; all days: "
          + ", ".join(f"{h}m {q[h][0]:+.0f}/{q[h][1]:+.0f}" for h in HS) + ") ==")
    for name, f in (("dawn rise", lambda p: p["grp"] == "dawn" and not p["mealafter"]),
                    ("day rise", lambda p: p["grp"] == "day" and not p["mealafter"]),
                    ("dawn, not rising (unlogged)", lambda p: p["grp"] == "other" and 3 <= p["hr"] < 8),
                    ("everything", lambda p: True)):
        sub = [p for p in pts if f(p)]
        if not sub: continue
        r = report(sub, gain, qd)
        print(f"  {name:28s} n={len(sub):4d} days={len({p['day'] for p in sub})} trend {st.mean(p['tr'] for p in sub):.2f}"
              f" start {st.mean(p['g'] for p in sub):.0f}"
              + (f"  reading delivered {delivered(sub, gain):.2f} of the drawn 30m rise (median)" if "rise" in name else ""))
        for h in HS:
            x = r[h]
            print(f"      {h:2d}m mae {x['mae']:5.1f} (no change {x['nc']:5.1f}) bias {x['bias']:+6.1f} (med {x['med']:+6.1f}) "
                  f"inside {x['ins']:3.0f}% above {x['above']:3.0f}% below {x['below']:3.0f}%")
    if gain == 0.45:
        print("  per morning, dawn rises: n, bias 15/30/60, inside 30/60")
        for dd in dawn_days:
            sub = [p for p in pts if p["day"] == dd and p["grp"] == "dawn" and not p["mealafter"]]
            if sub:
                r = report(sub, gain, qd)
                print(f"    {dd} Nov n={len(sub):3d}  {r[15]['bias']:+6.1f} {r[30]['bias']:+6.1f} {r[60]['bias']:+6.1f}  "
                      f"{r[30]['ins']:3.0f}% {r[60]['ins']:3.0f}%  start {st.mean(p['g'] for p in sub):.0f} "
                      f"trend {st.mean(p['tr'] for p in sub):.2f}")

GRID = [(k, 0.0) for k in (0.0, 0.25, 0.4, 0.55, 0.7, 0.85)] + [(k, b) for k in (1.0, 1.2, 1.4, 1.7, 2.0) for b in (0.0, 0.1, 0.2, 0.35, 0.5)]
def mae(sub, gain, prm, hs=(30, 60)):
    return {h: st.mean(abs(p["act"][h] - fc(p, gain, prm)[h]) for p in sub) for h in hs}

def highs(sub, gain, prm, level=250):
    warned = real = 0
    for p in sub:
        ln = fc(p, gain, prm)
        if p["g"] < level <= ln[30]:
            warned += 1; real += p["peak45"] >= level
    reached = sum(1 for p in sub if p["g"] < level <= p["peak45"])
    return warned, real, reached

for name in SCOPE:
    scope = SCOPE[name]
    for gain in GAINS:
        scored = [p for p in pts if not (p["grp"] in ("dawn", "day") and p["mealafter"])]
        print(f"\n== Gain {gain}: trend scale k / carry-on b on {name}, leave one Perth morning out ==")
        wins = {30: 0, 60: 0}; dwins = {30: 0, 60: 0}; picks = []
        for dd in dawn_days:
            train = [p for p in scored if p["day"] != dd]
            test = [p for p in scored if p["day"] == dd]
            best = min(GRID, key=lambda prm: sum(mae(train, gain, prm).values())); picks.append(best)
            b0, b1 = mae(test, gain, (1.0, 0.0)), mae(test, gain, best)
            dt_ = [p for p in test if p["grp"] == "dawn"]
            d0, d1 = mae(dt_, gain, (1.0, 0.0)), mae(dt_, gain, best)
            for h in (30, 60):
                wins[h] += b1[h] < b0[h] - 1e-9; dwins[h] += d1[h] < d0[h] - 1e-9
            print(f"  {dd} Nov picks k={best[0]} b={best[1]}: all n={len(test)} 30m {b0[30]:.2f}→{b1[30]:.2f} 60m {b0[60]:.2f}→{b1[60]:.2f}"
                  f" | dawn rises n={len(dt_)} 30m {d0[30]:.1f}→{d1[30]:.1f} 60m {d0[60]:.1f}→{d1[60]:.1f}")
        print(f"  better held out (all points): 30m {wins[30]}/{len(dawn_days)}, 60m {wins[60]}/{len(dawn_days)}; "
              f"dawn rises: 30m {dwins[30]}/{len(dawn_days)}, 60m {dwins[60]}/{len(dawn_days)}")
        prm = max(set(picks), key=picks.count)
        qd = day_quantiles(gain)
        for gname in ("dawn", "day"):
            sub = [p for p in pts if p["grp"] == gname and not p["mealafter"]]
            r0, r1 = report(sub, gain, qd), report(sub, gain, qd, prm)
            print(f"  {gname} rises with k={prm[0]} b={prm[1]}: " + "  ".join(
                f"{h}m bias {r0[h]['bias']:+.1f}→{r1[h]['bias']:+.1f} inside {r0[h]['ins']:.0f}→{r1[h]['ins']:.0f}%" for h in HS))
        w0, w1 = highs(scored, gain, (1.0, 0.0)), highs(scored, gain, prm)
        print(f"  predicted-high crossings (30m line crosses 250 from below): as ships {w0[0]} ({w0[1]} reached 250 in 45 min), "
              f"tweak {w1[0]} ({w1[1]}); {w0[2]} forecasts were under 250 and reached it within 45 min")

scope = SCOPE["dawn"]
print("\n== Gain 0.45, dawn only: each fixed k scored per morning (no fitting) ==")
for k in (0.0, 0.25, 0.4, 0.55, 0.7, 0.85, 1.0):
    w = {30: 0, 60: 0}
    scored = [p for p in pts if not (p["grp"] in ("dawn", "day") and p["mealafter"])]
    for dd in dawn_days:
        test = [p for p in scored if p["day"] == dd]
        a, b = mae(test, 0.45, (1.0, 0.0)), mae(test, 0.45, (k, 0.0))
        for h in (30, 60): w[h] += b[h] < a[h] - 1e-9
    allm = mae(scored, 0.45, (k, 0.0)); hi = highs(scored, 0.45, (k, 0.0))
    print(f"  k={k:4.2f}: better on 30m {w[30]}/{len(dawn_days)}, 60m {w[60]}/{len(dawn_days)} mornings; all-point MAE "
          f"30m {allm[30]:.2f} 60m {allm[60]:.2f}; predicted-high crossings {hi[0]} ({hi[1]} reached 250)")
dawn = [p for p in scored if p["grp"] == "dawn"]
print(f"  dawn rises: {len(dawn)}, by hour " + ", ".join(f"{h:02d}h {sum(p['hr'] == h for p in dawn)}" for h in range(3, 8))
      + f"; reading lower 30 min later on {sum(p['act'][30] < p['g'] for p in dawn)}, 60 min later on {sum(p['act'][60] < p['g'] for p in dawn)}")
print("  correct predicted-high crossings at dawn that k = 0 removes:")
for p in dawn:
    if p["g"] < 250 <= line(p["g"], p["tr"], 0.45)[30] and p["peak45"] >= 250:
        print(f"    {perth(p['t']).strftime('%d Nov %H:%M')} reading {p['g']} trend {p['tr']:+.2f} peak in 45 min {p['peak45']}")

