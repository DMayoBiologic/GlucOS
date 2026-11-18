#!/usr/bin/env python3
"""Forecast error and range coverage after correction-only rapid doses (docs/ForecastAccuracy.md §87).

Correction: a rapid dose with no meal logged within 60 minutes either side, taken above 180 mg/dL.
Meal-covered: a rapid dose with a meal within 60 minutes. A forecast point belongs to the latest
rapid dose in the 3 hours before it was issued (scripts/correction-doses.sql). Phases: issued 0-60
minutes after the dose ("early") or 60-180 minutes after ("late").

Tweak (range only, never the line, IOB curve or sensitivity): after a correction, one factor per
horizon, phase and side scaling the drawn range's distance below and above the line. Each side's
factor is the 90th percentile of the training points' side ratios (how far the reading fell past the
line on that side / the drawn distance on that side, 0 when it fell on the other side), clamped to
0.6..2.5, fitted only with 8+ training points. Fitted leave-one-Perth-day-out over the correction
days and scored on the held-out day. Score: 80% interval score (width + 10 x distance outside),
lower is better. Bar: better held out on every correction day at 30 AND 60 minutes, and no reading
under 70 dropped out of the range.

Input: one ';'-separated line of t,device,minutes,line,lower,upper,actual,dose,group,start for clean
shown points (scripts/correction-doses.sql, second query).

Usage: python3 -I scripts/correction-doses.py corrections.txt
"""
import datetime as dt
import statistics as st
import sys

PERTH = dt.timezone(dt.timedelta(hours=8))


def load(path):
    out = []
    for row in open(path).read().strip().split(';'):
        t, dev, h, line, lo, up, act, dose, g, s = row.split(',')
        p = dict(t=int(t), dev=dev, h=int(h), line=float(line), lo=float(lo), up=float(up),
                 act=float(act), dose=int(dose), g=g, start=float(s))
        p['phase'] = 'early' if p['t'] - p['dose'] < 3600 else 'late'
        p['day'] = dt.datetime.fromtimestamp(p['dose'], PERTH).strftime('%d %b')
        out.append(p)
    return out


def score(lo, up, a):
    return (up - lo) + 10 * (max(lo - a, 0) + max(a - up, 0))


def q(xs, f):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(f * len(xs)))]


def side_ratios(ps):
    lo = [max(p['line'] - p['act'], 0) / max(p['line'] - p['lo'], 1e-6) for p in ps]
    up = [max(p['act'] - p['line'], 0) / max(p['up'] - p['line'], 1e-6) for p in ps]
    return lo, up


def scaled(p, f):
    cl, cu = f.get((p['h'], p['phase']), (1.0, 1.0))
    return max(39.0, p['line'] - cl * (p['line'] - p['lo'])), p['line'] + cu * (p['up'] - p['line'])


def summary(ps):
    if not ps:
        return ' 0 pts'
    err = [p['act'] - p['line'] for p in ps]
    nc = st.mean(abs(p['act'] - p['start']) for p in ps)
    ins = sum(p['lo'] <= p['act'] <= p['up'] for p in ps) / len(ps)
    below = sum(p['act'] < p['lo'] for p in ps) / len(ps)
    above = sum(p['act'] > p['up'] for p in ps) / len(ps)
    sc = st.mean(score(p['lo'], p['up'], p['act']) for p in ps)
    return (f"{len(ps):3d} pts  MAE {st.mean(map(abs, err)):5.1f} (no change {nc:5.1f})  bias {st.mean(err):+6.1f}  "
            f"inside {ins:4.0%}  below {below:4.0%}  above {above:4.0%}  score {sc:6.1f}")


def fit(train):
    f = {}
    for h in (30, 60):
        for ph in ('early', 'late'):
            sel = [p for p in train if p['h'] == h and p['phase'] == ph]
            if len(sel) < 8:
                continue
            lo, up = side_ratios(sel)
            f[(h, ph)] = tuple(min(2.5, max(0.6, q(r, 0.9))) for r in (lo, up))
    return f


def main():
    pts = load(sys.argv[1])
    for h in (30, 60):
        print(f'== {h} min ==')
        for g in ('correction', 'meal'):
            for ph in ('early', 'late', None):
                sel = [p for p in pts if p['h'] == h and p['g'] == g and ph in (None, p['phase'])]
                print(f'  {g:10s} {ph or "all":5s} {summary(sel)}')
        for d in sorted({p['dose'] for p in pts if p['g'] == 'correction'}):
            sel = [p for p in pts if p['h'] == h and p['dose'] == d]
            when = dt.datetime.fromtimestamp(d, PERTH).strftime('%d %b %H:%M')
            print(f'    correction {when}: {summary(sel)}')
    corr = [p for p in pts if p['g'] == 'correction']
    print('\nHeld-out side factors (leave one Perth day out, correction points):')
    for day in sorted({p['day'] for p in corr}):
        f = fit([p for p in corr if p['day'] != day])
        for h in (30, 60):
            test = [p for p in corr if p['day'] == day and p['h'] == h]
            if not test:
                print(f'  {day} {h} min: no points')
                continue
            s0 = st.mean(score(p['lo'], p['up'], p['act']) for p in test)
            s1 = st.mean(score(*scaled(p, f), p['act']) for p in test)
            in0 = sum(p['lo'] <= p['act'] <= p['up'] for p in test)
            in1 = sum(scaled(p, f)[0] <= p['act'] <= scaled(p, f)[1] for p in test)
            lost = sum(p['act'] < 70 and p['lo'] <= p['act'] <= p['up']
                       and not scaled(p, f)[0] <= p['act'] <= scaled(p, f)[1] for p in test)
            fs = ' '.join(f'{ph}={f[(h, ph)][0]:.2f}/{f[(h, ph)][1]:.2f}' for ph in ('early', 'late')
                          if (h, ph) in f) or 'unfittable'
            print(f'  {day} {h} min: factors(lower/upper) {fs}  score {s0:6.1f} -> {s1:6.1f}  '
                  f'inside {in0}/{len(test)} -> {in1}/{len(test)}  lows lost {lost}')


if __name__ == '__main__':
    main()
