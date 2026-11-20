#!/usr/bin/env python3
"""ForecastAccuracy §106: is the drawn range calibrated by rate of change?

Bins each clean shown point by how fast glucose was moving when the forecast was made
(|trend_per_minute|): steady (< 0.5 mg/dL a minute), slow (0.5 to < 1.5) and fast (1.5 or more,
`ForecastRangeScale.fastTrendPerMinute`, the split the app already widens on). For each bin and
horizon (15 / 30 / 60 min): how often the reading landed inside, above and below the range, the
width, and the 80% interval score (width + 10 x distance outside; lower is better).

Steady points are also split by the reading 30 minutes before the forecast: "after a move" when
glucose had changed by 20 mg/dL or more in that half hour, otherwise "calm" (§21's side finding
that flat misses more than slow, guessed to be turning points).

Then held out, leave one Perth day out (and walk forward, each day learnt from the days before
it): one width factor per bin x horizon, the 80th percentile of the other days' miss ratios
(miss / drawn half-width on the side it fell), clamped 0.7 to 2.5, scaling both sides about the
line. Bins with under 25 training points keep the drawn range (factor 1). Also a version that
only ever widens (factor >= 1).

Input: one clean shown point per line, from the export in docs/ForecastAccuracy.md §106:

    issued_epoch,device,basis,start,minutes,line,actual,lower,upper,trend_per_min,reading_30_min_before

    python3 -I scripts/range-by-rate.py points.csv
"""
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

PERTH = timezone(timedelta(hours=8))
HORIZONS = (15, 30, 60)
BINS = ("steady", "slow", "fast")
SLOW, FAST = 0.5, 1.5
MOVED = 20.0
MIN_TRAIN = 25
SENSOR_LOW, SENSOR_HIGH = 40, 400


def rate_bin(tr):
    a = abs(tr)
    return "fast" if a >= FAST else "slow" if a >= SLOW else "steady"


def load(path):
    pts = []
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        t, dev, basis, s, m, f, a, lo, hi, tr, r30 = line.split(",")
        p = dict(t=int(t), dev=dev, s=float(s), m=int(m), f=float(f), a=float(a), lo=float(lo),
                 hi=float(hi), tr=float(tr), r30=float(r30) if r30 else None)
        p["day"] = datetime.fromtimestamp(p["t"], PERTH).date()
        p["bin"] = rate_bin(p["tr"])
        p["moved"] = p["r30"] is not None and abs(p["s"] - p["r30"]) >= MOVED
        pts.append(p)
    return pts


def ratio(p):
    """Miss in units of the drawn half-width on the side it fell; None where the range is cut."""
    if p["lo"] <= SENSOR_LOW or p["hi"] >= SENSOR_HIGH:
        return None
    up, dn = p["hi"] - p["f"], p["f"] - p["lo"]
    if up <= 0.5 or dn <= 0.5:
        return None
    e = p["a"] - p["f"]
    return e / up if e >= 0 else -e / dn


def scaled(p, k):
    return p["f"] - (p["f"] - p["lo"]) * k, p["f"] + (p["hi"] - p["f"]) * k


def score(p, k=1.0):
    lo, hi = scaled(p, k)
    out = lo - p["a"] if p["a"] < lo else p["a"] - hi if p["a"] > hi else 0.0
    return (hi - lo) + 10 * out, out == 0, p["a"] > hi, p["a"] < lo, hi - lo


def q(xs, f):
    xs = sorted(xs)
    i = f * (len(xs) - 1)
    a = int(i)
    return xs[a] if a + 1 >= len(xs) else xs[a] + (xs[a + 1] - xs[a]) * (i - a)


def summary(ps, k=lambda p: 1.0):
    n = len(ps)
    if not n:
        return None
    rs = [score(p, k(p)) for p in ps]
    return dict(n=n, days=len({p["day"] for p in ps}), inside=100 * sum(r[1] for r in rs) / n,
                above=100 * sum(r[2] for r in rs) / n, below=100 * sum(r[3] for r in rs) / n,
                width=sum(r[4] for r in rs) / n, score=sum(r[0] for r in rs) / n)


