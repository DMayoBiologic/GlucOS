#!/usr/bin/env python3
"""ForecastAccuracy §98: forecast error by the glucose level the forecast started from.

Bands (mg/dL): under 70, 70-180, 180-250, over 250. Horizons 15, 30 and 60 minutes, both the
line (bias, miss, no-change miss) and the range (inside rate, misses above / below, width).

Input: the same points file as §97 (one clean shown point per line, nothing logged after,
drawn), from glucos.forecast_checks:

    issued_epoch,device,basis,start_mgdl,minutes,forecast,actual,lower,upper

Export it in the Supabase SQL editor with the `string_agg` query in docs/ForecastAccuracy.md
§97 or §98, save the `rows` value one point per line, and pass the path:

    python3 scripts/start-band-forecasts.py points.csv

Prints the band tables (all ranges, and ranges from 14 Nov on, after §40 / §41 widened the low
and high starts), per Perth day per band at 30 minutes, and the held-out tweaks (leave one
Perth day out): a shrunk mean shift plus range scale per band x horizon, a range scale alone,
a shift alone, and a shift for starts over 180 only (§36's carried retest), each at k 0 / 10 / 30.
"""
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

PERTH = timezone(timedelta(hours=8))
WIDE_FROM = datetime(2026, 11, 14, tzinfo=PERTH).timestamp()
HORIZONS = (15, 30, 60)
BANDS = ("<70", "70-180", "180-250", ">250")


def band(s):
    return BANDS[0] if s < 70 else BANDS[1] if s <= 180 else BANDS[2] if s <= 250 else BANDS[3]


def load(path):
    pts = []
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        t, dev, basis, start, m, f, a, lo, hi = line.split(",")
        t = int(t)
        pts.append(dict(t=t, dev=dev, basis=basis, start=float(start), m=int(m), f=float(f),
                        a=float(a), lo=float(lo), hi=float(hi),
                        day=datetime.fromtimestamp(t, PERTH).date(), band=band(float(start))))
    return pts


def stats(ps):
    n = len(ps)
    if not n:
        return None
    return dict(
        n=n, days=len({p["day"] for p in ps}),
        bias=sum(p["a"] - p["f"] for p in ps) / n,
        mae=sum(abs(p["a"] - p["f"]) for p in ps) / n,
        nc=sum(abs(p["a"] - p["start"]) for p in ps) / n,
        inside=100 * sum(p["lo"] <= p["a"] <= p["hi"] for p in ps) / n,
        above=100 * sum(p["a"] > p["hi"] for p in ps) / n,
        below=100 * sum(p["a"] < p["lo"] for p in ps) / n,
        width=sum(p["hi"] - p["lo"] for p in ps) / n)


def row(label, s):
    if s is None:
        return f"{label:<16} -"
    return (f"{label:<16} n {s['n']:>4} days {s['days']} bias {s['bias']:+6.1f} miss {s['mae']:5.1f}"
            f" no-change {s['nc']:5.1f} inside {s['inside']:5.1f}% above {s['above']:4.1f}%"
            f" below {s['below']:4.1f}% width {s['width']:4.0f}")


def table(pts, title):
    print(f"\n== {title}")
    for m in HORIZONS:
        print(f"-- {m} min")
        for b in BANDS:
            print(row(b, stats([p for p in pts if p["m"] == m and p["band"] == b])))
        print(row("all", stats([p for p in pts if p["m"] == m])))


def by_day(pts):
    print("\n== 30 min by Perth day and band (n bias/miss/inside)")
    for d in sorted({p["day"] for p in pts}):
        cells = []
        for b in BANDS:
            s = stats([p for p in pts if p["day"] == d and p["m"] == 30 and p["band"] == b])
            cells.append(f"{b}: -" if s is None else f"{b}: {s['n']} {s['bias']:+.0f}/{s['mae']:.0f}/{s['inside']:.0f}%")
        print(d.strftime("%a %d"), " | ".join(cells))


