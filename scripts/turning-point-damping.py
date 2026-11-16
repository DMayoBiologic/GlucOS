#!/usr/bin/env python3
"""Should the trend ease off when the last few minutes already disagree with it? (ForecastAccuracy.md §45)

Usage: python3 scripts/turning-point-damping.py DIR
DIR holds readings.json ([[unix, mgdl], ...], live readings only, one a minute, from glucos.readings
where trend > 0) and logs.json ([[unix, "meal"], ...] from glucos.logbook), as for
scripts/acceleration-trend.py (§39).

Replays the engine's trend forecast (20-minute least-squares slope, 30-minute fade, minute
midpoint integration) every 5 minutes and scores it at 15 and 30 minutes, at the gains the tuner
has fitted on each device (about 0.45 on the Mac and relay, 0.6 overall, 0.7 on the iPhone).

The candidate looks for an early sign of a turn: the slope of only the last S minutes, s, against
the 20-minute trend, tr. When s is weaker than tr in the same direction, or already the other way
(ρ = s / tr < 1), the trend is scaled by 1 − k·(1 − max(ρ, floor)), so k = 1 with floor 0 counts
the short slope instead of the long one when it's weaker, and never flips the sign. A trend
speeding up (ρ > 1) is left alone (that was §39). The `side` option applies it to rises only
("peaks"), falls only ("troughs"), both, or "guarded": rises, and falls only while the un-eased
line stays at or above GUARD at 30 minutes, so no low warning can move. S, k, floor and side are
picked on five Perth days and scored on the sixth.

Coverage uses one band for every method: the 10th to 90th percentile of what ships' misses on the
training days, at each horizon, laid around each line. Then low warnings, as in §39: every reading
in the 90 minutes before each low under 70, when did the trend carried 30 minutes first go under 70,
and how many warnings had no reading under 70 in the next 45 minutes.
"""
import bisect, datetime as dt, itertools, json, statistics as st, sys

d = sys.argv[1]
R = json.load(open(f"{d}/readings.json"))
L = json.load(open(f"{d}/logs.json"))
T = [r[0] for r in R]
G = {r[0]: r[1] for r in R}
meals = sorted(t for t, k in L if k == "meal")
FADE, TREND_W, MAX = 30.0, 20, 4.0
GAINS = (0.45, 0.6, 0.7)

def window(t, minutes):
    i, j = bisect.bisect_left(T, t - minutes * 60), bisect.bisect_right(T, t)
    return [((T[k] - t) / 60, R[k][1]) for k in range(i, j)]

def slope(pts, span=9):
    if len(pts) < 3 or pts[-1][0] - pts[0][0] < span: return None
    mx = st.mean(p[0] for p in pts); my = st.mean(p[1] for p in pts)
    sxx = sum((p[0] - mx) ** 2 for p in pts)
    return max(-MAX, min(MAX, sum((p[0] - mx) * (p[1] - my) for p in pts) / sxx)) if sxx else None

GUARD = 85  # "guarded": a fall is eased only while the un-eased line stays at or above this at 30 min

def damped(tr, short, prm, g=None, gain=None):
    S, k, floor, side = prm
    if k == 0 or short is None or tr == 0: return tr
    if side == "peaks" and tr < 0: return tr
    if side == "troughs" and tr > 0: return tr
    # 15 = the fade's weight summed over 30 minutes, so this is the un-eased line at 30 minutes.
    if side == "guarded" and tr < 0 and g + 15 * gain * tr < GUARD: return tr
    rho = short / tr
    if rho >= 1: return tr
    return tr * (1 - k * (1 - max(rho, floor)))

def line(g, trend, gain, minutes=30):
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

SHORTS = (5, 8, 10)
pts = []
for slot in range(T[0] - T[0] % 300 + 300, T[-1] - 1800, 300):
    # Issued at the latest reading in each 5-minute slot (readings land at any second).
    i = bisect.bisect_right(T, slot) - 1
    if i < 0 or slot - T[i] >= 60: continue
    t = T[i]
    tr = slope(window(t, TREND_W))
    if tr is None: continue
    sh = {S: slope(window(t, S), span=S - 2) for S in SHORTS}
    act = {h: at(t + h * 60) for h in (15, 30)}
    if None in act.values(): continue
    tr_later = slope(window(t + 900, TREND_W))
    i = bisect.bisect_right(meals, t) - 1
    pts.append(dict(t=t, g=G[t], tr=tr, sh=sh, act=act, day=perth_day(t),
                    meal=i >= 0 and t - meals[i] < 3 * 3600,
                    turning=tr_later is not None and abs(tr) >= 0.5 and tr * tr_later < 0,
                    peak=tr_later is not None and tr >= 0.5 and tr_later < 0,
                    trough=tr_later is not None and tr <= -0.5 and tr_later > 0))
