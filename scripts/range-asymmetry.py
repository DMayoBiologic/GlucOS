#!/usr/bin/env python3
"""Do forecast misses lean one way, and would lopsided range widths help? (docs/ForecastAccuracy.md §62)

Uses the export, cleaning and as-drawn-today step of scripts/adaptive-range.py (§42): clean shown
points only (nothing logged after), §40/§41 applied to points drawn before those versions.

Part 1 prints, per horizon, how many misses land above the range and how many below, split by
source and by trend (falling < -0.5, steady, rising > 0.5 mg/dL/min), with a binomial check of
"above and below equally likely" and the number of days on which each side wins.

Part 2 tries asymmetric widths: the upper half-width times cu and the lower times cd, where cu and
cd are fitted per horizon (optionally per trend bucket) as the 90th percentile of each side's miss
ratio, so each side would miss 1 in 10. "Neutral" then rescales both so the average width of the
fitted points is unchanged, which moves width from the side that misses less to the side that
misses more without widening overall. Held out two ways: leave-one-day-out and walk-forward (days
before only, min 30 points per group, else 1 x 1). Score = interval score at 80% (width + 10 x
distance outside), lower is better. "low<" = actuals under 70 that land below the range.

Usage: python3 -I scripts/range-asymmetry.py points.txt
"""
import importlib.util
import math
import os
import statistics as st
import sys

spec = importlib.util.spec_from_file_location('ar', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'adaptive-range.py'))
ar = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ar)

HORIZONS = (15, 30, 45, 60)
MIN_FIT = 30


def bucket(r):
    tr = r['tr']
    return 'fall' if tr < -0.5 else 'rise' if tr > 0.5 else 'steady'


def sides(r):
    """Shown half-widths, with a side clipped at the sensor limit taken from the other side."""
    up, dn = r['hi'] - r['f'], r['f'] - r['lo']
    ch, cl = r['hi'] >= ar.HIGH_CLIP - 1, r['lo'] <= ar.LOW_CLIP + 1
    if ch and cl:
        return None
    if ch:
        up = dn
    if cl:
        dn = up
    if up <= 0.5 or dn <= 0.5:
        return None
    return up, dn


def q(xs, p):
    xs = sorted(xs)
    i = p * (len(xs) - 1)
    a = int(i)
    b = min(a + 1, len(xs) - 1)
    return xs[a] + (xs[b] - xs[a]) * (i - a)


def fit(rs, neutral):
    rs = [r for r in rs if r['sd'] is not None]
    if len(rs) < MIN_FIT:
        return 1.0, 1.0
    ru = [max(0.0, (r['a'] - r['f']) / r['sd'][0]) for r in rs]
    rd = [max(0.0, (r['f'] - r['a']) / r['sd'][1]) for r in rs]
    cu, cd = q(ru, 0.9), q(rd, 0.9)
    if neutral:
        w0 = sum(u + d for u, d in (r['sd'] for r in rs))
        w1 = sum(cu * u + cd * d for u, d in (r['sd'] for r in rs))
        lam = w0 / w1 if w1 > 0 else 1
        cu, cd = cu * lam, cd * lam
    return cu, cd


def score(r, c):
    cu, cd = c
    hi = min(401, r['f'] + (r['hi'] - r['f']) * cu)
    lo = max(39, r['f'] - (r['f'] - r['lo']) * cd)
    a = r['a']
    ex = lo - a if a < lo else a - hi if a > hi else 0
    return lo <= a <= hi, hi - lo, (hi - lo) + 10 * ex, a < lo and a < 70, a > hi, a < lo


def summ(rs, C):
    s = [score(r, C.get(id(r), (1, 1))) for r in rs]
    n = len(s)
    return (100 * sum(x[0] for x in s) / n, st.mean(x[1] for x in s), st.mean(x[2] for x in s),
            sum(x[3] for x in s), 100 * sum(x[4] for x in s) / n, 100 * sum(x[5] for x in s) / n)


def binom_p(k, n):
    """Two-sided exact test of k of n against 1/2."""
    if n == 0:
        return 1.0
    pk = [math.comb(n, i) / 2 ** n for i in range(n + 1)]
    return min(1.0, sum(p for p in pk if p <= pk[k] + 1e-12))


