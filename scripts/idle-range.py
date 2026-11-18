#!/usr/bin/env python3
"""Does the drawn range hold its 80% in daytime stretches with nothing logged, and would widening
it there help? (docs/ForecastAccuracy.md §75)

Same export, cleaning and as-drawn-today step as scripts/adaptive-range.py (§42): clean shown
points only (nothing logged after), §40/§41 applied to points drawn before those versions.
A point is "idle" when it was issued in the daytime (07:00-22:00 Perth) and no non-deleted
Logbook entry of any kind came in the IDLE_H hours before it (or none ever). Everything else
("rest") is daytime-active plus night. The widening is one factor c per horizon, applied to idle
points only: the 80th percentile of the idle points' miss ratios, fitted held out by
leave-one-day-out and walk-forward (days before only, min 30 points), clamped to >= 1 so it can
only widen. Rest points keep their drawn range, so nothing widens elsewhere by construction.
"score" is the interval score at 80% (width + 10 x distance outside), lower is better.

Input: points.txt from the adaptive-range.py export, and log.txt from

    select string_agg(concat_ws(',', round((payload->>'timestamp')::float)::bigint, kind,
      coalesce(payload->>'kind','')), ';' order by (payload->>'timestamp')::float)
    from glucos.logbook where not deleted and payload->>'timestamp' is not null;

Usage: python3 -I scripts/idle-range.py points.txt log.txt [idle_hours=5]
"""
import bisect
import datetime as dt
import importlib.util
import os
import statistics as st
import sys

spec = importlib.util.spec_from_file_location('ar', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'adaptive-range.py'))
ar = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ar)

HORIZONS = (15, 30, 45, 60)
DAY_FROM, DAY_TO = 7, 22


def fit(rs, clamp=True):
    xs = [r['ratio'] for r in rs if r['ratio'] is not None]
    if len(xs) < 30:
        return 1.0
    c = ar.q80(xs)
    return max(1.0, c) if clamp else c


def summ(rs, C):
    if not rs:
        return 0, float('nan'), float('nan'), float('nan'), 0, 0
    s = [ar.score(r, C.get(id(r), 1.0)) for r in rs]
    lows = [(x, r) for x, r in zip(s, rs) if r['a'] < 70]
    return (len(s), 100 * sum(x[0] for x in s) / len(s), st.mean(x[1] for x in s), st.mean(x[2] for x in s),
            len(lows), sum(x[0] for x, _ in lows))


def fmt(t):
    n, i, w, s, nl, il = t
    return f"n{n:4d} in{i:4.0f}% w{w:6.1f} s{s:6.1f} lows {il}/{nl}"


def main(points, log, idle_h=5.0):
    stamps = sorted(int(x.split(',')[0]) for x in open(log).read().split(';') if x.strip())
    clean = [r for r in ar.load(points) if not r['log'] and r['shown']
             and not (r['ver'] == (0,) and r['t'] >= ar.WIDENING_FROM)]
    for r in clean:
        ar.as_drawn_today(r)
        r['ratio'] = ar.ratio(r)
        hour = dt.datetime.fromtimestamp(r['t'] + 8 * 3600, dt.timezone.utc).hour
        k = bisect.bisect_right(stamps, r['t'])
        since = (r['t'] - stamps[k - 1]) / 3600 if k else None
        r['daytime'] = DAY_FROM <= hour < DAY_TO
        r['idle'] = r['daytime'] and (since is None or since >= idle_h)
    days = sorted({r['day'] for r in clean})
    print(f"{len(clean)} clean points, {days[0]}..{days[-1]} (Perth), {len(stamps)} Logbook entries, idle = daytime and {idle_h:g} h+ since one")
    print("\ncoverage as drawn (inside / above / below, mae, idle days)")
    for m in HORIZONS:
        rs = [r for r in clean if r['m'] == m]
        for name, g in (('idle', [r for r in rs if r['idle']]), ('day-active', [r for r in rs if r['daytime'] and not r['idle']]),
                        ('night', [r for r in rs if not r['daytime']]), ('rest', [r for r in rs if not r['idle']])):
            if not g:
                continue
            ab = sum(r['a'] > r['hi'] for r in g)
            be = sum(r['a'] < r['lo'] for r in g)
            print(f"{m:3d} {name:10s} n{len(g):4d}  {100 - 100 * (ab + be) / len(g):4.0f}% {100 * ab / len(g):4.0f}% {100 * be / len(g):4.0f}%"
                  f"  mae {st.mean(abs(r['a'] - r['f']) for r in g):5.1f}  days {len({r['day'] for r in g})}")
    print("\nheld out widening on idle points only (rest unchanged): drawn | LODO | walk-forward; then idle per-day score drawn->LODO")
    for m in HORIZONS:
        rs = [r for r in clean if r['m'] == m]
        idle = [r for r in rs if r['idle']]
        if len(idle) < 30:
            print(f"{m:3d}: only {len(idle)} idle points, not fitted")
            continue
        lodo, wf, cs = {}, {}, []
        for d in days:
            test = [r for r in idle if r['day'] == d]
            if not test:
                continue
            c1 = fit([r for r in idle if r['day'] != d])
            c2 = fit([r for r in idle if r['day'] < d])
            cs.append((d, c1, c2))
            for r in test:
                lodo[id(r)] = c1
                wf[id(r)] = c2
        print(f"{m:3d} in-sample c {fit(idle, False):.2f}; per held-out day (LODO/WF): " + ' '.join(f"{d[5:]} {a:.2f}/{b:.2f}" for d, a, b in cs))
        for label, g in (('idle', idle), ('all', rs)):
            print(f"    {label:4s} " + ' | '.join(fmt(summ(g, C)) for C in ({}, lodo, wf)))
        wins = []
        for d in days:
            t = [r for r in idle if r['day'] == d]
            if t:
                a, b = summ(t, {})[3], summ(t, lodo)[3]
                wins.append(b < a)
                print(f"      {d} n{len(t):3d} s {a:6.1f} -> {b:6.1f}")
        print(f"    LODO wins on {sum(wins)}/{len(wins)} idle days")


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2], float(sys.argv[3]) if len(sys.argv) > 3 else 5.0)
