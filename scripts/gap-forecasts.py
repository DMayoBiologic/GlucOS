#!/usr/bin/env python3
"""Forecasts made just after a gap in readings (ForecastAccuracy.md §31).

Usage: python3 scripts/gap-forecasts.py DIR
DIR holds readings.json ([[unix, mgdl, trend], ...] from glucos.readings) and checks.json
(one row per glucos.forecast_checks row, query in §31). Prints clean points by kind of gap, then a
leave-one-day-out test of cutting a horizon or widening the range after a gap.
"""
import bisect, datetime as dt, json, statistics as st, sys

d = sys.argv[1]
R = json.load(open(f"{d}/readings.json"))
C = json.load(open(f"{d}/checks.json"))

# Live readings only: drop LinkUp graph points (trend 0) within 30 s of another reading (§23).
live = [R[i] for i in range(len(R)) if not (R[i][2] == 0 and (
    (i > 0 and R[i][0] - R[i - 1][0] < 30) or (i + 1 < len(R) and R[i + 1][0] - R[i][0] < 30)))]
gaps = [(live[i - 1][0], live[i][0]) for i in range(1, len(live)) if live[i][0] - live[i - 1][0] > 300]
gap_ends = [g[1] for g in gaps]

pts, last, wake = [], {}, {}
for t, dev, basis, start, trend, points, _ver in C:
    if dev not in last or t - last[dev] > 25 * 60:
        wake[dev] = t  # first forecast after the app was closed or the Mac slept
    last[dev] = t
    i = bisect.bisect_right(gap_ends, t) - 1
    since_gap = (t - gaps[i][1]) / 60 if i >= 0 else 1e9
    for m, pr, lo, up, act, after_log, _shown, _scale in points or []:
        if after_log or m not in (15, 30, 60):
            continue
        pts.append(dict(t=t, dev=dev, m=m, pr=pr, lo=lo, up=up, act=float(act), start=start,
                        since_wake=(t - wake[dev]) / 60, since_gap=since_gap,
                        day=dt.datetime.fromtimestamp(t + 8 * 3600, dt.UTC).strftime("%d")))
days = sorted({p["day"] for p in pts})

def err(p): return abs(p["act"] - p["pr"])
def nochange(p): return abs(p["act"] - p["start"])
def inside(p, k=1): return p["pr"] - k * (p["pr"] - p["lo"]) <= p["act"] <= p["pr"] + k * (p["up"] - p["pr"])
def ratio(p):
    e = p["act"] - p["pr"]
    return abs(e) / max((p["up"] - p["pr"]) if e > 0 else (p["pr"] - p["lo"]), 1e-6)
def iscore(p, k=1):  # 80% interval score: width plus 10x any miss outside it
    lo, up = p["pr"] - k * (p["pr"] - p["lo"]), p["pr"] + k * (p["up"] - p["pr"])
    return up - lo + 10 * max(0, lo - p["act"]) + 10 * max(0, p["act"] - up)
def q80(xs):
    xs = sorted(xs); return xs[int(0.8 * (len(xs) - 1))]

def kind(p):
    if p["since_gap"] <= 30: return "data gap <=30 min ago"
    if p["since_wake"] == 0 and p["dev"] != "relay": return "first after a wake"
    return "unbroken"

print(f"{len(pts)} clean points, {len(gaps)} gaps over 5 min in live readings")
for m in (15, 30, 60):
    for k in ("unbroken", "first after a wake", "data gap <=30 min ago"):
        s = [p for p in pts if p["m"] == m and kind(p) == k]
        if s:
            print(f"{m:3d} {k:22s} n={len(s):3d} error {st.mean(map(err, s)):5.1f} "
                  f"no change {st.mean(map(nochange, s)):5.1f} inside {100 * st.mean(map(inside, s)):3.0f}%")

print("\nheld out: cut the horizon (show nothing, scored as no change) / widen the range")
for name, gap in (("wake", lambda p, n: p["dev"] != "relay" and p["since_wake"] <= n),
                  ("data", lambda p, n: p["since_gap"] <= max(n, 5))):
    for n in (0, 15, 30, 45):
        for m in (15, 30, 60):
            G = [p for p in pts if p["m"] == m and gap(p, n)]
            base = cut = wide = basis = 0; ins0 = ins1 = 0
            for day in days:
                tr = [p for p in G if p["day"] != day]; te = [p for p in G if p["day"] == day]
                if not te or len(tr) < 10: continue
                c = st.mean(map(err, tr)) > st.mean(map(nochange, tr))
                k = max(1, q80([ratio(p) for p in tr]))
                for p in te:
                    base += err(p); cut += nochange(p) if c else err(p)
                    basis += iscore(p); wide += iscore(p, k); ins0 += inside(p); ins1 += inside(p, k)
            N = sum(1 for p in G if sum(q["day"] != p["day"] for q in G) >= 10)
            if N:
                print(f"{name} {n:2d} {m:3d} n={N:3d} error {base / N:5.1f} -> {cut / N:5.1f}  "
                      f"inside {100 * ins0 / N:3.0f} -> {100 * ins1 / N:3.0f}%  score {basis / N:6.1f} -> {wide / N:6.1f}")
