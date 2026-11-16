#!/usr/bin/env python3
"""Range width from the last few hours' scored error (docs/ForecastAccuracy.md §42).

Replays every clean shown point (nothing logged after, drawn) with its range multiplied by a
factor learnt from the points scored in the W hours before it was issued: the 80th percentile
of their miss ratios (|actual - forecast| / shown half-width on that side, a side clipped at the
sensor's limit using the other side), clamped to [floor, cap], once there are N of them. Apps and
relay learn apart. Points shown before §40/§41 reached that device (by app version) get those
widenings first, so the baseline is what's drawn today and nothing is widened twice. The window
is on scoring time: points whose reading came in during the W hours before the forecast.

Input: one ';'-separated line, exported with

    select string_agg(concat_ws(',', extract(epoch from c.issued_at)::bigint, left(c.device,1),
      (e->>'minutes'), round((e->>'mgdl')::numeric,1), round((e->>'lower')::numeric,1),
      round((e->>'upper')::numeric,1), round((e->>'actual')::numeric,1), c.start_mgdl,
      round(c.trend_per_minute::numeric,2), case when (e->>'after_log')::boolean then 1 else 0 end,
      case when coalesce(c.extra,false) then 1 else 0 end, c.basis, coalesce(e->>'shown','true'),
      coalesce(c.app_version, '0'), array_to_string(c.limitations,'|')), ';' order by c.issued_at)
    from glucos.forecast_checks c, jsonb_array_elements(c.points) e where e->>'actual' is not null;

Usage: python3 -I scripts/adaptive-range.py points.txt [--grid]
"""
import datetime as dt
import itertools
import statistics as st
import sys

LOW_CLIP, HIGH_CLIP = 39.5, 400.5
# First versions that draw §40 (low-start upper) and §41 (high-start lower; apps only).
LOW_START_FROM = {'r': (2, 17, 0), 'M': (1, 30, 0), 'i': (1, 30, 0)}
HIGH_START_FROM = {'M': (1, 31, 0), 'i': (1, 31, 0)}
# The first of those went out at 09:33 UTC on 16 Nov 2026. A record with no version from after
# then could already carry them, so it's left out rather than guessed at.
WIDENING_FROM = 1794821580


def load(path):
    rows = []
    for x in open(path).read().replace('\n', ';').split(';'):
        f = x.strip().split(',')
        if len(f) < 13:
            continue
        r = dict(t=int(f[0]), dev=f[1], m=int(f[2]), f=float(f[3]), lo=float(f[4]), hi=float(f[5]),
                 a=float(f[6]), s=float(f[7]), log=f[9] == '1', shown=f[12] == 'true',
                 ver=(0,), lim='')
        rest = f[13:]
        if rest and all(x.isdigit() for x in rest[0].split('.')):
            r['ver'] = tuple(int(x) for x in rest.pop(0).split('.'))
        r['lim'] = rest[0] if rest else ''
        r['day'] = dt.datetime.fromtimestamp(r['t'] + 8 * 3600, dt.timezone.utc).date().isoformat()
        r['due'] = r['t'] + 60 * r['m']
        rows.append(r)
    return rows


def interp(pts, m):
    for (a, fa), (b, fb) in zip(pts, pts[1:]):
        if m <= b:
            return fa + (fb - fa) * (m - a) / (b - a)
    return pts[-1][1]


def as_drawn_today(r):
    """§40 low-start upper and §41 high-start lower widenings, as they ship now, on points drawn
    by a version from before them (later points already carry them)."""
    up = dn = 1
    if r['s'] < 80 and 'lowTreatment' not in r['lim'] and r['ver'] < LOW_START_FROM[r['dev']]:
        up = interp([(0, 1), (15, 2.8), (30, 3.3), (60, 3.6)], r['m'])
    if r['s'] > 180 and r['dev'] in HIGH_START_FROM and r['ver'] < HIGH_START_FROM[r['dev']]:
        dn = interp([(0, 1), (30, 1), (60, 1.7), (90, 1)], r['m'])
    r['hi'] = min(401, r['f'] + (r['hi'] - r['f']) * up)
    r['lo'] = max(39, r['f'] - (r['f'] - r['lo']) * dn)


