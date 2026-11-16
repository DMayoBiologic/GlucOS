#!/usr/bin/env python3
"""Does the trend arrow match what happened next? (ForecastAccuracy.md §32)

Usage: python3 scripts/trend-arrow.py DIR
DIR holds readings.json ([[unix, mgdl, trend], ...] from glucos.readings; trend 0 rows are LinkUp
graph points and are dropped). The arrow on every screen is LinkUp's TrendArrow, passed through.

Prints how each arrow's next 15 and 30 minutes went, then a leave-one-Perth-day-out test of
replacing it with an arrow GlucOS works out itself from the last N minutes of readings, with the
rate thresholds (steady/rising and rising/quickly, mg/dL per minute) fitted on the other days.
"""
import bisect, datetime as dt, itertools, json, statistics as st, sys

R = json.load(open(f"{sys.argv[1]}/readings.json"))
live = sorted({int(t) // 60: (int(t) // 60 * 60, float(g), int(a)) for t, g, a in R if a > 0}.values())
T = [r[0] for r in live]
NAMES = {1: "falling quickly", 2: "falling", 3: "steady", 4: "rising", 5: "rising quickly"}

def at(t, tol=120):
    """The live reading nearest t, within tol seconds."""
    i = bisect.bisect_left(T, t)
    best = min((j for j in (i - 1, i) if 0 <= j < len(T)), key=lambda j: abs(T[j] - t), default=None)
    return live[best] if best is not None and abs(T[best] - t) <= tol else None

def band(rate, a=1.0, b=2.0):
    """Arrow for a rate in mg/dL per minute; Abbott's documented bands are a=1, b=2."""
    if rate < -b: return 1
    if rate < -a: return 2
    if rate <= a: return 3
    if rate <= b: return 4
    return 5

def past_rate(i, window):
    """Rate over the last `window` minutes of live readings (at least 5 min apart), as LibreReadings.trend."""
    t, g, _ = live[i]
    j = bisect.bisect_left(T, t - window * 60)
    if t - T[j] < 300: return None
    return (g - live[j][1]) / ((t - T[j]) / 60)

pts = []
for i, (t, g, arrow) in enumerate(live):
    f15, f30 = at(t + 900), at(t + 1800)
    if not f15 or not f30: continue
    pts.append(dict(t=t, g=g, arrow=arrow, d15=f15[1] - g, d30=f30[1] - g,
                    past={w: past_rate(i, w) for w in (5, 10, 15)},
                    day=dt.datetime.fromtimestamp(t + 8 * 3600, dt.UTC).strftime("%d")))
days = sorted({p["day"] for p in pts})
print(f"{len(pts)} live readings with a reading 15 and 30 min later, {len(days)} Perth days ({days[0]}–{days[-1]} Nov)\n")

def happened(p, h): return band(p[f"d{h}"] / h)

print("What happened after each LinkUp arrow (actual band uses the same ±1 / ±2 mg/dL/min):")
print(f"{'arrow':16} {'n':>5} {'15 min':>8} {'30 min':>8} {'right band 15/30':>17} {'right way 15/30':>16} {'wrong way 15':>13}")
for a in range(1, 6):
    s = [p for p in pts if p["arrow"] == a]
    if not s: continue
    rb15 = st.mean(happened(p, 15) == a for p in s); rb30 = st.mean(happened(p, 30) == a for p in s)
    if a == 3:
        rw15 = st.mean(abs(p["d15"]) <= 15 for p in s); rw30 = st.mean(abs(p["d30"]) <= 30 for p in s)
        wrong = st.mean(abs(p["d15"]) > 30 for p in s)
    else:
        sign = 1 if a > 3 else -1
        rw15 = st.mean(sign * p["d15"] > 0 for p in s); rw30 = st.mean(sign * p["d30"] > 0 for p in s)
        wrong = st.mean(sign * p["d15"] < -15 for p in s)
    print(f"{NAMES[a]:16} {len(s):5} {st.median(p['d15'] for p in s):+8.0f} {st.median(p['d30'] for p in s):+8.0f}"
          f" {rb15:8.0%} {rb30:7.0%} {rw15:8.0%} {rw30:6.0%} {wrong:12.0%}")
print("(15/30 min = median change, mg/dL. Steady 'right way' = within 15 / 30 mg/dL. Wrong way = 15 mg/dL the other way,"
      " or for steady more than 30 mg/dL either way.)\n")

def score(arrow, p, h):
    """Band distance between the arrow and what happened (0 = right band); lower is better."""
    return abs(arrow - happened(p, h))

def arrows(rule, p):
    if rule == "linkup": return p["arrow"]
    w, a, b = rule
    r = p["past"][w]
    return None if r is None else band(r, a, b)

GRID = [(w, a, b) for w in (5, 10, 15) for a in (0.5, 0.75, 1.0, 1.25, 1.5, 2.0)
        for b in (1.5, 2.0, 2.5, 3.0, 4.0) if b > a]

def mean_score(rule, s, h):
    v = [score(x, p, h) for p in s if (x := arrows(rule, p)) is not None]
    return st.mean(v) if v else 9

for h in (15, 30):
    print(f"Leave one day out, {h} min (mean band distance; lower is better):")
    tot = {"linkup": [], "own (Abbott ±1/±2, 15 min)": [], "own (fitted)": []}
    for d in days:
        train = [p for p in pts if p["day"] != d and p["past"][15] is not None]
        test = [p for p in pts if p["day"] == d and p["past"][15] is not None]
        if not test: continue
        best = min(GRID, key=lambda r: mean_score(r, train, h))
        lk, ab, fit = (mean_score(r, test, h) for r in ("linkup", (15, 1.0, 2.0), best))
        tot["linkup"].append((lk, len(test))); tot["own (Abbott ±1/±2, 15 min)"].append((ab, len(test)))
        tot["own (fitted)"].append((fit, len(test)))
        print(f"  {d} Nov n={len(test):4}  LinkUp {lk:.3f}  own ±1/±2 {ab:.3f}  fitted {best} {fit:.3f}"
              f"  {'fitted wins' if fit < lk else 'LinkUp wins'}")
    for k, v in tot.items():
        n = sum(x[1] for x in v)
        print(f"  {k:28} {sum(x[0] * x[1] for x in v) / n:.3f}")
    print(f"  {'always steady (no arrow)':28} {st.mean(score(3, p, h) for p in pts if p['past'][15] is not None):.3f}"
          "  <- band distance rewards a quiet arrow, so it can't pick thresholds on its own\n")

def balanced(rule, s, h):
    """Share of real moves (15 mg/dL per 15 min either way) the arrow pointed at, plus share of steady
    stretches it left steady. 2 is perfect, always-steady scores 1."""
    v = [(x, happened(p, h)) for p in s if (x := arrows(rule, p)) is not None]
    moved = [(a, b) for a, b in v if b != 3]; still = [a for a, b in v if b == 3]
    return (st.mean(a != 3 and (a < 3) == (b < 3) for a, b in moved) if moved else 0) + \
           (st.mean(a == 3 for a in still) if still else 0)

for h in (15, 30):
    print(f"Leave one day out, {h} min, balanced score (higher is better):")
    wins, lk_all, fit_all = 0, [], []
    for d in days:
        train = [p for p in pts if p["day"] != d and p["past"][15] is not None]
        test = [p for p in pts if p["day"] == d and p["past"][15] is not None]
        best = max(GRID, key=lambda r: balanced(r, train, h))
        lk, fit = balanced("linkup", test, h), balanced(best, test, h)
        wins += fit > lk; lk_all.append(lk); fit_all.append(fit)
        print(f"  {d} Nov  LinkUp {lk:.3f}  fitted {best} {fit:.3f}")
    print(f"  fitted beat LinkUp on {wins} of {len(days)} days; mean LinkUp {st.mean(lk_all):.3f}, fitted {st.mean(fit_all):.3f}\n")

# Safety: lows under 70 within 30 min — how often did each rule show a falling arrow beforehand?
lows = [p for p in pts if p["g"] >= 80 and p["g"] + p["d30"] < 70 and p["past"][15] is not None]
print(f"Readings ≥80 that were under 70 thirty minutes later: {len(lows)}")
for rule in ("linkup", (15, 1.0, 2.0), (15, 1.5, 2.0), (15, 2.0, 4.0), (10, 1.0, 2.0)):
    v = [arrows(rule, p) for p in lows]
    print(f"  {str(rule):18} falling arrow shown {st.mean(x is not None and x <= 2 for x in v):.0%},"
          f" steady {st.mean(x == 3 for x in v):.0%}")
