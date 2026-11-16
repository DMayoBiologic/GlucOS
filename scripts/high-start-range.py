#!/usr/bin/env python3
"""Range bottoms on forecasts that start high, and the high-start lower widening (docs/ForecastAccuracy.md §41).

Input: the shown forecast points exported with the query at the top of scripts/low-start-range.py
(15, 30 and 60 minutes; add 45 and 90 to the `in (...)` list to check those too).

Usage: python3 -I scripts/high-start-range.py points.txt
"""
import importlib.util
import os
import statistics as st
import sys

HIGH = 180          # forecasts starting over this (mg/dL) get the extra lower widening
EPISODE_GAP = 7200  # points more than 2 h apart belong to different highs

_spec = importlib.util.spec_from_file_location('lsr', os.path.join(os.path.dirname(__file__), 'low-start-range.py'))
lsr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lsr)


def down_ratio(r):
    """How far below the forecast it landed, in units of the shown lower half."""
    d = r['f'] - r['lo']
    return max(r['f'] - r['a'], 0) / d if d > 0 else 9


def scored(r, c):
    """Inside?, width, interval score (80%) with the lower half widened c times (down to the sensor floor)."""
    lo = max(40, r['f'] - (r['f'] - r['lo']) * c)
    a, hi = r['a'], r['hi']
    excess = lo - a if a < lo else a - hi if a > hi else 0
    return lo <= a <= hi, hi - lo, (hi - lo) + 10 * excess


def fmt(s):
    if not s:
        return '-'
    return (f"n={len(s):3d} inside={100 * sum(x[0] for x in s) / len(s):3.0f}% "
            f"width={st.mean(x[1] for x in s):5.1f} score={st.mean(x[2] for x in s):6.1f}")


def held_out(rows, key, m):
    """Each group left out in turn, the factor learnt on the rest (what would have held 4 in 5)."""
    before, after, wins, n, factors = [], [], 0, 0, []
    for k in sorted({key(r) for r in rows}):
        train = [r for r in rows if key(r) != k and r['m'] == m]
        test = [r for r in rows if key(r) == k and r['m'] == m]
        if not test or len(train) < 10:
            continue
        c = max(1, lsr.q80([down_ratio(r) for r in train]))
        b, w = [scored(r, 1) for r in test], [scored(r, c) for r in test]
        before += b; after += w; n += 1; factors.append(round(c, 2))
        wins += st.mean(x[2] for x in w) < st.mean(x[2] for x in b)
    return before, after, wins, n, factors


def main(path):
    rows = lsr.load(path)
    high = sorted([r for r in rows if r['s'] > HIGH], key=lambda r: r['t'])
    episode, last = -1, None
    for r in high:
        if last is None or r['t'] - last > EPISODE_GAP:
            episode += 1
        r['ep'], last = episode, r['t']
    for m in sorted({r['m'] for r in high}):
        a = [r for r in high if r['m'] == m]
        print(f"== {m} min, start > {HIGH}: {fmt([scored(r, 1) for r in a])} "
              f"below={sum(r['a'] < r['lo'] for r in a)} above={sum(r['a'] > r['hi'] for r in a)} "
              f"bias={st.mean(r['a'] - r['f'] for r in a):+.1f} factor(all)={lsr.q80([down_ratio(r) for r in a]):.2f}")
        for name, key in (('high', lambda r: r['ep']), ('day', lambda r: r['day'])):
            b, w, wins, n, fs = held_out(high, key, m)
            if b:
                print(f"   leave one {name} out: shipped {fmt(b)} | widened {fmt(w)} | better on {wins}/{n} | factors {fs}")


if __name__ == '__main__':
    main(sys.argv[1])
