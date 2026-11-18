#!/usr/bin/env python3
"""Forecast error and range coverage after stacked rapid insulin (docs/ForecastAccuracy.md §85).

Stacked: a rapid dose logged within 60 minutes after another rapid dose (s60). Doses 61-90 minutes
apart are kept as a near-stacked group (s90) so there is more than one pair to hold out. A forecast
point belongs to the latest rapid dose in the 4 hours before it was issued; the group summary for
single doses and no recent dose is the SQL in scripts/stacked-insulin.sql.

Tweak (range width only, never the line, IOB curve or sensitivity): one factor per horizon scaling
the drawn range's distance above and below the line for points after a stacked or near-stacked
pair. Fitted leave-one-pair-out as the 80th percentile of the other pair's miss ratios
(|actual - line| / half-width on the side the reading fell), clamped to 0.6..2.5. Score is the 80%
interval score (width + 10 x distance outside), lower is better. The bar: better held out at 30 AND
60 on every held-out pair, and no reading under 70 dropped out of the range.

Input: stacked.txt, one ';'-separated line of t,device,minutes,line,lower,upper,actual,dose,group
for clean shown points (scripts/stacked-insulin.sql, second query).

Usage: python3 -I scripts/stacked-insulin.py stacked.txt
"""
import datetime as dt
import statistics as st
import sys


def load(path):
    out = []
    for row in open(path).read().strip().split(';'):
        t, dev, h, line, lo, up, act, dose, g = row.split(',')
        out.append(dict(t=int(t), dev=dev, h=int(h), line=float(line), lo=float(lo), up=float(up),
                        act=float(act), dose=int(dose), g=g))
    return out


def miss_ratio(p):
    half = (p['up'] - p['line']) if p['act'] >= p['line'] else (p['line'] - p['lo'])
    return abs(p['act'] - p['line']) / max(half, 1e-6)


def scaled(p, c):
    return p['line'] - c * (p['line'] - p['lo']), p['line'] + c * (p['up'] - p['line'])


def score(lo, up, a):
    return (up - lo) + 10 * (max(lo - a, 0) + max(a - up, 0))


def q80(xs):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(0.8 * len(xs)))]


def summary(ps):
    err = [p['act'] - p['line'] for p in ps]
    ins = sum(p['lo'] <= p['act'] <= p['up'] for p in ps) / len(ps)
    below = sum(p['act'] < p['lo'] for p in ps) / len(ps)
    sc = st.mean(score(p['lo'], p['up'], p['act']) for p in ps)
    return (f"{len(ps):2d} pts  MAE {st.mean(map(abs, err)):5.1f}  bias(actual-line) {st.mean(err):+6.1f}  "
            f"inside {ins:4.0%}  below {below:4.0%}  score {sc:6.1f}")


def main():
    pts = load(sys.argv[1])
    pairs = sorted({p['dose'] for p in pts})
    for h in (30, 60):
        print(f'== {h} min ==')
        for d in pairs:
            sel = [p for p in pts if p['h'] == h and p['dose'] == d]
            when = dt.datetime.fromtimestamp(d + 8 * 3600, dt.timezone.utc).strftime('%d %b %H:%M')
            print(f'  {sel[0]["g"]} second dose {when}: {summary(sel)}')
    print('\nHeld-out width factor (leave one pair out):')
    for h in (30, 60):
        for d in pairs:
            train = [p for p in pts if p['h'] == h and p['dose'] != d]
            test = [p for p in pts if p['h'] == h and p['dose'] == d]
            c = min(2.5, max(0.6, q80([miss_ratio(p) for p in train])))
            s0 = st.mean(score(p['lo'], p['up'], p['act']) for p in test)
            s1 = st.mean(score(*scaled(p, c), p['act']) for p in test)
            in0 = sum(p['lo'] <= p['act'] <= p['up'] for p in test)
            in1 = sum(scaled(p, c)[0] <= p['act'] <= scaled(p, c)[1] for p in test)
            lost = sum(p['act'] < 70 and p['lo'] <= p['act'] <= p['up']
                       and not scaled(p, c)[0] <= p['act'] <= scaled(p, c)[1] for p in test)
            when = dt.datetime.fromtimestamp(d + 8 * 3600, dt.timezone.utc).strftime('%d %b')
            print(f'  {h} min, test {when}: c={c:.2f} score {s0:6.1f} -> {s1:6.1f} '
                  f'inside {in0}/{len(test)} -> {in1}/{len(test)} lows lost {lost}')


if __name__ == '__main__':
    main()