days = sorted({p["day"] for p in pts})
GRID = [(S, k, f, side) for S in SHORTS for k in (.25, .5, .75, 1.0) for f in (0.0, -0.5)
        for side in ("both", "peaks", "troughs", "guarded")]
SAFE = [prm for prm in GRID if prm[3] in ("peaks", "guarded")]
BASE = (5, 0, 0.0, "both")

cache = {}
def pred(p, prm, h, gain):
    key = (p["t"], prm, h, gain)
    if key not in cache:
        cache[key] = line(p["g"], damped(p["tr"], p["sh"][prm[0]], prm, p["g"], gain), gain)[h]
    return cache[key]
def err(p, prm, h, gain): return abs(pred(p, prm, h, gain) - p["act"][h])

def q(xs, f):
    xs = sorted(xs); i = f * (len(xs) - 1); lo = int(i)
    return xs[lo] + (xs[min(lo + 1, len(xs) - 1)] - xs[lo]) * (i - lo)

print(f"{len(pts)} forecast points over {len(days)} Perth days ({days[0]}–{days[-1]} Nov); "
      f"{sum(p['turning'] for p in pts)} at turning points ({sum(p['peak'] for p in pts)} peaks, "
      f"{sum(p['trough'] for p in pts)} troughs), {sum(p['meal'] for p in pts)} within 3 h of a meal")

for label, grid, gain in [("any side", GRID, g) for g in GAINS] + [("peaks or guarded only", SAFE, g) for g in GAINS]:
    held, inside_b, inside_c, picks = {}, {}, {}, []
    for day in days:
        tr = [p for p in pts if p["day"] != day]; te = [p for p in pts if p["day"] == day]
        best = min(grid, key=lambda prm: sum(err(p, prm, 15, gain) + err(p, prm, 30, gain) for p in tr))
        picks.append((day, best))
        band = {h: (q([p["act"][h] - pred(p, BASE, h, gain) for p in tr], .1),
                    q([p["act"][h] - pred(p, BASE, h, gain) for p in tr], .9)) for h in (15, 30)}
        for p in te:
            for h in (15, 30):
                held[(p["t"], h)] = (err(p, best, h, gain), pred(p, best, h, gain))
                lo, up = band[h]
                inside_b[(p["t"], h)] = lo <= p["act"][h] - pred(p, BASE, h, gain) <= up
                inside_c[(p["t"], h)] = lo <= p["act"][h] - pred(p, best, h, gain) <= up
    print(f"\n=== {label}, gain {gain}: picks (S, k, floor, side) by held-out day:")
    print("   " + ", ".join(f"{d}:{b}" for d, b in picks))

    def row(name, sel):
        s = [p for p in pts if sel(p)]
        if not s: return
        cells = []
        for h in (15, 30):
            nc = st.mean(abs(p["act"][h] - p["g"]) for p in s)
            b = st.mean(err(p, BASE, h, gain) for p in s)
            c = st.mean(held[(p["t"], h)][0] for p in s)
            cb = 100 * st.mean(inside_b[(p["t"], h)] for p in s)
            cc = 100 * st.mean(inside_c[(p["t"], h)] for p in s)
            cells.append(f"{nc:5.1f} {b:5.1f} {c:5.1f}  in {cb:4.1f}%→{cc:4.1f}%")
        print(f"{name:24s} n={len(s):4d}  15: nochg/ships/damped {cells[0]}  | 30: {cells[1]}")
    row("all", lambda p: True)
    row("quiet (no meal in 3 h)", lambda p: not p["meal"])
    row("within 3 h of a meal", lambda p: p["meal"])
    row("turning points", lambda p: p["turning"])
    row("  peaks", lambda p: p["peak"])
    row("  troughs", lambda p: p["trough"])
    row("falling (trend < -1)", lambda p: p["tr"] < -1)
    row("rising (trend > 1)", lambda p: p["tr"] > 1)
    row("first half (11–13 Nov)", lambda p: p["day"] <= "13")
    row("second half (14–16 Nov)", lambda p: p["day"] >= "14")
    for day in days:
        row(f"day {day}", lambda p, d=day: p["day"] == d)

print("\nfixed settings, gain 0.6, all days (no hold-out): miss 15 / 30, turning 15 / 30")
for prm in [BASE] + [(S, k, f, side) for S in (5, 8, 10) for k in (.5, 1.0) for f in (0.0,)
                     for side in ("both", "peaks", "troughs")]:
    print(f"  {str(prm):26s} {st.mean(err(p, prm, 15, .6) for p in pts):5.2f} "
          f"{st.mean(err(p, prm, 30, .6) for p in pts):5.2f}   turning "
          f"{st.mean(err(p, prm, 15, .6) for p in pts if p['turning']):5.2f} "
          f"{st.mean(err(p, prm, 30, .6) for p in pts if p['turning']):5.2f}")

