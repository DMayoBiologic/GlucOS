#!/usr/bin/env python3
"""How late do readings arrive, and should "In 30 min ≈ …" allow for it? (ForecastAccuracy.md §47)

Usage: python3 scripts/reading-latency.py DIR
DIR holds readings.json ([[unix, mgdl], ...], live readings only, one a minute, from glucos.readings
where trend > 0), logs.json ([[unix, kind], ...], doses, meals and context from glucos.logbook, the
query in §31), and optionally samples.json ([[reading_t, fetched_at], ...], the relay's
work->'current'->'t' and work->'lastFetchAt' read once a minute).

Every forecast is already drawn from the reading's own time (GlucoseForecaster t0 =
latest.timestamp, relay core.ts the same), so the chart is right however late the reading came.
What isn't: the headline and the Outlook rows pick the point 15, 30 or 60 minutes after the
reading (OutlookSnapshot.sample(minutesAhead:)), and the person reads that at fetch time or later,
when it's really 15 − a, 30 − a or 60 − a minutes away, a being the reading's age. That is the
same as starting the forecast at fetch time. The candidate picks the point at m + a instead
("reading time plus the lag"), so the label means m minutes from when it's read.

Replays the engine's trend forecast (20-minute least-squares slope, 30-minute fade, exact integral
of the minute midpoint rule) every 5 minutes, away from logs (nothing logged from 3 h before to the
target), at the tuner's gains (0.45 Mac/relay, 0.6 overall, 0.7 iPhone). Actuals are interpolated
between readings at the second they're read. Ages tried: 0.5 min (the relay, measured), 1.0 (an app
polling every 60 s at a random second, on average), 1.5 (its worst ordinary case), 3 and 5 (a late
upload, a sleeping widget). Coverage uses the 10th–90th percentile of the shipped label's misses on
the other Perth days, laid around each label. Low check: points whose actual is under 70, and
whether the line or the range bottom was under 70.
"""
import bisect, datetime as dt, json, os, statistics as st, sys

d = sys.argv[1]
R = json.load(open(f"{d}/readings.json"))
L = json.load(open(f"{d}/logs.json"))
T = [r[0] for r in R]
logs = sorted(t for t, _ in L)
FADE, TREND_W, MAX = 30.0, 20, 4.0
GAINS = (0.45, 0.6, 0.7)
AGES = (0.5, 1.0, 1.5, 3.0, 5.0)
HS = (15, 30, 60)

# --- 1. How late readings arrive -------------------------------------------------------------
if os.path.exists(f"{d}/samples.json"):
    S = json.load(open(f"{d}/samples.json"))
    first = {}
    for t, f in S:
        first[t] = min(first.get(t, f), f)
    ages = sorted(f - t for t, f in first.items())
    print(f"Relay: {len(S)} fetches, {len(first)} distinct readings; age when first fetched "
          f"min {ages[0]:.0f} s, median {st.median(ages):.0f} s, max {ages[-1]:.0f} s")
    late = sum(1 for a in ages if a > 60)
    print(f"  first seen more than a minute after its time: {late} of {len(ages)}")
gaps = [b - a for a, b in zip(T, T[1:])]
one = sum(1 for g in gaps if g <= 90)
print(f"Readings: {len(T)} live, {one / len(gaps):.1%} of steps a minute apart; "
      f"missing minutes (step 1.5–6 min): {sum(1 for g in gaps if 90 < g <= 360)}, "
      f"gaps over 6 min: {sum(1 for g in gaps if g > 360)}")

# --- 2. Replay --------------------------------------------------------------------------------
def window(t, minutes):
    i, j = bisect.bisect_left(T, t - minutes * 60), bisect.bisect_right(T, t)
    return [((T[k] - t) / 60, R[k][1]) for k in range(i, j)]

def slope(pts, span=9):
    if len(pts) < 3 or pts[-1][0] - pts[0][0] < span: return None
    mx = st.mean(p[0] for p in pts); my = st.mean(p[1] for p in pts)
    sxx = sum((p[0] - mx) ** 2 for p in pts)
    return max(-MAX, min(MAX, sum((p[0] - mx) * (p[1] - my) for p in pts) / sxx)) if sxx else None

