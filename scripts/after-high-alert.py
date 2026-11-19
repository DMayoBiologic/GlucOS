#!/usr/bin/env python3
"""The hour after a high alert fires: does the line show the come-down on time? (ForecastAccuracy.md §103)

Usage: python3 -I scripts/after-high-alert.py DIR
DIR holds:
  alerts.txt   ';'-separated "firedAt,kind,response" from the Alert History store:
                 select string_agg(concat_ws(',', round((payload->>'firedAt')::float)::bigint,
                   payload->>'kind', coalesce(payload->>'response','none')), ';'
                   order by (payload->>'firedAt')::float)
                 from glucos.logbook where kind = 'alert' and not deleted;
  readings.json [[unix, mgdl], ...] live readings (glucos.readings where trend > 0) from 30 min
               before to 3.5 h after each episode start (the list the script prints).
  logs.json    [[unix, "meal" | "rapid", grams | units, food], ...] from glucos.logbook.
  points.json  [[issued, device, minutes, line, lower, upper, actual, start, basis], ...] clean
               shown 15/30/60-min accuracy-log points (nothing logged before the reading came in)
               issued in the hour after an episode start.

Episodes: the first high or veryHigh alert with no other high or veryHigh alert in the 45 min
before it (repeats of the same high fold in, as AlertLog does). Predicted-high alerts don't start
one. Treated = a rapid dose logged from 15 min before the start to 60 min after it.

Replay = the engine's model forecast (as §101/§102: trend at the tuner's gain fading over 30 min,
plus K x carbs - S x insulin), issued every 5 min for the hour after the start and scored at
15/30/60 min. Bias = actual - line (negative = line high).

Come-down: the first reading at least 10 min after the start that is 20 mg/dL or more under the
highest reading since the start, with the next 10 min staying under that peak minus 15 (the fall
has begun). The line "calls" it when a forecast issued after the peak draws its 30-min point
lower than its start by 10 or more. Lead = come-down time - call time (negative = late).

Tweak tried (forecast only; insulin on board, the insulin curve, sensitivity, carb ratios and the
bolus calculator untouched): in the hour after a high alert, a rising trend above 180 is scaled by
w (0-1). w is picked on the other days and scored on the held-out day (leave one Perth day out).
"""
import bisect, datetime as dt, json, math, statistics as st, sys
from collections import defaultdict

d = sys.argv[1]
R = json.load(open(f"{d}/readings.json")); T = [r[0] for r in R]
L = json.load(open(f"{d}/logs.json"))
P = json.load(open(f"{d}/points.json"))
A = [x.split(',') for x in open(f"{d}/alerts.txt").read().strip().split(';') if x]
K, S, FADE, MAX = 2.8, 19.2, 30.0, 4.0
HS = (15, 30, 60)
HIGH = {'high', 'veryHigh'}


def perth(t): return dt.datetime.fromtimestamp(t + 8 * 3600, dt.UTC)
def lab(t): return perth(t).strftime("%d Nov %H:%M")
def day(t): return perth(t).strftime("%d Nov")


def at(t, tol=120):
    i = bisect.bisect_left(T, t); c = [j for j in (i - 1, i) if 0 <= j < len(T)]
    if not c: return None
    j = min(c, key=lambda j: abs(T[j] - t)); return R[j][1] if abs(T[j] - t) <= tol else None


def window(a, b): return R[bisect.bisect_left(T, a):bisect.bisect_right(T, b)]


def slope(t):
    pts = [((x - t) / 60, g) for x, g in window(t - 1200, t)]
    if len(pts) < 3 or pts[-1][0] - pts[0][0] < 9: return None
    mx = st.mean(p[0] for p in pts); my = st.mean(p[1] for p in pts); sxx = sum((p[0] - mx) ** 2 for p in pts)
    return max(-MAX, min(MAX, sum((p[0] - mx) * (p[1] - my) for p in pts) / sxx)) if sxx else None


def carb_rate(e, delay=600, absorb=10800):
    x = (e - delay) / absorb; rise, fall = 0.15, 0.5; sc = 2 / (1 + fall - rise)
    u = 0 if x <= 0 or x >= 1 else sc * x / rise if x < rise else sc if x < fall else sc * (1 - x) / (1 - fall)
    return u / (absorb / 60)


def ins(e):
    delay, peak, dur = 600.0, 75 * 60.0, 6 * 3600.0; tau = peak * (1 - peak / dur) / (1 - 2 * peak / dur); a = 2 * tau / dur
    s = 1 / (1 - a + (1 + a) * math.exp(-dur / tau)); t = e - delay
    if t <= 0 or t >= dur: return 0
    return max(0, (s / tau ** 2) * t * (1 - t / dur) * math.exp(-t / tau)) * 60


meals = [dict(t=t, g=v) for t, k, v, _ in L if k == 'meal']
doses = [(t, v) for t, k, v, _ in L if k == 'rapid']