def tweak(pts, k, shift=True, scale_on=True, only=None):
    """Leave one Perth day out: shift line and range by the shrunk mean miss of the other days'
    points in the same band x horizon (once there are 5), and scale the range about the line so
    those points would be 80% inside (1x to 2.5x, like ForecastLedger.rangeScale)."""
    cells = defaultdict(list)
    for q in pts:
        cells[(q["band"], q["m"])].append(q)
    out = []
    for p in pts:
        if only and p["band"] not in only:
            out.append(p)
            continue
        train = [q for q in cells[(p["band"], p["m"])] if q["day"] != p["day"]]
        d = sum(q["a"] - q["f"] for q in train) / (len(train) + k) if shift and len(train) >= 5 else 0.0
        s = 1.0
        if scale_on and len(train) >= 10:
            for s in [1 + i * 0.05 for i in range(31)]:
                ins = sum((q["f"] + d - s * (q["f"] - q["lo"])) <= q["a"] <= (q["f"] + d + s * (q["hi"] - q["f"])) for q in train)
                if ins >= 0.8 * len(train):
                    break
        out.append(dict(p, f=p["f"] + d, lo=p["f"] + d - s * (p["f"] - p["lo"]),
                        hi=p["f"] + d + s * (p["hi"] - p["f"])))
    return out


def lows(ps):
    """Readings that ended under 70: how many had the line under 70 (what low warnings read)."""
    hit = [p for p in ps if p["a"] < 70]
    return sum(p["f"] < 70 for p in hit), len(hit)


def score(ps):
    """Interval score for an 80% range (lower is better)."""
    tot = 0.0
    for p in ps:
        tot += (p["hi"] - p["lo"]) + 10 * max(0, p["lo"] - p["a"]) + 10 * max(0, p["a"] - p["hi"])
    return tot / len(ps)


def compare(pts):
    print("\n== Held out (leave one Perth day out), change vs shipped")
    days = sorted({p["day"] for p in pts})
    base = {m: [p for p in pts if p["m"] == m] for m in HORIZONS}
    bl = lows(pts)
    print("shipped", " | ".join(f"{m}: miss {stats(base[m])['mae']:.1f} inside {stats(base[m])['inside']:.1f}% "
                                f"score {score(base[m]):.0f}" for m in HORIZONS), f"| line<70 on lows {bl[0]}/{bl[1]}")
    for name, sh, sc, only in (("shift + scale", True, True, None), ("scale only", False, True, None),
                               ("shift only", True, False, None), ("shift >180 only", True, False, BANDS[2:])):
        for k in ((0,) if not sh else (0, 10, 30)):
            new = tweak(pts, k, sh, sc, only)
            cells = []
            for m in HORIZONS:
                nm = [p for p in new if p["m"] == m]
                better = n_days = 0
                for d in days:
                    o = [p for p in base[m] if p["day"] == d]
                    if not o:
                        continue
                    nn = [p for p in nm if p["day"] == d]
                    n_days += 1
                    if sh:
                        better += sum(abs(p["a"] - p["f"]) for p in nn) < sum(abs(p["a"] - p["f"]) for p in o)
                    else:
                        better += score(nn) < score(o)
                cells.append(f"{m}: miss {100 * (stats(nm)['mae'] / stats(base[m])['mae'] - 1):+5.1f}% "
                             f"inside {stats(nm)['inside']:.1f}% score {100 * (score(nm) / score(base[m]) - 1):+5.1f}% "
                             f"days {better}/{n_days}")
            lw = lows(new)
            print(f"{name:<15} k {k:<2} " + " | ".join(cells) + f" | lows {lw[0]}/{lw[1]}")
            for b in BANDS:
                bc = []
                for m in HORIZONS:
                    o = [p for p in base[m] if p["band"] == b]
                    nn = [p for p in new if p["m"] == m and p["band"] == b]
                    if o:
                        bc.append(f"{m}: miss {stats(o)['mae']:.1f}->{stats(nn)['mae']:.1f} "
                                  f"inside {stats(o)['inside']:.0f}->{stats(nn)['inside']:.0f}%")
                print(f"    {b:<8} " + " | ".join(bc))


def main():
    pts = load(sys.argv[1])
    print(f"{len(pts)} points, {min(p['day'] for p in pts)} to {max(p['day'] for p in pts)}")
    table(pts, "All ranges")
    table([p for p in pts if p["t"] >= WIDE_FROM], "Ranges from 14 Nov on")
    by_day(pts)
    compare(pts)


if __name__ == "__main__":
    main()
