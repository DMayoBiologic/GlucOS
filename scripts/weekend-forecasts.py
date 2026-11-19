#!/usr/bin/env python3
"""ForecastAccuracy §97: forecast error on weekends against weekdays, by Perth time of day.

Input: a points file, one clean shown point per line (nothing logged after, drawn), from
glucos.forecast_checks:

    issued_epoch,device,basis,start_mgdl,minutes,forecast,actual,lower,upper

Export it in the Supabase SQL editor with the query in docs/ForecastAccuracy.md §97 (the
`string_agg` one), save the `rows` value, and pass the path:

    python3 scripts/weekend-forecasts.py points.csv

Prints, per side (weekday / weekend, Saturday and Sunday in Perth) and time of day (night
0-6, morning 6-12, afternoon 12-18, evening 18-24): points, days, bias (actual - forecast,
positive = line low), mean miss, no-change miss, inside-the-range rate and range width; the
same restricted to ranges from 14 Nov on; per Perth day; and the held-out tweak (a mean shift
and a range-width scale learnt per side x time of day x horizon, leave one Perth day out).
"""
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

PERTH = timezone(timedelta(hours=8))
WIDE_FROM = datetime(2026, 11, 14, tzinfo=PERTH).timestamp()  # ranges widened by then (§96)
HORIZONS = (15, 30, 60)
BANDS = ("night", "morning", "afternoon", "evening")


def load(path):
    pts = []
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        t, dev, basis, start, m, f, a, lo, hi = line.split(",")
        t = int(t)
        lt = datetime.fromtimestamp(t, PERTH)
        pts.append(dict(t=t, dev=dev, basis=basis, start=float(start), m=int(m), f=float(f),
                        a=float(a), lo=float(lo), hi=float(hi), day=lt.date(),
                        side="weekend" if lt.weekday() >= 5 else "weekday",
                        band=BANDS[lt.hour // 6]))
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
        width=sum(p["hi"] - p["lo"] for p in ps) / n)


def row(label, s):
    if s is None:
        return f"{label:<28} -"
    return (f"{label:<28} n {s['n']:>4} days {s['days']} bias {s['bias']:+6.1f} miss {s['mae']:5.1f}"
            f" no-change {s['nc']:5.1f} inside {s['inside']:5.1f}% width {s['width']:4.0f}")


def table(pts, title):
    print(f"\n== {title}")
    for m in HORIZONS:
        print(f"-- {m} min")
        for side in ("weekday", "weekend"):
            for band in BANDS:
                print(row(f"{side} {band}", stats([p for p in pts if p["m"] == m and p["side"] == side and p["band"] == band])))
            print(row(f"{side} all", stats([p for p in pts if p["m"] == m and p["side"] == side])))


def by_day(pts):
    print("\n== By Perth day (bias / miss / no-change / inside)")
    for d in sorted({p["day"] for p in pts}):
        cells = []
        for m in HORIZONS:
            s = stats([p for p in pts if p["day"] == d and p["m"] == m])
            cells.append("-" if s is None else f"{m}: n {s['n']} {s['bias']:+.1f}/{s['mae']:.1f}/{s['nc']:.1f}/{s['inside']:.0f}%")
        print(d.strftime("%a %d"), " | ".join(cells))


def tweak(pts, key, k):
    """Leave one Perth day out: shift line and range by the shrunk mean miss of the other days'
    points in the same cell, and scale the range about the line so the other days' cell would be
    80% inside (never below 1x, cap 2.5x, like ForecastLedger.rangeScale). Returns new points."""
    out = []
    for p in pts:
        train = [q for q in pts if q["day"] != p["day"] and q["m"] == p["m"] and key(q) == key(p)]
        d = sum(q["a"] - q["f"] for q in train) / (len(train) + k) if len(train) >= 5 else 0.0
        scale = 1.0
        if len(train) >= 10:
            for s in [1 + i * 0.05 for i in range(31)]:
                ins = sum((q["f"] + d - s * (q["f"] - q["lo"])) <= q["a"] <= (q["f"] + d + s * (q["hi"] - q["f"])) for q in train)
                scale = s
                if ins >= 0.8 * len(train):
                    break
        out.append(dict(p, f=p["f"] + d, lo=p["f"] + d - scale * (p["f"] - p["lo"]),
                        hi=p["f"] + d + scale * (p["hi"] - p["f"])))
    return out


def lows(ps):
    hit = [p for p in ps if p["a"] < 70]
    return sum(p["lo"] < 70 for p in hit), len(hit)


def compare(pts):
    print("\n== Held out (leave one Perth day out): miss change vs shipped, inside, lows caught")
    base = {m: stats([p for p in pts if p["m"] == m]) for m in HORIZONS}
    bl = lows(pts)
    print("shipped", " ".join(f"{m}: {base[m]['mae']:.1f} {base[m]['inside']:.1f}%" for m in HORIZONS), f"lows {bl[0]}/{bl[1]}")
    keys = {
        "side x band": lambda p: (p["side"], p["band"]),
        "band only (pool)": lambda p: p["band"],
        "side only": lambda p: p["side"],
    }
    days = sorted({p["day"] for p in pts})
    for name, key in keys.items():
        for k in (0, 10, 30):
            new = tweak(pts, key, k)
            cells = []
            for m in HORIZONS:
                s = stats([p for p in new if p["m"] == m])
                better = 0
                wk_better = wk_days = 0
                for d in days:
                    o = [p for p in pts if p["m"] == m and p["day"] == d]
                    if not o:
                        continue
                    nn = [p for p in new if p["m"] == m and p["day"] == d]
                    b = sum(abs(p["a"] - p["f"]) for p in nn) < sum(abs(p["a"] - p["f"]) for p in o)
                    better += b
                    if o[0]["side"] == "weekend":
                        wk_days += 1
                        wk_better += b
                cells.append(f"{m}: {100 * (s['mae'] / base[m]['mae'] - 1):+5.1f}% {s['inside']:.1f}% "
                             f"days {better}/{sum(1 for d in days if any(p['day'] == d and p['m'] == m for p in pts))} wkend {wk_better}/{wk_days}")
            lw = lows(new)
            print(f"{name:<17} k {k:<2} " + " | ".join(cells) + f" | lows {lw[0]}/{lw[1]}")


def main():
    pts = load(sys.argv[1])
    print(f"{len(pts)} points, {min(p['day'] for p in pts)} to {max(p['day'] for p in pts)}")
    table(pts, "All ranges")
    table([p for p in pts if p["t"] >= WIDE_FROM], "Ranges from 14 Nov on")
    by_day(pts)
    compare(pts)


if __name__ == "__main__":
    main()