# Episodes
highs = sorted((int(t), k, r) for t, k, r in A if k in HIGH)
E = []
for t, k, r in highs:
    if any(t - 2700 <= s < t for s, _, _ in highs): continue
    copies = [x for x in highs if t <= x[0] <= t + 3600]
    g0 = at(t, 300)
    treated = any(t - 900 <= x <= t + 3600 for x, _ in doses)
    meal = any(t - 3 * 3600 <= m["t"] <= t + 3600 for m in meals)
    E.append(dict(t=t, kind=k, g0=g0, day=day(t), treated=treated, meal=meal,
                  resp=sorted({x[2] for x in copies} - {'none'})))
print(f"{len(E)} episodes, {len({e['day'] for e in E})} days")


def forecast(t0, g0, tr, gain, w=1.0, h=60):
    known = [m for m in meals if m["t"] <= t0 and t0 - m["t"] < 4 * 3600]
    ds = [x for x in doses if x[0] <= t0 and t0 - x[0] < 6.5 * 3600]
    if tr > 0 and g0 > 180: tr *= w
    g, out = g0, {}
    for u in range(h):
        mid = t0 + (u + .5) * 60; wf = max(0, 1 - (u + .5) / FADE); rate = 0.0
        for m in known: rate += K * m["g"] * carb_rate(mid - m["t"])
        for tx, un in ds: rate -= S * un * ins(mid - tx)
        g += wf * gain * tr + (1 - wf) * rate; out[u + 1] = max(39, min(401, g))
    return out


# Come-down per episode
for e in E:
    e["peak"] = e["down"] = None
    run = window(e["t"], e["t"] + 3 * 3600)
    if not run or e["g0"] is None: continue
    best = run[0]
    for i, (t, g) in enumerate(run):
        if g > best[1]: best = (t, g)
        if t - e["t"] < 600 or g > best[1] - 20: continue
        nxt = [x for x in run[i:] if x[0] <= t + 600]
        if nxt and max(x[1] for x in nxt) <= best[1] - 15:
            e["peak"], e["down"] = best, t
            break

pts = []
for e in E:
    if e["g0"] is None: continue
    for k in range(0, 61, 5):
        ti = e["t"] + k * 60
        i = bisect.bisect_right(T, ti) - 1
        if i < 0 or ti - T[i] >= 300: continue
        t0, g0 = R[i]; tr = slope(t0)
        if tr is None: continue
        act = {h: a for h in HS if (a := at(t0 + h * 60)) is not None}
        if act: pts.append(dict(t0=t0, g0=g0, tr=tr, act=act, e=e, day=e["day"], k=k))
print(f"Replay: {len(pts)} forecasts on {len({id(p['e']) for p in pts})} episodes")

cache = {}
def line(p, gain, w=1.0):
    key = (id(p), gain, w)
    if key not in cache: cache[key] = forecast(p["t0"], p["g0"], p["tr"], gain, w)
    return cache[key]


def stats(sub, gain, h, w=1.0):
    e = [p["act"][h] - line(p, gain, w)[h] for p in sub if h in p["act"]]
    nc = [abs(p["act"][h] - p["g0"]) for p in sub if h in p["act"]]
    if not e: return None
    return len(e), st.mean(abs(x) for x in e), st.mean(e), st.mean(nc)


def fmt(s, h): return f"{h}m n={s[0]:3d} mae {s[1]:5.1f} nc {s[3]:5.1f} bias {s[2]:+6.1f}" if s else f"{h}m -"


def calls(e, gain, w=1.0):
    """Minutes the line called the come-down ahead of it (negative = after), or None."""
    if not e["down"]: return None
    pk = e["peak"][0]
    for t in range(pk - 1800, e["down"] + 1801, 300):
        i = bisect.bisect_right(T, t) - 1
        if i < 0 or t - T[i] >= 300 or T[i] < e["t"]: continue
        t0, g0 = R[i]; tr = slope(t0)
        if tr is None: continue
        if forecast(t0, g0, tr, gain, w, 30)[30] <= g0 - 10: return (e["down"] - t0) / 60
    return None


print("\nEpisodes (start, kind, reading, treated, meal in last 3 h, responses, peak, come-down):")
for e in E:
    pk = f"peak {e['peak'][1]} at +{(e['peak'][0]-e['t'])/60:.0f}m, down +{(e['down']-e['t'])/60:.0f}m" if e["down"] else "no come-down in 3 h"
    print(f"  {lab(e['t'])} {e['kind']:8s} {e['g0']} treated={int(e['treated'])} meal={int(e['meal'])} {','.join(e['resp']) or '-':10s} {pk}")

G = [("all", lambda p: True), ("untreated", lambda p: not p["e"]["treated"]),
     ("treated", lambda p: p["e"]["treated"]), ("meal in 3 h", lambda p: p["e"]["meal"]),
     ("no meal", lambda p: not p["e"]["meal"]), ("first 30 min", lambda p: p["k"] < 30),
     ("30-60 min", lambda p: p["k"] >= 30), ("rising at issue", lambda p: p["tr"] > 0.5),
     ("flat", lambda p: -0.5 <= p["tr"] <= 0.5), ("falling", lambda p: p["tr"] < -0.5)]