def line(g, tr, gain, u):
    """The trend line u minutes after the reading (rate gain·tr fading to 0 over FADE)."""
    u = min(u, FADE)
    return g + gain * tr * (u - u * u / (2 * FADE))

def actual(t):
    i = bisect.bisect_left(T, t)
    if i == 0 or i >= len(T): return None
    a, b = i - 1, i
    if T[b] - T[a] > 150: return None
    return R[a][1] + (R[b][1] - R[a][1]) * (t - T[a]) / (T[b] - T[a])

def perth_day(t): return dt.datetime.fromtimestamp(t + 8 * 3600, dt.UTC).strftime("%d")

pts = []
for slot in range(T[0] - T[0] % 300 + 300, T[-1] - 3900, 300):
    i = bisect.bisect_right(T, slot) - 1
    if i < 0 or slot - T[i] >= 60: continue
    t = T[i]
    j = bisect.bisect_right(logs, t + 3900) - 1
    if j >= 0 and logs[j] > t - 3 * 3600: continue
    tr = slope(window(t, TREND_W))
    if tr is None: continue
    act = {(h, a): actual(t + (h + a) * 60) for h in HS for a in (0,) + AGES}
    if None in act.values(): continue
    pts.append(dict(t=t, g=R[i][1], tr=tr, act=act, day=perth_day(t)))
days = sorted({p["day"] for p in pts})
print(f"\n{len(pts)} clean forecast points over {len(days)} Perth days ({days[0]}–{days[-1]})")

def q(xs, f):
    xs = sorted(xs); k = f * (len(xs) - 1); lo = int(k)
    return xs[lo] + (xs[min(lo + 1, len(xs) - 1)] - xs[lo]) * (k - lo)

for gain in GAINS:
    print(f"\n=== gain {gain}")
    base0 = {h: st.mean(abs(p["act"][(h, 0)] - line(p["g"], p["tr"], gain, h)) for p in pts) for h in HS}
    print("  read at the reading's own time (a = 0): " +
          ", ".join(f"{h} min {base0[h]:.2f}" for h in HS))
    print("  age | horizon | shipped label | lag-aware | change | inside shipped → lag-aware | days better | lows: line<70 / bottom<70, shipped → lag-aware")
    for a in AGES:
        for h in HS:
            ship = lambda p: line(p["g"], p["tr"], gain, h)
            cand = lambda p: line(p["g"], p["tr"], gain, h + a)
            es = [abs(p["act"][(h, a)] - ship(p)) for p in pts]
            ec = [abs(p["act"][(h, a)] - cand(p)) for p in pts]
            ins_s = ins_c = 0
            better = 0; scored = 0
            for day in days:
                tr_ = [p for p in pts if p["day"] != day]; te = [p for p in pts if p["day"] == day]
                res = [p["act"][(h, a)] - ship(p) for p in tr_]
                lo, up = q(res, .1), q(res, .9)
                for p in te:
                    ins_s += lo <= p["act"][(h, a)] - ship(p) <= up
                    ins_c += lo <= p["act"][(h, a)] - cand(p) <= up
                if len(te) >= 20:
                    scored += 1
                    better += (st.mean(abs(p["act"][(h, a)] - cand(p)) for p in te)
                               < st.mean(abs(p["act"][(h, a)] - ship(p)) for p in te))
                # range bottom for the low check uses this day's band
                for p in te: p[("lo", h, a)] = lo
            lows = [p for p in pts if p["act"][(h, a)] < 70]
            ls = sum(ship(p) < 70 for p in lows); lc = sum(cand(p) < 70 for p in lows)
            bs = sum(ship(p) + p[("lo", h, a)] < 70 for p in lows); bc = sum(cand(p) + p[("lo", h, a)] < 70 for p in lows)
            ms, mc = st.mean(es), st.mean(ec)
            print(f"  {a:>3} | {h:>2} | {ms:6.2f} | {mc:6.2f} | {100 * (mc - ms) / ms:+5.1f}% | "
                  f"{ins_s / len(pts):.1%} → {ins_c / len(pts):.1%} | {better}/{scored} | "
                  f"{len(lows)} lows: {ls}/{bs} → {lc}/{bc}")
