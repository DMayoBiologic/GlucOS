#!/usr/bin/env python3
"""Do forecasts run high or low into a fast fall inside the target range, and does the predicted-low
warning come early enough? (ForecastAccuracy.md §100)

Usage: python3 scripts/fast-falls-in-range.py DIR
DIR holds readings.json ([[unix, mgdl], ...], live readings only, from glucos.readings where
trend > 0) and logs.json ([[unix, "meal" | "dose"], ...], meals and rapid doses from
glucos.logbook), as for scripts/unassisted-falls.py (§82).

Replays the engine's trend forecast (20-minute least-squares slope clamped at ±4, 30-minute fade,
minute midpoint integration) every 5 minutes, issued at the latest reading in each 5-minute slot,
and scores it at 15, 30 and 60 minutes at the gains the tuner fits (0.45 Mac/relay, 0.6, 0.7 iPhone).

Groups, judged only from what the app has at issue time (start = latest reading):
  fast       start 70-180 and engine trend < -2 mg/dL a minute
  moderate   start 70-180 and trend -2 to -1
  other      everything else (shown for reference)
Fast falls are split by "from high" (a reading above 180 in the 60 minutes before, §82's group)
and by a rapid dose in the 3 hours before.

Predicted-low warning lead: for each low (first reading under 70, an hour apart), the first live
reading in the 90 minutes before where the trend is <= -0.3 and the line (gain x trend, faded,
carried to 30 minutes, as PredictiveAlerts reads lowLookahead) goes under 70. Lows whose run-in
had a fast in-range fall in the 45 minutes before are reported apart. False alarms: warnings on
fast falls with no reading under 70 in the next 45 minutes (one per 45-minute window).

Tweak, fitted on all but one Perth day and scored on the left-out day (objective: miss at 30 +
60 minutes on fast falls): the trend of fast in-range falls is scaled by w (1 = as ships).
Every other forecast is left alone. Ship bar: better held out at both 30 and 60 minutes on most
days at every gain, no low warning later, no more false alarms.
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
WS = (0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.35, 1.5, 1.75, 2.0)


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


def group(g, tr):
    if 70 <= g <= 180 and tr < -2: return "fast"
    if 70 <= g <= 180 and tr <= -1: return "moderate"
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
    pts.append(dict(t=t, g=G[t], tr=tr, act=act, day=perth(t), grp=group(G[t], tr),
                    high=max(v for _, v in window(t, 60)) > 180, dose=recent(doses, t, 3 * 3600),
                    meal=recent(meals, t, 3 * 3600)))
days = sorted({p["day"] for p in pts})
fast = [p for p in pts if p["grp"] == "fast"]


def pred(p, h, gain, w=1.0):
    return line(p["g"], p["tr"] * (w if p["grp"] == "fast" else 1), gain)[h]


def mae(s, h, f): return st.mean(abs(p["act"][h] - f(p)) for p in s)


print(f"{len(pts)} forecast points over {len(days)} Perth days ({days[0]}–{days[-1]} Nov)")
for k in ("fast", "moderate", "other"):
    s = [p for p in pts if p["grp"] == k]
    print(f"   {k:8s} {len(s):5d} points, {len({p['day'] for p in s})} days, {len({perth(p['t'], '%d %H') for p in s})} hours, "
          f"mean start {st.mean(p['g'] for p in s):.0f}, mean trend {st.mean(p['tr'] for p in s):+.2f}, "
          f"from high {sum(p['high'] for p in s)}, dose 3 h {sum(p['dose'] for p in s)}, meal 3 h {sum(p['meal'] for p in s)}")

# 1. Error and bias by group.
print("\n== Miss by group: no change / ships (bias = actual - ships; + = line ran low, - = line ran high)")
for gain in GAINS:
    print(f"-- gain {gain}")
    for k in ("fast", "moderate", "other"):
        s = [p for p in pts if p["grp"] == k]
        print(f"   {k:8s} " + "  ".join(
            f"{h}: {mae(s, h, lambda p: p['g']):5.1f} / {mae(s, h, lambda p: pred(p, h, gain)):5.1f} "
            f"({st.mean(p['act'][h] - pred(p, h, gain) for p in s):+5.1f})" for h in H))

print("\n== Fast falls split, gain 0.45: n, bias 15 / 30 / 60, actual change 30 / 60, share under 70 at 30")
for name, f in (("from high", lambda p: p["high"]), ("not from high", lambda p: not p["high"]),
                ("dose 3 h", lambda p: p["dose"]), ("no dose 3 h", lambda p: not p["dose"]),
                ("start < 120", lambda p: p["g"] < 120), ("start >= 120", lambda p: p["g"] >= 120),
                ("trend < -3", lambda p: p["tr"] < -3), ("trend -3..-2", lambda p: p["tr"] >= -3)):
    s = [p for p in fast if f(p)]
    if not s: continue
    print(f"   {name:14s} {len(s):3d}  " + " / ".join(f"{st.mean(p['act'][h] - pred(p, h, .45) for p in s):+6.1f}" for h in H)
          + f"   {st.mean(p['act'][30] - p['g'] for p in s):+6.1f} / {st.mean(p['act'][60] - p['g'] for p in s):+6.1f}"
          + f"   {100 * st.mean(p['act'][30] < 70 for p in s):3.0f}%")

print("\n== Fast falls by Perth day, gain 0.45: n, bias 30 / 60")
for dd in days:
    s = [p for p in fast if p["day"] == dd]
    if s:
        print(f"   {dd} Nov: {len(s):3d}  {st.mean(p['act'][30] - pred(p, 30, .45) for p in s):+6.1f} / "
              f"{st.mean(p['act'][60] - pred(p, 60, .45) for p in s):+6.1f}")

# 2. Held out trend scale on fast in-range falls.
print("\n== Held out (leave one Perth day out): trend x w on fast in-range falls")
for gain in GAINS:
    held, picks = {}, {}
    for dd in days:
        tr_ = [p for p in fast if p["day"] != dd]
        w = min(WS, key=lambda w: (sum(abs(p["act"][h] - pred(p, h, gain, w)) for p in tr_ for h in (30, 60)), abs(w - 1)))
        picks[dd] = w
        for p in pts:
            if p["day"] == dd:
                for h in H: held[(p["t"], h)] = abs(p["act"][h] - pred(p, h, gain, w))
    print(f"-- gain {gain}: picks " + ", ".join(f"{k}:{v}" for k, v in picks.items()))
    fd = [dd for dd in days if any(p["day"] == dd for p in fast)]
    for h in H:
        b = mae(pts, h, lambda p: pred(p, h, gain)); a = st.mean(held[(p["t"], h)] for p in pts)
        bf = mae(fast, h, lambda p: pred(p, h, gain)); af = st.mean(held[(p["t"], h)] for p in fast)
        per = [(st.mean(held[(p["t"], h)] for p in fast if p["day"] == dd),
                mae([p for p in fast if p["day"] == dd], h, lambda p: pred(p, h, gain))) for dd in fd]
        print(f"   {h:2d} min  all {b:6.2f} -> {a:6.2f} ({(a / b - 1) * 100:+5.2f}%)   fast {bf:5.1f} -> {af:5.1f} "
              f"({(af / bf - 1) * 100:+5.1f}%)   days better/worse {sum(x < y - 1e-9 for x, y in per)}/"
              f"{sum(x > y + 1e-9 for x, y in per)} of {len(fd)}")

print("\n== Fixed w on fast falls, all days, gain 0.45: miss 15 / 30 / 60 on those points")
for w in WS:
    print(f"   w={w:4}: " + " / ".join(f"{mae(fast, h, lambda p: pred(p, h, .45, w)):5.1f}" for h in H))

# 3. Predicted-low warning lead and false alarms.
lows, below = [], False
for t, g in R:
    if g < 70 and not below and (not lows or t - lows[-1] > 3600): lows.append(t)
    below = g < 70


def warn(t, w, gain):
    tr = slope(window(t, TREND_W))
    if tr is None or tr > -0.3: return False
    if group(G[t], tr) == "fast": tr *= w
    return min(line(G[t], tr, gain, 30).values()) < 70


def first_warning(low, w, gain):
    for t in T[bisect.bisect_left(T, low - 90 * 60):bisect.bisect_right(T, low)]:
        if G[t] >= 70 and warn(t, w, gain): return (low - t) / 60
    return 0.0


def run_in_fast(low):
    for t in T[bisect.bisect_left(T, low - 45 * 60):bisect.bisect_right(T, low)]:
        tr = slope(window(t, TREND_W))
        if tr is not None and group(G[t], tr) == "fast": return True
    return False


def false_alarms(w, gain):
    n, last = 0, -1e18
    for t in T:
        if t - last < 45 * 60: continue
        tr = slope(window(t, TREND_W))
        if tr is None or group(G[t], tr) != "fast" or not warn(t, w, gain): continue
        last = t
        nxt = T[bisect.bisect_left(T, t):bisect.bisect_right(T, t + 45 * 60)]
        n += min(G[x] for x in nxt) >= 70
    return n


def warnings(w, gain):
    n, last = 0, -1e18
    for t in T:
        if t - last < 45 * 60: continue
        tr = slope(window(t, TREND_W))
        if tr is None or group(G[t], tr) != "fast" or not warn(t, w, gain): continue
        last = t; n += 1
    return n


fl = [l for l in lows if run_in_fast(l)]
print(f"\n== Lows: {len(lows)} under 70, {len(fl)} with a fast in-range fall in the 45 min before")
for gain in GAINS:
    for subset, name in ((fl, "fast run-in"), ([l for l in lows if l not in fl], "other lows")):
        leads = [first_warning(l, 1, gain) for l in subset]
        if leads:
            print(f"   gain {gain} {name:11s}: lead min median {st.median(leads):4.1f}, mean {st.mean(leads):4.1f}, "
                  f"unwarned {sum(x == 0 for x in leads)}; " + ", ".join(f"{perth(l, '%d %H:%M')} {x:.0f}" for l, x in zip(subset, leads)))
    print(f"   gain {gain} warnings on fast falls {warnings(1, gain)}, false alarms {false_alarms(1, gain)}")
for gain in GAINS:
    for w in (0.8, 1.2, 1.35, 1.5):
        ch = [(perth(l, "%d %H:%M"), first_warning(l, 1, gain), first_warning(l, w, gain)) for l in lows]
        print(f"   gain {gain} w={w}: later on {sum(b < a for _, a, b in ch)}, earlier on {sum(b > a for _, a, b in ch)}, "
              f"mean lead {st.mean(a for _, a, _ in ch):.1f} -> {st.mean(b for _, _, b in ch):.1f}, "
              f"false alarms {false_alarms(1, gain)} -> {false_alarms(w, gain)}")
