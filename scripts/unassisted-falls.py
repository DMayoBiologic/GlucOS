#!/usr/bin/env python3
"""Are forecasts worse while glucose falls back from above range with no insulin logged, and would
damping the trend there help? (ForecastAccuracy.md §82)

Usage: python3 scripts/unassisted-falls.py DIR
DIR holds readings.json ([[unix, mgdl], ...], live readings only, from glucos.readings where
trend > 0) and logs.json ([[unix, "meal" | "dose"], ...], meals and rapid doses from
glucos.logbook), as for scripts/turning-points.py (§71).

Replays the engine's trend forecast (20-minute least-squares slope clamped at ±4, 30-minute fade,
minute midpoint integration) every 5 minutes, issued at the latest reading in each 5-minute slot,
and scores it at 15, 30 and 60 minutes at the gains the tuner fits (0.45 Mac/relay, 0.6, 0.7 iPhone).

Groups, judged only from what the app has at issue time:
  fall          engine trend <= -1 mg/dL a minute
  from high     a fall with a reading above 180 in the last 60 minutes and the latest reading >= 120
  unassisted    from high, no rapid dose logged in the 3 hours before issue
  dosed         from high, a rapid dose in the 3 hours before issue
  other falls   every fall that isn't from high

Tweak, fitted on six Perth days and scored on the seventh (objective: miss at 30 + 60 minutes):
the trend of unassisted falls from high is scaled by w (1 = as ships; under 1 damps the fall,
over 1 steepens it). Every other forecast is left alone.
Ship bar: better held out at both 30 and 60 minutes on most days, at every gain, and no low
warning later and lows not forecast higher.
"""
import bisect, datetime as dt, json, statistics as st, sys

d = sys.argv[1]
R = json.load(open(f"{d}/readings.json"))
L = json.load(open(f"{d}/logs.json"))
T = [r[0] for r in R]
G = {r[0]: r[1] for r in R}
meals = sorted(t for t, k in L if k == "meal")
doses = sorted(t for t, k in L if k == "dose")
FADE, TREND_W, MAX = 30.0, 20, 4.0
GAINS = (0.45, 0.6, 0.7)
H = (15, 30, 60)
WS = (0.25, 0.4, 0.55, 0.7, 0.85, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0)

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

def at(t, tol=90):
    i = bisect.bisect_left(T, t)
    best = min((j for j in (i - 1, i) if 0 <= j < len(T)), key=lambda j: abs(T[j] - t), default=None)
    return R[best][1] if best is not None and abs(T[best] - t) <= tol else None

def perth(t, f="%d"): return dt.datetime.fromtimestamp(t + 8 * 3600, dt.UTC).strftime(f)

def recent(xs, t, secs):
    j = bisect.bisect_right(xs, t) - 1
    return j >= 0 and t - xs[j] < secs

def group(t, g, tr):
    if tr > -1: return None
    peak = max(v for _, v in window(t, 60))
    if peak > 180 and g >= 120:
        return "dosed" if recent(doses, t, 3 * 3600) else "unassisted"
    return "other"

pts = []
for slot in range(T[0] - T[0] % 300 + 300, T[-1] - 3600, 300):
    i = bisect.bisect_right(T, slot) - 1
    if i < 0 or slot - T[i] >= 60: continue
    t = T[i]
    tr = slope(window(t, TREND_W))
    if tr is None: continue
    act = {h: at(t + h * 60, 120) for h in H}
    if None in act.values(): continue
    pts.append(dict(t=t, g=G[t], tr=tr, act=act, day=perth(t), grp=group(t, G[t], tr),
                    meal=recent(meals, t, 3 * 3600)))
days = sorted({p["day"] for p in pts})

def pred(p, h, gain, w=1.0):
    tr = p["tr"] * (w if p["grp"] == "unassisted" else 1)
    return line(p["g"], tr, gain)[h]

def mae(s, h, f): return st.mean(abs(p["act"][h] - f(p)) for p in s)

print(f"{len(pts)} forecast points over {len(days)} Perth days ({days[0]}–{days[-1]} Nov)")
for k in ("unassisted", "dosed", "other"):
    s = [p for p in pts if p["grp"] == k]
    eps = sorted({perth(p["t"], "%d %H") for p in s})
    print(f"   {k:10s} {len(s):4d} points, {len({p['day'] for p in s})} days, "
          f"{sum(p['meal'] for p in s)} within 3 h of a meal, mean start {st.mean(p['g'] for p in s):.0f}, "
          f"mean trend {st.mean(p['tr'] for p in s):+.2f}; hours: {len(eps)}")