def main(path):
    rows = ar.load(path)
    # ar.load drops the trend column; read it back in the same order (same 13-field filter).
    trends = [float(f[8]) for f in (x.strip().split(',') for x in open(path).read().replace('\n', ';').split(';')) if len(f) >= 13]
    for r, tr in zip(rows, trends):
        r['tr'] = tr
    clean = [r for r in rows if not r['log'] and r['shown']
             and not (r['ver'] == (0,) and r['t'] >= ar.WIDENING_FROM)]
    for r in clean:
        ar.as_drawn_today(r)
        r['sd'] = sides(r)
    days = sorted({r['day'] for r in clean})
    print(f"{len(clean)} clean drawn points, {days[0]}..{days[-1]} (Perth)\n")

    print("Part 1: which side do misses land on")
    print("horizon group     n  inside above below  p(equal)  days above>below / below>above   median miss outside")
    for m in HORIZONS:
        rs = [r for r in clean if r['m'] == m]
        groups = [('all', rs), ('apps', [r for r in rs if r['dev'] != 'r']), ('relay', [r for r in rs if r['dev'] == 'r'])]
        groups += [(b, [r for r in rs if bucket(r) == b]) for b in ('fall', 'steady', 'rise')]
        for name, g in groups:
            if len(g) < 15:
                continue
            ab = [r['a'] - r['hi'] for r in g if r['a'] > r['hi']]
            be = [r['lo'] - r['a'] for r in g if r['a'] < r['lo']]
            da = db = 0
            for d in days:
                t = [r for r in g if r['day'] == d]
                x, y = sum(r['a'] > r['hi'] for r in t), sum(r['a'] < r['lo'] for r in t)
                da += x > y
                db += y > x
            med = lambda xs: st.median(xs) if xs else float('nan')
            print(f"{m:5d}  {name:7s} {len(g):4d}  {100 - 100 * (len(ab) + len(be)) / len(g):4.0f}%  {100 * len(ab) / len(g):4.0f}% {100 * len(be) / len(g):4.0f}%"
                  f"  {binom_p(len(ab), len(ab) + len(be)):6.3f}    {da} / {db}"
                  f"    above {med(ab):5.1f}  below {med(be):5.1f}")
        print()

    print("Part 2: asymmetric widths, held out   inside% (above%/below%) / width / score / low<")
    variants = [('per horizon, q90 each side', False, False), ('per horizon, width-neutral', True, False),
                ('per horizon x trend, q90', False, True), ('per horizon x trend, neutral', True, True)]
    for m in HORIZONS:
        rs = [r for r in clean if r['m'] == m]
        if len(rs) < 60:
            continue
        i, w, s, lo, a, b = summ(rs, {})
        print(f"{m} min, {len(rs)} points. shown: {i:3.0f}% ({a:.0f}/{b:.0f}) w{w:6.1f} s{s:6.1f} low<{lo}")
        insample = fit(rs, False)
        print(f"   in-sample q90 factors up {insample[0]:.2f} down {insample[1]:.2f};"
              f" neutral {fit(rs, True)[0]:.2f} / {fit(rs, True)[1]:.2f}")
        for name, neutral, by_trend in variants:
            key = (lambda r: (r['dev'] == 'r', bucket(r))) if by_trend else (lambda r: r['dev'] == 'r')
            for label, split in (('LODO', lambda r, d: r['day'] != d), ('walk-fwd', lambda r, d: r['day'] < d)):
                C = {}
                for d in days:
                    test = [r for r in rs if r['day'] == d]
                    train = [r for r in rs if split(r, d)]
                    for k in {key(r) for r in test}:
                        c = fit([r for r in train if key(r) == k], neutral)
                        for r in test:
                            if key(r) == k:
                                C[id(r)] = c
                i, w, s, lo, a, b = summ(rs, C)
                better = sum(summ(t, C)[2] < summ(t, {})[2] - 0.05 for t in ([r for r in rs if r['day'] == d] for d in days) if len(t) >= 10)
                worse = sum(summ(t, C)[2] > summ(t, {})[2] + 0.05 for t in ([r for r in rs if r['day'] == d] for d in days) if len(t) >= 10)
                print(f"   {name:30s} {label:8s} {i:3.0f}% ({a:.0f}/{b:.0f}) w{w:6.1f} s{s:6.1f} low<{lo}  days better/worse {better}/{worse}")
        print()


if __name__ == '__main__':
    main(sys.argv[1])
