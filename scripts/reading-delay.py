#!/usr/bin/env python3
"""How late do readings arrive, and would a delay offset help the forecast? (ForecastAccuracy.md §67)

Usage: python3 scripts/reading-delay.py DIR
DIR holds readings.json ([[unix, mgdl], ...], live readings only, from glucos.readings where
trend > 0) and logs.json ([[unix, kind], ...], meals, doses and context from glucos.logbook,
payload->>'timestamp'). Optional samples.json ([[reading_t, fetched_at], ...]) from the relay row
(work->'current'->'t', work->>'lastFetchAt').

Part 1, arrival. glucos.readings keeps only the sample time, so arrival is read three ways: the
relay row's fetch time against its reading time; the second of the minute the readings carry, day
by day (the relay ticks at about :01, so that sets how old each reading is when the relay fetches
it); and how often a minute goes missing against the margin between a reading's time and the next
relay tick (a reading LinkUp hasn't got yet when the relay ticks is skipped, so misses climb when
the margin is short).

Part 2, held out. The engine's trend forecast (20-minute least-squares slope clamped at ±4,
30-minute fade, the tuner's gains) every 5 minutes away from logs, 11–17 Nov. Each candidate draws
the point for horizon h at line(h + d): d > 0 projects as if from arrival time (the reading's time
plus its delay), d < 0 as if the reading were older than it says. Two ways of scoring:
  chart: against the reading h minutes after the reading's time (what the chart and ledger mean);
  label: against the reading h + a minutes after it, a = 0.5 (relay) or 1.0 (apps, average), i.e.
         "in h minutes" from when the person reads it, the arrival-time view.
Leave-one-Perth-day-out: d is picked on six days per horizon (lowest mean miss), scored on the
seventh. Ship bar: lower held-out miss at both 15 and 30 min, better on most days, and no more
missed lows (actual under 70 with the line, or the range bottom, at or above 70).
"""
import bisect, datetime as dt, json, os, statistics as st, sys, collections

d = sys.argv[1]
R = json.load(open(f"{d}/readings.json"))
L = json.load(open(f"{d}/logs.json"))
T = [r[0] for r in R]
logs = sorted(t for t, _ in L)
FADE, TREND_W, MAX = 30.0, 20, 4.0
GAINS = (0.45, 0.6, 0.7)
HS = (15, 30, 60)
DS = (-3, -2, -1.5, -1, -0.5, 0, 0.5, 1, 1.5, 2, 3)
AGES = (0.0, 0.5, 1.0)

def perth_day(t): return dt.datetime.fromtimestamp(t + 8 * 3600, dt.UTC).strftime("%d")

# --- 1. Arrival ---------------------------------------------------------------------------
print("== Arrival")
if os.path.exists(f"{d}/samples.json"):
    S = json.load(open(f"{d}/samples.json"))
    ages = sorted(f - t for t, f in S)
    print(f"Relay row: {len(S)} samples, age at fetch {ages[0]:.0f}–{ages[-1]:.0f} s, median {st.median(ages):.0f} s")
by = collections.defaultdict(list)
for t, _ in R: by[perth_day(t)].append(t % 60)
print("Second of the minute readings carry, by Perth day (median, range):")
for day, v in sorted(by.items()):
    print(f"  {day} Nov: {len(v)} readings, :{st.median(v):02.0f} ({min(v)}–{max(v)})")
b = collections.defaultdict(lambda: [0, 0])
gaps = []
for (t0, _), (t1, _) in zip(R, R[1:]):
    g = t1 - t0; gaps.append(g)
    if g > 400: continue
    k = ((61 - t1 % 60) % 60) // 10 * 10
    b[k][0] += 1; b[k][1] += 90 < g <= 150
print("Missed minutes against the margin from reading time to the next relay tick (:01):")
for k in sorted(b):
    n, two = b[k]; print(f"  {k:2d}–{k + 9} s: {n} steps, {two} one-minute misses ({two / n:.1%})")
print(f"Steps a minute apart: {sum(g <= 90 for g in gaps) / len(gaps):.1%} of {len(gaps)}")

# --- 2. Held-out offset ------------------------------------------------------------------
def window(t, minutes):
    i, j = bisect.bisect_left(T, t - minutes * 60), bisect.bisect_right(T, t)
    return [((T[k] - t) / 60, R[k][1]) for k in range(i, j)]