for gain in (0.45, 0.6, 0.7):
    print(f"\n== gain {gain} (bias = actual - line; negative = line high) ==")
    for n, f in G:
        sub = [p for p in pts if f(p)]
        print(f"  {n:16s} eps={len({id(p['e']) for p in sub}):2d} days={len({p['day'] for p in sub})} | " + " | ".join(fmt(stats(sub, gain, h), h) for h in HS))
    leads = [(e, calls(e, gain)) for e in E if e["down"]]
    got = [x for _, x in leads if x is not None]
    print(f"  come-down called: {len(got)}/{len(leads)}, lead median {st.median(got) if got else 0:+.0f} min, "
          f"late {sum(x < 0 for x in got)}, on time or early {sum(x >= 0 for x in got)}")
    if gain == 0.45:
        for e, x in leads: print(f"    {lab(e['t'])} down +{(e['down']-e['t'])/60:.0f}m lead {x if x is None else f'{x:+.0f}'}")

# Live accuracy log
seen = set(); g = defaultdict(list)
for t, dv, m, f, lo, hi, a, s, b in P:
    if (t, dv, m) in seen: continue
    seen.add((t, dv, m))
    c = [e for e in E if e["t"] <= t <= e["t"] + 3600]
    if not c: continue
    e = c[-1]
    phase = "after peak" if e["down"] and t >= e["peak"][0] else "before peak"
    for key in (("all", m), ("untreated" if not e["treated"] else "treated", m), (phase, m), ("app" if dv != 'r' else "relay", m)):
        g[key].append((a - f, a - s, lo <= a <= hi, hi - lo, a > hi, a < lo, e["day"]))
print("\nLive log, clean shown points issued in the hour after (bias = actual - line):")
for k in sorted(g):
    v = g[k]
    print(f"  {k[0]:12s} {k[1]:2d}m n={len(v):3d} days={len({x[6] for x in v})} mae {st.mean(abs(x[0]) for x in v):5.1f} nc {st.mean(abs(x[1]) for x in v):5.1f} "
          f"bias {st.mean(x[0] for x in v):+6.1f} inside {100*st.mean(x[2] for x in v):3.0f}% above {100*st.mean(x[4] for x in v):3.0f}% "
          f"below {100*st.mean(x[5] for x in v):3.0f}% width {st.mean(x[3] for x in v):5.1f}")

# Held out by day: rising-trend scale above 180 in the hour after
days = sorted({p["day"] for p in pts})
W = (0, .25, .5, .75, 1)
for gain in (0.45, 0.6, 0.7):
    print(f"\n== held out by day (rising trend above 180 scaled by w), gain {gain} ==")
    win = {h: 0 for h in HS}; lose = {h: 0 for h in HS}; n = {h: 0 for h in HS}; worst = (0, '')
    for dd in days:
        tr = [p for p in pts if p["day"] != dd]; te = [p for p in pts if p["day"] == dd]
        w = min(W, key=lambda w: sum((stats(tr, gain, h, w) or (0, 0))[1] for h in (30, 60)))
        row = []
        for h in HS:
            a, b = stats(te, gain, h), stats(te, gain, h, w)
            if not a: continue
            n[h] += 1; win[h] += b[1] < a[1] - 0.05; lose[h] += b[1] > a[1] + 0.05
            if b[1] - a[1] > worst[0]: worst = (b[1] - a[1], f"{dd} {h}m {a[1]:.1f}->{b[1]:.1f}")
            row.append(f"{h}m {a[1]:.1f}->{b[1]:.1f} (bias {a[2]:+.1f}->{b[2]:+.1f})")
        print(f"  {dd} w={w} " + " ".join(row))
    print("  held-out days better/worse: " + " ".join(f"{h}m {win[h]}/{lose[h]} of {n[h]}" for h in HS) + f"; largest loss {worst[1] or '-'}")
    allw = min(W, key=lambda w: sum((stats(pts, gain, h, w) or (0, 0))[1] for h in (30, 60)))
    leads = [calls(e, gain, allw) for e in E if e["down"]]
    got = [x for x in leads if x is not None]
    print(f"  in-sample w={allw}; come-down called {len(got)}/{len(leads)}, lead median {st.median(got) if got else 0:+.0f} min")
    # Cost: readings that went on to 250+ at 30 min, how many did the line put at 250+?
    for ww in (1, allw):
        hi = [p for p in pts if p["act"].get(30, 0) >= 250 and p["g0"] < 250]
        print(f"  w={ww}: {sum(line(p, gain, ww)[30] >= 250 for p in hi)}/{len(hi)} forecasts below 250 that reached 250+ by 30 min had the line at 250+")
