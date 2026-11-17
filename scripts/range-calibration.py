#!/usr/bin/env python3
"""Does the drawn range hold its 80% at each horizon, and would one fixed factor per horizon help?
(docs/ForecastAccuracy.md §53)

Uses the same export, cleaning and as-drawn-today step as scripts/adaptive-range.py (§42): clean
shown points only (nothing logged after), §40/§41 applied to points drawn before those versions.
For each horizon it prints coverage (inside, above, below), then fits one factor c per horizon
(and per source: apps, relay) as the 80th percentile of the points' miss ratios, so that c times
the drawn half-width holds 80% in sample. That factor is then checked held out two ways:
leave-one-day-out (fit on every other day) and walk-forward (fit on days before only, min 30
points). A factor can't move the central line, so absolute error is unchanged by construction;
"score" is the interval score at 80% (width + 10 x distance outside), lower is better.

Usage: python3 -I scripts/range-calibration.py points.txt
"""
import importlib.util
import os
import statistics as st
import sys

spec = importlib.util.spec_from_file_location('ar', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'adaptive-range.py'))
ar = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ar)

HORIZONS = (15, 30, 45, 60, 90, 120)


def fit(rs):
    xs = [r['ratio'] for r in rs if r['ratio'] is not None]
    return ar.q80(xs) if len(xs) >= 30 else 1.0


def summary(rs, cs):
    s = [ar.score(r, cs[id(r)]) for r in rs]
    return (100 * sum(x[0] for x in s) / len(s), st.mean(x[1] for x in s), st.mean(x[2] for x in s),
            sum(x[3] < 70 for x, r in zip(s, rs) if r['a'] < 70))


def main(path):
    clean = [r for r in ar.load(path) if not r['log'] and r['shown']
             and not (r['ver'] == (0,) and r['t'] >= ar.WIDENING_FROM)]
    for r in clean:
        ar.as_drawn_today(r)
        r['ratio'] = ar.ratio(r)
    days = sorted({r['day'] for r in clean})
    print(f"{len(clean)} clean points, {days[0]}..{days[-1]} (Perth)")
    print("horizon  n    inside above below  mae   in-sample c  (apps / relay)")
    for m in HORIZONS:
        rs = [r for r in clean if r['m'] == m]
        if len(rs) < 20:
            continue
        ab = sum(r['a'] > r['hi'] for r in rs)
        be = sum(r['a'] < r['lo'] for r in rs)
        mae = st.mean(abs(r['a'] - r['f']) for r in rs)
        apps = [r for r in rs if r['dev'] != 'r']
        rel = [r for r in rs if r['dev'] == 'r']
        print(f"{m:5d} {len(rs):5d}  {100 - 100 * (ab + be) / len(rs):5.0f}% {100 * ab / len(rs):4.0f}% {100 * be / len(rs):4.0f}%"
              f"  {mae:5.1f}  {fit(rs):5.2f}  ({fit(apps):.2f} / {fit(rel) if len(rel) >= 30 else float('nan'):.2f})")
    print("\nheld out: shown -> leave-one-day-out -> walk-forward   inside% / width / score / lows with bottom<70")
    for m in HORIZONS:
        rs = [r for r in clean if r['m'] == m]
        if len(rs) < 60:
            continue
        base = {id(r): 1.0 for r in rs}
        lodo, wf = {}, {}
        for d in days:
            test = [r for r in rs if r['day'] == d]
            for split, out in ((lambda r: r['day'] != d, lodo), (lambda r: r['day'] < d, wf)):
                for g in (False, True):
                    c = fit([r for r in rs if split(r) and (r['dev'] == 'r') == g])
                    for r in test:
                        if (r['dev'] == 'r') == g:
                            out[id(r)] = c
        parts = []
        for C in (base, lodo, wf):
            i, w, s, lo = summary(rs, C)
            parts.append(f"{i:3.0f}% w{w:6.1f} s{s:6.1f} lo{lo}")
        per_day = []
        for d in days:
            t = [r for r in rs if r['day'] == d]
            if len(t) >= 10:
                per_day.append('+' if summary(t, lodo)[2] < summary(t, base)[2] - 0.05 else '-')
        print(f"{m:5d}  {' -> '.join(parts)}  LODO days better {''.join(per_day)}")


if __name__ == '__main__':
    main(sys.argv[1])
