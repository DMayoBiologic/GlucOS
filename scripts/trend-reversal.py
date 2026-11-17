#!/usr/bin/env python3
"""Are forecasts worse just after the trend reverses, and would a short damping or wider range help? (ForecastAccuracy.md §59)

Usage: python3 scripts/trend-reversal.py DIR
DIR holds readings.json ([[unix, mgdl], ...], live readings only, from glucos.readings where
trend > 0) and logs.json ([[unix, "meal" | "dose"], ...] from glucos.logbook), as for
scripts/turning-point-damping.py (§45).

Replays the engine's trend forecast (20-minute least-squares slope, 30-minute fade, minute
midpoint integration) every 5 minutes, issued at the latest reading in each 5-minute slot, and
scores it at 15, 30 and 60 minutes at the gains the tuner fits (0.45 Mac/relay, 0.6, 0.7 iPhone).

A reversal is looked for only in what the app already has at issue time (unlike §45, whose
"turning points" were labelled from the trend 15 minutes later). Each minute over the last
LOOK minutes gets a direction from a slope (up if >= +D mg/dL a minute, down if <= -D, else
none). A point is "just after a reversal" when the latest direction in the last 15 minutes is
the opposite of the direction before it, and the flip (the first minute of the new direction)
is at most 15 minutes old. Two slopes are tried: the last 10 minutes ("s10"), and the engine's
own 20-minute trend ("tr20"). D is 0.3 and 0.5.

Fixes, each fitted on five Perth days and scored on the sixth:
  damp:  for W minutes after the flip, the trend is scaled by w (1 = as ships, 0 = no change).
         "rises only" leaves a negative trend alone, so no low warning can move.
  widen: for W minutes after the flip, the 10th-90th percentile band of what ships' misses on
         the training days (one band for every point, as §45) is scaled by k around the line,
         scored by the 80% interval score (width + 10 x any miss distance, lower is better).
Then the low-warning check of §39/§45 for the damping that wins.
"""
import bisect, datetime as dt, json, statistics as st, sys

d = sys.argv[1]
R = json.load(open(f"{d}/readings.json"))
L = json.load(open(f"{d}/logs.json"))
T = [r[0] for r in R]
G = {r[0]: r[1] for r in R}
meals = sorted(t for t, k in L if k == "meal")
FADE, TREND_W, MAX = 30.0, 20, 4.0
GAINS = (0.45, 0.6, 0.7)
H = (15, 30, 60)
LOOK = 45  # minutes of history scanned for the direction before the flip

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
        out[u] = g
    return out

def at(t, tol=120):
    i = bisect.bisect_left(T, t)
    best = min((j for j in (i - 1, i) if 0 <= j < len(T)), key=lambda j: abs(T[j] - t), default=None)
    return R[best][1] if best is not None and abs(T[best] - t) <= tol else None

def perth_day(t): return dt.datetime.fromtimestamp(t + 8 * 3600, dt.UTC).strftime("%d")