def slope(pts, span=9):
    if len(pts) < 3 or pts[-1][0] - pts[0][0] < span: return None
    mx = st.mean(p[0] for p in pts); my = st.mean(p[1] for p in pts)
    sxx = sum((p[0] - mx) ** 2 for p in pts)
    return max(-MAX, min(MAX, sum((p[0] - mx) * (p[1] - my) for p in pts) / sxx)) if sxx else None

def line(g, tr, gain, u):
    u = max(0.0, min(u, FADE))
    return g + gain * tr * (u - u * u / (2 * FADE))

def actual(t):
    i = bisect.bisect_left(T, t)
    if i == 0 or i >= len(T): return None
    a, b_ = i - 1, i
    if T[b_] - T[a] > 150: return None
    return R[a][1] + (R[b_][1] - R[a][1]) * (t - T[a]) / (T[b_] - T[a])

pts = []
for slot in range(T[0] - T[0] % 300 + 300, T[-1] - 3900, 300):
    i = bisect.bisect_right(T, slot) - 1
    if i < 0 or slot - T[i] >= 60: continue
    t = T[i]
    j = bisect.bisect_right(logs, t + 3900) - 1
    if j >= 0 and logs[j] > t - 3 * 3600: continue
    tr = slope(window(t, TREND_W))
    if tr is None: continue
    act = {(h, a): actual(t + (h + a) * 60) for h in HS for a in AGES}
    if None in act.values(): continue
    pts.append(dict(t=t, g=R[i][1], tr=tr, act=act, day=perth_day(t)))
days = sorted({p["day"] for p in pts})
print(f"\n== Held out: {len(pts)} clean points over {len(days)} Perth days ({days[0]}–{days[-1]} Nov)")

def q(xs, f):
    xs = sorted(xs); k = f * (len(xs) - 1); lo = int(k)
    return xs[lo] + (xs[min(lo + 1, len(xs) - 1)] - xs[lo]) * (k - lo)

def mae(ps, gain, h, a, dd):
    return st.mean(abs(p["act"][(h, a)] - line(p["g"], p["tr"], gain, h + dd)) for p in ps)

for gain in GAINS:
    print(f"\n-- gain {gain}")
    print("  score | horizon | d=0 | held-out pick | change | days better/worse | picks | lows missed line/bottom d=0 → pick")
    for a in AGES:
        name = "chart" if a == 0 else f"label a={a}"
        for h in HS:
            e0 = e1 = n = 0; better = worse = 0; picks = []
            miss0 = miss1 = bm0 = bm1 = nl = 0
            for day in days:
                tr_ = [p for p in pts if p["day"] != day]; te = [p for p in pts if p["day"] == day]
                if not te: continue
                dd = min(DS, key=lambda x: (mae(tr_, gain, h, a, x), abs(x)))
                picks.append(dd)
                r0 = [p["act"][(h, a)] - line(p["g"], p["tr"], gain, h) for p in tr_]
                r1 = [p["act"][(h, a)] - line(p["g"], p["tr"], gain, h + dd) for p in tr_]
                lo0, lo1 = q(r0, .1), q(r1, .1)
                m0 = mae(te, gain, h, a, 0); m1 = mae(te, gain, h, a, dd)
                e0 += m0 * len(te); e1 += m1 * len(te); n += len(te)
                if len(te) >= 20 and dd != 0:
                    better += m1 < m0; worse += m1 > m0
                for p in te:
                    if p["act"][(h, a)] < 70:
                        nl += 1
                        f0 = line(p["g"], p["tr"], gain, h); f1 = line(p["g"], p["tr"], gain, h + dd)
                        miss0 += f0 >= 70; miss1 += f1 >= 70
                        bm0 += f0 + lo0 >= 70; bm1 += f1 + lo1 >= 70
            c = collections.Counter(picks)
            print(f"  {name:11} | {h:2} | {e0 / n:6.2f} | {e1 / n:6.2f} | {100 * (e1 - e0) / e0:+5.1f}% | "
                  f"{better}/{worse} | {dict(sorted(c.items()))} | {nl} lows: {miss0}/{bm0} → {miss1}/{bm1}")

print("\n== Fixed offsets, all days (mean miss; label a=0.5 / chart)")
for gain in GAINS:
    for h in (15, 30):
        row = ", ".join(f"d={x:+}: {mae(pts, gain, h, 0.5, x):.2f}/{mae(pts, gain, h, 0, x):.2f}" for x in (-3, -1, 0, 0.5, 1, 1.5, 3))
        print(f"  gain {gain}, {h} min: {row}")
