#!/usr/bin/env python3
"""Range coverage at 15/30/60 minutes, and the low-start upper widening (docs/ForecastAccuracy.md §40).

Input: a file of shown forecast points, one per line or ';'-separated, as exported with

    select string_agg(concat_ws(',', extract(epoch from c.issued_at)::bigint, left(c.device,1),
      (e->>'minutes'), round((e->>'mgdl')::numeric), round((e->>'lower')::numeric),
      round((e->>'upper')::numeric), round((e->>'actual')::numeric), round(c.start_mgdl::numeric),
      round(c.trend_per_minute::numeric,2), case when (e->>'after_log')::boolean then 1 else 0 end,
      case when coalesce(c.extra,false) then 1 else 0 end, c.basis, array_to_string(c.limitations,'|')),
      ';' order by c.issued_at)
    from glucos.forecast_checks c, jsonb_array_elements(c.points) e
    where (e->>'minutes')::int in (15,30,60) and e->>'actual' is not null;

Usage: python3 -I scripts/low-start-range.py points.txt
"""
import datetime as dt
import statistics as st
import sys

LOW = 80          # forecasts starting under this (mg/dL) get the extra upper widening
EPISODE_GAP = 7200  # points more than 2 h apart belong to different lows


def load(path):
    rows = []
    for line in open(path).read().replace('\n', ';').split(';'):
        f = line.strip().split(',')
        if len(f) < 12:
            continue
        r = dict(t=int(f[0]), dev=f[1], m=int(f[2]), f=float(f[3]), lo=float(f[4]), hi=float(f[5]),
                 a=float(f[6]), s=float(f[7]), lim=f[12] if len(f) > 12 else '')
        r['day'] = dt.datetime.fromtimestamp(r['t'] + 8 * 3600, dt.timezone.utc).date().isoformat()
        rows.append(r)
    return rows


def q80(xs):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(0.8 * len(xs)))] if xs else 1


def up_ratio(r):
    """How far above the forecast it landed, in units of the shown upper half."""
    u = r['hi'] - r['f']
    return max(r['a'] - r['f'], 0) / u if u > 0 else 9


def scored(r, c):
    """Inside?, width, interval score (80%) with the upper half widened c times."""
    hi = r['f'] + (r['hi'] - r['f']) * c
    a, lo = r['a'], r['lo']
    excess = lo - a if a < lo else a - hi if a > hi else 0
    return lo <= a <= hi, hi - lo, (hi - lo) + 10 * excess


def summary(rs, c=lambda r: 1):
    s = [scored(r, c(r)) for r in rs]
    if not s:
        return '-'
    return (f"n={len(s):3d} inside={100 * sum(x[0] for x in s) / len(s):3.0f}% "
            f"width={st.mean(x[1] for x in s):5.1f} score={st.mean(x[2] for x in s):6.1f}")


def main(path):
    rows = load(path)
    for m in (15, 30, 60):
        a = [r for r in rows if r['m'] == m]
        print(f"== {m} min: all {summary(a)}")
        for d in sorted({r['day'] for r in a}):
            print(f"   {d} {summary([r for r in a if r['day'] == d])}")
        print(f"   start < {LOW}: {summary([r for r in a if r['s'] < LOW])}")
    # Leave one low episode out: the upper factor learnt on the other lows.
    low = sorted([r for r in rows if r['s'] < LOW and 'lowTreatment' not in r['lim']], key=lambda r: r['t'])
    episode, last = -1, None
    for r in low:
        if last is None or r['t'] - last > EPISODE_GAP:
            episode += 1
        r['ep'], last = episode, r['t']
    for m in (15, 30, 60):
        before, after, wins, n, factors = [], [], 0, 0, []
        for e in range(episode + 1):
            train = [r for r in low if r['ep'] != e and r['m'] == m]
            test = [r for r in low if r['ep'] == e and r['m'] == m]
            if not test or len(train) < 5:
                continue
            c = max(1, q80([up_ratio(r) for r in train]))
            b, w = [scored(r, 1) for r in test], [scored(r, c) for r in test]
            before += b; after += w; n += 1; factors.append(round(c, 1))
            wins += st.mean(x[2] for x in w) < st.mean(x[2] for x in b)
        if not before:
            continue
        def fmt(s):
            return (f"inside {100 * sum(x[0] for x in s) / len(s):3.0f}% width {st.mean(x[1] for x in s):5.1f} "
                    f"score {st.mean(x[2] for x in s):6.1f}")
        print(f"held out {m:2d} min, {len(before)} points on {n} lows: shipped {fmt(before)} | widened {fmt(after)} "
              f"| better on {wins}/{n} | factors {factors} | all lows {q80([up_ratio(r) for r in low if r['m'] == m]):.2f}")


if __name__ == '__main__':
    main(sys.argv[1])