def ratio(r):
    up, dn = r['hi'] - r['f'], r['f'] - r['lo']
    ch, cl = r['hi'] >= HIGH_CLIP - 1, r['lo'] <= LOW_CLIP + 1
    if ch and cl:
        return None
    if ch:
        up = dn
    if cl:
        dn = up
    if up <= 0.5 or dn <= 0.5:
        return None
    e = r['a'] - r['f']
    return e / up if e >= 0 else -e / dn


def q80(xs):
    xs = sorted(xs)
    i = 0.8 * (len(xs) - 1)
    a = int(i)
    b = min(a + 1, len(xs) - 1)
    return xs[a] + (xs[b] - xs[a]) * (i - a)


def score(r, c):
    hi = min(401, r['f'] + (r['hi'] - r['f']) * c)
    lo = max(39, r['f'] - (r['f'] - r['lo']) * c)
    a = r['a']
    ex = lo - a if a < lo else a - hi if a > hi else 0
    return lo <= a <= hi, hi - lo, (hi - lo) + 10 * ex, lo


def factors(rows, w_hours, n, floor, cap):
    group = lambda r: r['dev'] == 'r'
    pool = [r for r in rows if r['ratio'] is not None]
    out = {}
    for r in rows:
        xs = [p['ratio'] for p in pool if group(p) == group(r) and r['t'] - w_hours * 3600 <= p['due'] <= r['t']]
        out[id(r)] = min(cap, max(floor, q80(xs))) if len(xs) >= n else 1.0
    return out


def summ(rs, F):
    s = [score(r, F.get(id(r), 1)) for r in rs]
    if not s:
        return 0, float('nan'), float('nan'), float('nan')
    return len(s), 100 * sum(x[0] for x in s) / len(s), st.mean(x[1] for x in s), st.mean(x[2] for x in s)


def main(path, grid=False):
    clean = [r for r in load(path) if not r['log'] and r['shown']
             and not (r['ver'] == (0,) and r['t'] >= WIDENING_FROM)]
    for r in clean:
        as_drawn_today(r)
        r['ratio'] = ratio(r)
    days = sorted({r['day'] for r in clean})
    lows = [r for r in clean if r['a'] < 70]
    print(f"{len(clean)} clean points, {days[0]}..{days[-1]}, {len(lows)} landed under 70")
    configs = [None, (6, 20, 0.7, 2), (6, 20, 1, 2), (3, 10, 0.85, 1.5), (3, 10, 1, 2), (12, 20, 1, 2),
               (3, 10, 0.7, 1), (6, 20, 0.7, 1)]
    if grid:
        configs = [None] + [c for c in itertools.product((3, 6, 12, 24), (10, 20, 30), (1, 0.85, 0.7, 0.5), (1, 1.5, 2, 2.5))
                            if c[2:] != (1, 1)]
    for c in configs:
        F = factors(clean, *c) if c else {}
        parts, wins = [], []
        for m in (15, 30, 60):
            rs = [r for r in clean if r['m'] == m]
            n, i, w, s = summ(rs, F)
            if not n:
                parts.append(f"{m}: no points")
                wins.append(0)
                continue
            parts.append(f"{m}: {i:3.0f}% w{w:6.1f} s{s:6.1f}")
            wins.append(sum(summ(d, F)[3] < summ(d, {})[3] - 0.05
                            for d in ([r for r in rs if r['day'] == day] for day in days) if len(d) >= 10))
        held = sum(score(r, F.get(id(r), 1))[3] < 70 for r in lows)
        print(f"{str(c or 'shipped'):20s} {' | '.join(parts)}  days better {wins}  lows with bottom<70 {held}/{len(lows)}")


if __name__ == '__main__':
    main(sys.argv[1], '--grid' in sys.argv[2:])
