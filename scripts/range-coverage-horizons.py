#!/usr/bin/env python3
"""ForecastAccuracy §99: does the drawn range hold its 8 in 10 at 5, 10, 15, 30, 45 and 60 minutes?

For each horizon: how often the reading landed inside the drawn range, above it and below it,
against the 80% the range aims for (`ForecastScorecard.rangeTarget`, the `0.8` quantile in
`ForecastLedger.rangeScale`). Then a held-out test of one width factor per horizon (and one per
side per horizon), leave one Perth day out, judged on the 80% interval score.

The accuracy log only scores 15, 30, 45 and 60 minutes (and 90+ for the Outlook). 5 and 10
minutes are rebuilt from each clean 15-minute point:

- line: straight from the starting reading to the 15-minute line (the trend fades over at least
  an hour, so the first 15 minutes are close to straight);
- range: each side scaled by m / 15 (`ForecastCalibration.interpolate` scales the first checked
  horizon linearly below it, never under 0.6 x the default band: 5.4 / 7.2 mg/dL a side at 5 / 10
  minutes; the floor is applied before the range scale, so the rebuilt side is a lower bound
  where it binds), with §40's low-start upper widening (2.8x at 15, 1.6x at 5, 2.2x at
  10 for starts under 80) taken out and put back at the shorter horizon;
- reading: the stored reading in `glucos.readings` nearest 5 / 10 minutes after the forecast
  (within a minute). A 15-minute point with nothing logged before 15 minutes has nothing logged
  before 5 or 10 either.

Input: one clean shown point per line (nothing logged after, drawn), from the export in
docs/ForecastAccuracy.md §99:

    issued_epoch,device,basis,start,minutes,line,actual,lower,upper,trend_per_min,actual5,actual10

    python3 -I scripts/range-coverage-horizons.py points.csv
"""
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

PERTH = timezone(timedelta(hours=8))
SETTLED_FROM = datetime(2026, 11, 14, tzinfo=PERTH).timestamp()  # range width settled (§98)
HORIZONS = (5, 10, 15, 30, 45, 60)
TARGET = 0.80
LOW_START = 80.0
LOW_START_UPPER = ((0, 1.0), (15, 2.8), (30, 3.3), (60, 3.6))
SENSOR_LOW, SENSOR_HIGH = 40, 400
FAST = 1.5  # ForecastRangeScale.fastTrendPerMinute


def interp(table, m):
    for (a, fa), (b, fb) in zip(table, table[1:]):
        if m <= b:
            return fa + (fb - fa) * (m - a) / (b - a)
    return table[-1][1]


def load(path):
    pts = []
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        t, dev, basis, s, m, f, a, lo, hi, tr, a5, a10 = line.split(",")
        t, s, m, f, a, lo, hi, tr = int(t), float(s), int(m), float(f), float(a), float(lo), float(hi), float(tr)
        day = datetime.fromtimestamp(t, PERTH).date()
        base = dict(t=t, dev=dev, basis=basis, s=s, tr=tr, day=day, relay=dev == "relay")
        pts.append(dict(base, m=m, f=f, a=a, lo=lo, hi=hi))
        if m != 15 or lo <= SENSOR_LOW or hi >= SENSOR_HIGH:
            continue
        up15 = interp(LOW_START_UPPER, 15) if s < LOW_START else 1.0
        for mm, am in ((5, a5), (10, a10)):
            if not am:
                continue
            k = mm / 15
            fm = s + (f - s) * k
            upm = interp(LOW_START_UPPER, mm) if s < LOW_START else 1.0
            floor = 0.6 * (6 + 0.6 * mm)  # never under the floor, whatever the 15-minute side was
            pts.append(dict(base, m=mm, f=fm, a=float(am),
                            lo=fm - max(floor, (f - lo) * k), hi=fm + max(floor, (hi - f) * k / up15 * upm)))
    return pts


def side_ratios(p):
    """Miss as a share of the drawn half-width on the side it fell (above, below)."""
    up, down = p["hi"] - p["f"], p["f"] - p["lo"]
    if up <= 0.5 or down <= 0.5:
        return None
    e = p["a"] - p["f"]
    return ("up", e / up) if e >= 0 else ("down", -e / down)


def scaled(p, cu, cd):
    return p["f"] - (p["f"] - p["lo"]) * cd, p["f"] + (p["hi"] - p["f"]) * cu


def score(p, lo, hi):
    """80% interval score: width + 2 / (1 - 0.8) x distance outside. Lower is better."""
    a = p["a"]
    return (hi - lo) + 10 * (max(0, lo - a) + max(0, a - hi))


def quantile(xs, q):
    xs = sorted(xs)
    if not xs:
        return 1.0
    i = q * (len(xs) - 1)
    lo = int(i)
    hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (i - lo)


def wilson(k, n, z=1.96):
    if not n:
        return (0, 0)
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * ((p * (1 - p) / n + z * z / (4 * n * n)) ** 0.5) / d
    return 100 * (c - h), 100 * (c + h)