# 1. Error and bias by group.
print("\n== Miss by group: no change / ships (bias = actual - ships)")
for gain in GAINS:
    print(f"-- gain {gain}")
    for k in ("unassisted", "dosed", "other"):
        s = [p for p in pts if p["grp"] == k]
        print(f"   {k:10s} " + "  ".join(
            f"{h}: {mae(s, h, lambda p: p['g']):5.1f} / {mae(s, h, lambda p: pred(p, h, gain)):5.1f} "
            f"({st.mean(p['act'][h] - pred(p, h, gain) for p in s):+5.1f})" for h in H))

print("\n== Unassisted falls by Perth day, gain 0.45: n, bias 30 / 60, actual 60 min - start")
ua = [p for p in pts if p["grp"] == "unassisted"]
for dd in days:
    s = [p for p in ua if p["day"] == dd]
    if s:
        print(f"   {dd} Nov: {len(s):3d}  {st.mean(p['act'][30] - pred(p, 30, .45) for p in s):+6.1f} / "
              f"{st.mean(p['act'][60] - pred(p, 60, .45) for p in s):+6.1f}   "
              f"{st.mean(p['act'][60] - p['g'] for p in s):+6.1f}")

# 2. Held out trend scale on unassisted falls.
print("\n== Held out (leave one Perth day out): trend x w on unassisted falls from high")
for gain in GAINS:
    held, picks = {}, {}
    for dd in days:
        tr_ = [p for p in ua if p["day"] != dd]
        w = min(WS, key=lambda w: (sum(abs(p["act"][h] - pred(p, h, gain, w)) for p in tr_ for h in (30, 60)),
                                   abs(w - 1)))
        picks[dd] = w
        for p in pts:
            if p["day"] == dd:
                for h in H: held[(p["t"], h)] = abs(p["act"][h] - pred(p, h, gain, w))
    print(f"-- gain {gain}: picks " + ", ".join(f"{k}:{v}" for k, v in picks.items()))
    for h in H:
        b = mae(pts, h, lambda p: pred(p, h, gain)); a = st.mean(held[(p["t"], h)] for p in pts)
        bu = mae(ua, h, lambda p: pred(p, h, gain)); au = st.mean(held[(p["t"], h)] for p in ua)
        ud = [dd for dd in days if any(p["day"] == dd for p in ua)]
        better = sum(st.mean(held[(p["t"], h)] for p in ua if p["day"] == dd)
                     < mae([p for p in ua if p["day"] == dd], h, lambda p: pred(p, h, gain)) - 1e-9 for dd in ud)
        worse = sum(st.mean(held[(p["t"], h)] for p in ua if p["day"] == dd)
                    > mae([p for p in ua if p["day"] == dd], h, lambda p: pred(p, h, gain)) + 1e-9 for dd in ud)
        print(f"   {h:2d} min  all {b:6.2f} -> {a:6.2f} ({(a / b - 1) * 100:+5.2f}%)   unassisted {bu:5.1f} -> {au:5.1f}"
              f"   days better/worse {better}/{worse} of {len(ud)}")

print("\n== Fixed w on unassisted falls, all days, gain 0.45: miss 15 / 30 / 60 on those points")
for w in WS:
    print(f"   w={w:4}: " + " / ".join(f"{mae(ua, h, lambda p: pred(p, h, .45, w)):5.1f}" for h in H))

# 3. Lows: does damping make any low warning later, and are lows forecast higher?
lows, below = [], False
for t, g in R:
    if g < 70 and not below and (not lows or t - lows[-1] > 3600): lows.append(t)
    below = g < 70
def warn(t, w, gain):
    tr = slope(window(t, TREND_W))
    if tr is None: return False
    if group(t, G[t], tr) == "unassisted": tr *= w
    return min(line(G[t], tr, gain, 30).values()) < 70
def first_warning(low, w, gain):
    for t in T[bisect.bisect_left(T, low - 90 * 60):bisect.bisect_right(T, low)]:
        if G[t] >= 70 and warn(t, w, gain): return (low - t) / 60
    return 0.0
lo = [p for p in pts if p["act"][30] < 80]
ulo = [p for p in ua if min(p["act"].values()) < 80]
print(f"\n== Lows: {len(lows)} under 70; {len(lo)} points with the 30-min actual under 80; "
      f"{len(ulo)} unassisted points ending under 80 at some horizon")
for gain in GAINS:
    for w in (0.55, 0.7, 0.85, 1.15, 1.5):
        later = [(perth(l, "%d %H:%M"), first_warning(l, 1, gain), first_warning(l, w, gain)) for l in lows]
        later = [x for x in later if x[2] < x[1]]
        b0 = st.mean(p["act"][30] - pred(p, 30, gain) for p in lo)
        b1 = st.mean(p["act"][30] - pred(p, 30, gain, w) for p in lo)
        print(f"   gain {gain} w={w}: warnings later on {len(later)} {later}; bias under 80 {b0:+.1f} -> {b1:+.1f}")