# Low warnings, at every reading.
lows, below = [], False
for t, g in R:
    if g < 70 and not below and (not lows or t - lows[-1] > 3600): lows.append(t)
    below = g < 70
wcache = {}
def warn_at(t, prm, gain):
    key = (t, prm, gain)
    if key in wcache: return wcache[key]
    out = False
    if t in G:
        tr = slope(window(t, TREND_W))
        if tr is not None:
            S = prm[0]
            tr = damped(tr, slope(window(t, S), span=S - 2), prm, G[t], gain)
            out = min(line(G[t], tr, gain).values()) < 70
    wcache[key] = out
    return out
def first_warning(low, prm, gain):
    for t in T[bisect.bisect_left(T, low - 90 * 60):bisect.bisect_right(T, low)]:
        if G[t] >= 70 and warn_at(t, prm, gain): return (low - t) / 60
    return 0.0
CANDS = [BASE, (5, 1.0, 0.0, "both"), (5, 1.0, -0.5, "both"), (5, 1.0, 0.0, "peaks"), (5, 1.0, -0.5, "peaks"),
         (5, 1.0, 0.0, "guarded"), (5, 1.0, -0.5, "guarded")]
for gain in GAINS:
    print(f"\ngain {gain}: {len(lows)} lows under 70 (an hour apart), minutes of warning from the trend carried 30 min")
    print("low (Perth)    " + " ".join(f"{str(c):>24s}" for c in CANDS))
    for low in lows:
        ws = [first_warning(low, c, gain) for c in CANDS]
        print(dt.datetime.fromtimestamp(low + 8 * 3600, dt.UTC).strftime("%d %b %H:%M") + "   " +
              " ".join(f"{w:24.0f}" for w in ws))
    for c in CANDS:
        fa = n = 0; prev = False
        for t in T[bisect.bisect_left(T, T[0] + 1200):bisect.bisect_right(T, T[-1] - 2700)]:
            w = G[t] >= 70 and warn_at(t, c, gain)
            if w and not prev:
                n += 1
                if min((g for _, g in R[bisect.bisect_left(T, t):bisect.bisect_right(T, t + 2700)]), default=999) >= 70: fa += 1
            prev = w
        print(f"  {str(c):26s} warnings {n:3d}, false alarms {fa:3d}")

# High warnings, the same way: easing a rise can only lower the line, so it can make a predicted
# high later or drop a false one, never the other way. Highs over 180, an hour apart.
HIGH = 180
highs, above = [], False
for t, g in R:
    if g > HIGH and not above and (not highs or t - highs[-1] > 3600): highs.append(t)
    above = g > HIGH
hcache = {}
def hwarn_at(t, prm, gain):
    key = (t, prm, gain)
    if key in hcache: return hcache[key]
    out = False
    tr = slope(window(t, TREND_W))
    if tr is not None:
        S = prm[0]
        tr = damped(tr, slope(window(t, S), span=S - 2), prm, G[t], gain)
        out = max(line(G[t], tr, gain).values()) > HIGH
    hcache[key] = out
    return out
HCANDS = [BASE, (5, 1.0, 0.0, "peaks"), (5, 0.75, 0.0, "peaks"), (5, 1.0, 0.0, "both")]
for gain in GAINS:
    print(f"\ngain {gain}: {len(highs)} highs over {HIGH}; minutes of warning from the trend carried 30 min "
          f"(median, how many got none, how many came later than what ships)")
    base_w = [next(((h - t) / 60 for t in T[bisect.bisect_left(T, h - 5400):bisect.bisect_right(T, h)]
                    if G[t] <= HIGH and hwarn_at(t, BASE, gain)), 0.0) for h in highs]
    for c in HCANDS:
        ws = [next(((h - t) / 60 for t in T[bisect.bisect_left(T, h - 5400):bisect.bisect_right(T, h)]
                    if G[t] <= HIGH and hwarn_at(t, c, gain)), 0.0) for h in highs]
        later = [(dt.datetime.fromtimestamp(h + 8 * 3600, dt.UTC).strftime("%d %H:%M"), b, w)
                 for h, b, w in zip(highs, base_w, ws) if w < b]
        fa = n = 0; prev = False
        for t in T[bisect.bisect_left(T, T[0] + 1200):bisect.bisect_right(T, T[-1] - 2700)]:
            w = G[t] <= HIGH and hwarn_at(t, c, gain)
            if w and not prev:
                n += 1
                if max((g for _, g in R[bisect.bisect_left(T, t):bisect.bisect_right(T, t + 2700)]), default=0) <= HIGH: fa += 1
            prev = w
        print(f"  {str(c):26s} median {st.median(ws):4.0f} min, none {sum(w == 0 for w in ws)}, "
              f"later {len(later)} {later[:6]}; warnings {n}, false alarms {fa}")