def coverage(ps, label):
    n = len(ps)
    if not n:
        print(f"{label:<22} -")
        return
    ins = sum(p["lo"] <= p["a"] <= p["hi"] for p in ps)
    ab = sum(p["a"] > p["hi"] for p in ps)
    be = sum(p["a"] < p["lo"] for p in ps)
    lo, hi = wilson(ins, n)
    by_day = defaultdict(list)
    for p in ps:
        by_day[p["day"]].append(p["lo"] <= p["a"] <= p["hi"])
    days = [100 * sum(v) / len(v) for v in by_day.values() if len(v) >= 10]
    spread = f"{min(days):3.0f}-{max(days):3.0f}%" if days else "   -   "
    w = sum(p["hi"] - p["lo"] for p in ps) / n
    print(f"{label:<22} n {n:4d} days {len(by_day)} inside {100 * ins / n:5.1f}% ({lo:4.1f}-{hi:4.1f})"
          f" above {100 * ab / n:4.1f}% below {100 * be / n:4.1f}% width {w:5.1f} day range {spread}")


def heldout(ps, m, sided):
    """Leave one Perth day out: factor(s) fitted on the other days' miss ratios (q80, or q90 per
    side so the two tails sum to 20%), clamped 0.7-2.5. Returns shipped and held-out summaries."""
    days = sorted({p["day"] for p in ps})
    res = dict(ship=[0, 0, 0, 0], held=[0, 0, 0, 0])
    per_day = []
    factors = []
    for d in days:
        train = [r for r in (side_ratios(p) for p in ps if p["day"] != d) if r]
        test = [p for p in ps if p["day"] == d]
        if len(train) < 30 or not test:
            continue
        if sided:
            share_up = sum(s == "up" for s, _ in train) / len(train)
            cu = quantile([x for s, x in train if s == "up"], 1 - 0.1 / max(share_up, 0.1)) if share_up else 1
            cd = quantile([x for s, x in train if s == "down"], 1 - 0.1 / max(1 - share_up, 0.1)) if share_up < 1 else 1
        else:
            cu = cd = quantile([x for _, x in train], TARGET)
        cu, cd = (min(2.5, max(0.7, c)) for c in (cu, cd))
        factors.append((cu, cd))
        s0 = s1 = 0.0
        for p in test:
            lo, hi = scaled(p, cu, cd)
            for key, (l, h) in (("ship", (p["lo"], p["hi"])), ("held", (lo, hi))):
                r = res[key]
                r[0] += 1
                r[1] += l <= p["a"] <= h
                r[2] += h - l
                r[3] += score(p, l, h)
            s0 += score(p, p["lo"], p["hi"])
            s1 += score(p, lo, hi)
        per_day.append(s1 < s0)
    return res, per_day, factors


def held_table(pts, title):
    print(f"\n== Held out, leave one Perth day out ({title}): inside / width / score; days better")
    for m in HORIZONS:
        ps = [p for p in pts if p["m"] == m]
        if len(ps) < 40:
            continue
        for sided in (False, True):
            res, per_day, fs = heldout(ps, m, sided)
            s, h = res["ship"], res["held"]
            if not s[0]:
                continue
            fu = sum(f[0] for f in fs) / len(fs)
            fd = sum(f[1] for f in fs) / len(fs)
            label = "per side" if sided else "one factor"
            print(f"{m:3d} min {label:<10} shipped {100 * s[1] / s[0]:5.1f}% / {s[2] / s[0]:5.1f} / {s[3] / s[0]:6.1f}"
                  f"  held out {100 * h[1] / h[0]:5.1f}% / {h[2] / h[0]:5.1f} / {h[3] / h[0]:6.1f}"
                  f" ({100 * (h[3] / s[3] - 1):+5.1f}%)  better {sum(per_day)}/{len(per_day)}"
                  f"  mean factor up {fu:.2f} down {fd:.2f}")


def lows(pts):
    print("\n== Readings under 70 with the range bottom already under 70 (shipped / one factor held out)")
    for m in HORIZONS:
        ps = [p for p in pts if p["m"] == m]
        if len(ps) < 40:
            continue
        days = sorted({p["day"] for p in ps})
        n = got = got_h = 0
        for d in days:
            train = [r for r in (side_ratios(p) for p in ps if p["day"] != d) if r]
            c = min(2.5, max(0.7, quantile([x for _, x in train], TARGET))) if len(train) >= 30 else 1
            for p in ps:
                if p["day"] != d or p["a"] >= 70:
                    continue
                n += 1
                got += p["lo"] < 70
                got_h += scaled(p, c, c)[0] < 70
        print(f"{m:3d} min: {got}/{n} shipped, {got_h}/{n} held out")


def main(path):
    pts = load(path)
    days = sorted({p["day"] for p in pts})
    print(f"{len(pts)} points ({sum(p['m'] in (5, 10) for p in pts)} rebuilt at 5/10 min), {days[0]}..{days[-1]} Perth")
    for title, sel in (("all ranges", pts), ("ranges from 14 Nov on", [p for p in pts if p["t"] >= SETTLED_FROM])):
        print(f"\n== Coverage, {title} (target 80%; Wilson 95% interval treats points as independent)")
        for m in HORIZONS:
            ps = [p for p in sel if p["m"] == m]
            coverage(ps, f"{m} min")
            coverage([p for p in ps if not p["relay"]], f"  apps")
            coverage([p for p in ps if p["relay"]], f"  relay")
            coverage([p for p in ps if abs(p["tr"]) >= FAST], f"  fast trend")
    held_table(pts, "all ranges")
    held_table([p for p in pts if p["t"] >= SETTLED_FROM], "from 14 Nov on")
    lows(pts)


if __name__ == "__main__":
    main(sys.argv[1])