scache = {}
def slope_at(t, minutes):
    key = (t // 60, minutes)
    if key not in scache:
        scache[key] = slope(window(t, minutes), span=minutes - 2 if minutes < 11 else 9)
    return scache[key]

def flip_age(t, minutes, D):
    """Minutes since the direction flipped, if it flipped in the last 15 minutes, else None.
    Also returns the new direction (+1 up, -1 down)."""
    dirs = []  # (age in minutes, direction) from now backwards
    for age in range(0, LOOK + 1):
        s = slope_at(t - age * 60, minutes)
        if s is None: continue
        dirs.append((age, 1 if s >= D else -1 if s <= -D else 0))
    signed = [(a, x) for a, x in dirs if x != 0]
    if not signed or signed[0][0] > 15: return None
    new = signed[0][1]
    for k, (a, x) in enumerate(signed):
        if x == -new:
            # the flip is the oldest minute of the new direction after this opposite one
            first_new = signed[k - 1][0]
            return (first_new, new) if first_new <= 15 else None
    return None

DEFS = [("s10", 10, 0.3), ("s10", 10, 0.5), ("tr20", TREND_W, 0.3), ("tr20", TREND_W, 0.5)]
pts = []
for slot in range(T[0] - T[0] % 300 + 300, T[-1] - 3600, 300):
    i = bisect.bisect_right(T, slot) - 1
    if i < 0 or slot - T[i] >= 60: continue
    t = T[i]
    tr = slope(window(t, TREND_W))
    if tr is None: continue
    act = {h: at(t + h * 60) for h in H}
    if None in act.values(): continue
    s5 = slope(window(t, 5), span=3)
    j = bisect.bisect_right(meals, t) - 1
    rev = {f"{n} D{D}": flip_age(t, m, D) for n, m, D in DEFS}
    pts.append(dict(t=t, g=G[t], tr=tr, s5=s5, act=act, day=perth_day(t), rev=rev,
                    meal=j >= 0 and t - meals[j] < 3 * 3600,
                    # §45's rises-only easing would already act here (rise weaker over the last 5 min)
                    s45=tr > 0 and s5 is not None and s5 < tr))
days = sorted({p["day"] for p in pts})

def q(xs, f):
    xs = sorted(xs); i = f * (len(xs) - 1); lo = int(i)
    return xs[lo] + (xs[min(lo + 1, len(xs) - 1)] - xs[lo]) * (i - lo)

def ships(p, h, gain): return line(p["g"], p["tr"], gain)[h]
def s45(p, h, gain):
    tr = p["tr"]
    if p["s45"]: tr = tr * max(p["s5"] / tr, 0)
    return line(p["g"], tr, gain)[h]
def iscore(a, lo, hi): return (hi - lo) + 10 * max(0, lo - a) + 10 * max(0, a - hi)

print(f"{len(pts)} forecast points over {len(days)} Perth days ({days[0]}–{days[-1]} Nov), "
      f"{sum(p['meal'] for p in pts)} within 3 h of a meal")

# 1. How much worse just after a reversal?
print("\n== Error just after a reversal vs the rest (gain 0.6; no change / ships / §45 rises-only; band coverage)")
gain = 0.6
for key in [f"{n} D{D}" for n, _, D in DEFS]:
    rv = [p for p in pts if p["rev"][key] is not None]
    rest = [p for p in pts if p["rev"][key] is None]
    print(f"-- {key}: {len(rv)} reversal points on {len({p['day'] for p in rv})} days "
          f"({sum(p['rev'][key][1] > 0 for p in rv)} now rising, {sum(p['rev'][key][1] < 0 for p in rv)} now falling); "
          f"§45 already eases {sum(p['s45'] for p in rv)}; engine trend still the old way on "
          f"{sum(p['tr'] * p['rev'][key][1] < 0 for p in rv)}")
    for h in H:
        # one band from every point (no hold-out needed for the split)
        res = [p["act"][h] - ships(p, h, gain) for p in pts]
        lo, hi = q(res, .1), q(res, .9)
        def cells(s):
            return (f"{st.mean(abs(p['act'][h] - p['g']) for p in s):5.1f} / {st.mean(abs(p['act'][h] - ships(p, h, gain)) for p in s):5.1f} / "
                    f"{st.mean(abs(p['act'][h] - s45(p, h, gain)) for p in s):5.1f}; in "
                    f"{100 * st.mean(lo <= p['act'][h] - ships(p, h, gain) <= hi for p in s):3.0f}%")
        print(f"   {h:2d} min  reversal: {cells(rv)}   rest: {cells(rest)}")
    for h in (30, 60):
        for side in (1, -1):
            s = [p for p in rv if p["rev"][key][1] == side]
            if s:
                print(f"   {h:2d} min  now {'rising' if side > 0 else 'falling'} n={len(s):3d}: ships {st.mean(abs(p['act'][h] - ships(p, h, gain)) for p in s):5.1f}, "
                      f"bias (actual - ships) {st.mean(p['act'][h] - ships(p, h, gain) for p in s):+5.1f}")
    by_age = {}
    for p in rv: by_age.setdefault(min(p["rev"][key][0] // 5, 2), []).append(p)
    print("   by minutes since the flip (30 min ships / no change): " + ", ".join(
        f"{a * 5}-{a * 5 + 4 if a < 2 else 15}: {st.mean(abs(p['act'][30] - ships(p, 30, gain)) for p in s):4.1f}/"
        f"{st.mean(abs(p['act'][30] - p['g']) for p in s):4.1f} (n={len(s)})" for a, s in sorted(by_age.items())))

# 2. Held-out fixes.
WS = (1.0, 0.75, 0.5, 0.25, 0.0)
KS = (1.0, 1.15, 1.3, 1.5, 1.75, 2.0)
WINS = (5, 10, 15)
def damp_pred(p, key, w, W, side, h, gain):
    r = p["rev"][key]
    tr = p["tr"]
    if r is not None and r[0] <= W and not (side == "rises" and tr < 0):
        tr = tr * w
    return line(p["g"], tr, gain)[h]

def fold(key, gain):
    out = {"damp": {}, "damp_r": {}, "widen": {}, "base_is": {}}
    picks = {"damp": [], "damp_r": [], "widen": []}
    for day in days:
        tr_ = [p for p in pts if p["day"] != day]; te = [p for p in pts if p["day"] == day]
        for name, side in (("damp", "both"), ("damp_r", "rises")):
            best = min(((w, W) for w in WS for W in WINS),
                       key=lambda c: (sum(abs(p["act"][h] - damp_pred(p, key, c[0], c[1], side, h, gain))
                                          for p in tr_ for h in (30, 60)), -c[0]))
            picks[name].append(best)
            for p in te:
                for h in H: out[name][(p["t"], h)] = abs(p["act"][h] - damp_pred(p, key, *best, side, h, gain))
        band = {h: (q([p["act"][h] - ships(p, h, gain) for p in tr_], .1),
                    q([p["act"][h] - ships(p, h, gain) for p in tr_], .9)) for h in H}
        def isc(p, h, k, W):
            c = ships(p, h, gain); lo, hi = band[h]
            r = p["rev"][key]
            if r is None or r[0] > W: k = 1.0
            return iscore(p["act"][h], c + k * lo, c + k * hi)
        best = min(((k, W) for k in KS for W in WINS),
                   key=lambda c: (sum(isc(p, h, *c) for p in tr_ for h in (30, 60)), c[0]))
        picks["widen"].append(best)
        for p in te:
            for h in H:
                out["widen"][(p["t"], h)] = isc(p, h, *best)
                out["base_is"][(p["t"], h)] = isc(p, h, 1.0, 0)
    return out, picks

print("\n== Held out (leave one Perth day out); objective = miss at 30 + 60 min")
results = {}
for key in [f"{n} D{D}" for n, _, D in DEFS]:
    for gain in GAINS:
        out, picks = fold(key, gain)
        results[(key, gain)] = out
        print(f"-- {key}, gain {gain}: picks damp (w, W) {picks['damp']}, rises-only {picks['damp_r']}, widen (k, W) {picks['widen']}")
        for label, sel in (("all", lambda p: True), ("reversal", lambda p: p["rev"][key] is not None)):
            s = [p for p in pts if sel(p)]
            line_ = []
            for h in (30, 60):
                b = st.mean(abs(p["act"][h] - ships(p, h, gain)) for p in s)
                dmp = st.mean(out["damp"][(p["t"], h)] for p in s)
                dr = st.mean(out["damp_r"][(p["t"], h)] for p in s)
                bi = st.mean(out["base_is"][(p["t"], h)] for p in s)
                wi = st.mean(out["widen"][(p["t"], h)] for p in s)
                line_.append(f"{h}: ships {b:5.1f}, damp {dmp:5.1f} ({(dmp / b - 1) * 100:+5.1f}%), rises-only {dr:5.1f} "
                             f"({(dr / b - 1) * 100:+5.1f}%), score {bi:6.1f} -> widen {wi:6.1f} ({(wi / bi - 1) * 100:+5.1f}%)")
            print(f"   {label:9s} n={len(s):4d}  " + "  |  ".join(line_))
        # days better at 30 and 60 for the damping
        better = {h: sum(st.mean(out["damp"][(p["t"], h)] for p in pts if p["day"] == dd) <
                         st.mean(abs(p["act"][h] - ships(p, h, gain)) for p in pts if p["day"] == dd) for dd in days) for h in (30, 60)}
        print(f"   damp: held-out days better overall at 30 / 60: {better[30]} / {better[60]} of {len(days)}")

# 3. Fixed settings, all days, for the record.
print("\n== Fixed settings, gain 0.6, all days (miss at 30 / 60 on reversal points, all points)")
for key in ("s10 D0.3", "tr20 D0.3"):
    rv = [p for p in pts if p["rev"][key] is not None]
    for w in WS:
        for W in (5, 15):
            a = [st.mean(abs(p["act"][h] - damp_pred(p, key, w, W, "both", h, .6)) for p in rv) for h in (30, 60)]
            b = [st.mean(abs(p["act"][h] - damp_pred(p, key, w, W, "both", h, .6)) for p in pts) for h in (30, 60)]
            print(f"   {key} w={w:4.2f} W={W:2d}: reversal {a[0]:5.2f} / {a[1]:5.2f}   all {b[0]:5.2f} / {b[1]:5.2f}")

# 4. Low warnings for damping both sides at full strength (worst case for lows), at every reading.
lows, below = [], False
for t, g in R:
    if g < 70 and not below and (not lows or t - lows[-1] > 3600): lows.append(t)
    below = g < 70
def warn(t, key_def, w, W, gain):
    if t not in G: return False
    tr = slope(window(t, TREND_W))
    if tr is None: return False
    if key_def is not None:
        n, m, D = key_def
        r = flip_age(t, m, D)
        if r is not None and r[0] <= W: tr *= w
    return min(line(G[t], tr, gain, 30).values()) < 70
def first_warning(low, *a):
    for t in T[bisect.bisect_left(T, low - 90 * 60):bisect.bisect_right(T, low)]:
        if G[t] >= 70 and warn(t, *a): return (low - t) / 60
    return 0.0
print(f"\n== Low warnings: {len(lows)} lows under 70; minutes of warning from the trend carried 30 min")
for gain in GAINS:
    for n, m, D in DEFS[:1] + DEFS[2:3]:
        for w, W in ((0.5, 15), (0.0, 15)):
            ws = [(first_warning(l, None, 1, 0, gain), first_warning(l, (n, m, D), w, W, gain)) for l in lows]
            later = [(dt.datetime.fromtimestamp(l + 8 * 3600, dt.UTC).strftime("%d %H:%M"), a, b)
                     for l, (a, b) in zip(lows, ws) if b < a]
            print(f"   gain {gain} {n} D{D} w={w} W={W}: later on {len(later)} {later}")