def fmt(s):
    return "—" if s is None else (f"{s['n']:4d} ({s['days']}d)  {s['inside']:5.1f}% in  "
                                  f"{s['above']:4.1f}/{s['below']:4.1f}% above/below  width {s['width']:6.1f}  score {s['score']:6.1f}")


def factors(train, floor):
    out = {}
    for b in BINS:
        for m in HORIZONS:
            rs = [ratio(p) for p in train if p["bin"] == b and p["m"] == m]
            rs = [r for r in rs if r is not None]
            out[(b, m)] = min(2.5, max(floor, q(rs, 0.8))) if len(rs) >= MIN_TRAIN else 1.0
    return out


def held_out(pts, floor, walk):
    days = sorted({p["day"] for p in pts})
    k = {}
    for i, d in enumerate(days):
        train = [p for p in pts if (p["day"] < d if walk else p["day"] != d)]
        if walk and i < 2:
            for p in pts:
                if p["day"] == d:
                    k[id(p)] = 1.0
            continue
        fs = factors(train, floor)
        for p in pts:
            if p["day"] == d:
                k[id(p)] = fs[(p["bin"], p["m"])]
    return k


def main(path):
    pts = [p for p in load(path) if ratio(p) is not None]
    print(f"{len(pts)} clean shown points, {len({p['day'] for p in pts})} days\n")
    print("Shipped range by rate bin and horizon")
    for m in HORIZONS:
        for b in BINS:
            print(f"  {m:2d} min {b:6s} {fmt(summary([p for p in pts if p['m'] == m and p['bin'] == b]))}")
        print(f"  {m:2d} min all    {fmt(summary([p for p in pts if p['m'] == m]))}")
    print("\nSteady points: calm vs after a 20+ mg/dL move in the half hour before")
    for m in HORIZONS:
        for name, mv in (("calm", False), ("moved", True)):
            print(f"  {m:2d} min {name:6s} {fmt(summary([p for p in pts if p['m'] == m and p['bin'] == 'steady' and p['moved'] == mv]))}")
    print("\nMac/iPhone vs relay at 15 min")
    for b in BINS:
        for rel in (False, True):
            ps = [p for p in pts if p["m"] == 15 and p["bin"] == b and (p["dev"] == "relay") == rel]
            print(f"  {b:6s} {'relay' if rel else 'apps ':5s} {fmt(summary(ps))}")
    print("\nLows: readings under 70 with the range bottom under 70")
    for m in HORIZONS:
        ps = [p for p in pts if p["m"] == m and p["a"] < 70]
        print(f"  {m:2d} min {sum(p['lo'] < 70 for p in ps)}/{len(ps)}")

    for label, floor, walk in (("LODO, 0.7-2.5", 0.7, False), ("LODO, widen only", 1.0, False),
                               ("walk-forward, 0.7-2.5", 0.7, True)):
        k = held_out(pts, floor, walk)
        print(f"\nHeld out per bin x horizon factor ({label})")
        for m in HORIZONS:
            for b in BINS + ("all",):
                ps = [p for p in pts if p["m"] == m and (b == "all" or p["bin"] == b)]
                base, new = summary(ps), summary(ps, lambda p: k[id(p)])
                byday = defaultdict(list)
                for p in ps:
                    byday[p["day"]].append(p)
                better = sum(1 for d in byday if len(byday[d]) >= 10 and
                             summary(byday[d], lambda p: k[id(p)])["score"] < summary(byday[d])["score"])
                counted = sum(1 for d in byday if len(byday[d]) >= 10)
                lows = [p for p in ps if p["a"] < 70]
                lows_in = sum(scaled(p, k[id(p)])[0] < 70 for p in lows)
                print(f"  {m:2d} min {b:6s} {base['inside']:5.1f}% -> {new['inside']:5.1f}%  width {base['width']:6.1f} -> {new['width']:6.1f}"
                      f"  score {base['score']:6.1f} -> {new['score']:6.1f} ({100 * (new['score'] / base['score'] - 1):+5.1f}%)"
                      f"  days better {better}/{counted}  lows covered {lows_in}/{len(lows)}")
    fs = factors(pts, 0.7)
    print("\nIn-sample factors (all days):", {f"{b}/{m}": round(v, 2) for (b, m), v in fs.items()})


if __name__ == "__main__":
    main(sys.argv[1])
