#!/usr/bin/env python3
"""Forecast range in the first hour after a gap in readings ends (docs/ForecastAccuracy.md §86).

Gaps follow the app's rule from PR #388 (Sources/Shared/ReadingGaps.swift): 10 min or more between
stored readings, except LinkUp's 15-minute history step (±90 s). Kind 'r388' uses every stored
reading; kind 'live' uses live readings only, so a stretch LinkUp filled with 15-minute history is
a gap too. Group summaries against normal stretches are the first query in
scripts/post-gap-forecast.sql.

Tweak (range width only, never the line): one factor per horizon scaling the drawn range's
distance above and below the line for points issued in the window after a gap ends (0-30 min, and
as a variant 0-60 min). Fitted leave-one-Perth-day-out as the 80th percentile of the other days'
miss ratios (|actual - line| / half-width on the side the reading fell), never narrower (1.0..2.5),
and only with 10+ training points. Lower ends stay at the sensor floor of 39. Score is the 80%
interval score (width + 10 x distance outside), lower is better. The bar: better held out on every
held-out day at each fittable horizon, and no reading under 70 dropped out of the range.

Input: post-gap.txt, one ';'-separated line of kind,t,device,minutes,line,lower,upper,actual,
gap_end,window for clean shown points (scripts/post-gap-forecast.sql, second query).

Usage: python3 -I scripts/post-gap-forecast.py post-gap.txt
"""
import datetime as dt
import statistics as st
import sys

PERTH = dt.timezone(dt.timedelta(hours=8))
FLOOR = 39.0


def load(path):
    out = []
    for row in open(path).read().strip().split(';'):
        kind, t, dev, h, line, lo, up, act, ge, win = row.split(',')
        out.append(dict(kind=kind, t=int(t), dev=dev, h=int(h), line=float(line), lo=float(lo),
                        up=float(up), act=float(act), ge=int(ge), win=win,
                        day=dt.datetime.fromtimestamp(int(t), PERTH).date()))
    return out


def miss_ratio(p):
    half = (p['up'] - p['line']) if p['act'] >= p['line'] else (p['line'] - p['lo'])
    return abs(p['act'] - p['line']) / max(half, 1e-6)


def scaled(p, c):
    return max(FLOOR, p['line'] - c * (p['line'] - p['lo'])), p['line'] + c * (p['up'] - p['line'])


def score(lo, up, a):
    return (up - lo) + 10 * (max(lo - a, 0) + max(a - up, 0))


def q80(xs):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(0.8 * len(xs)))]


def summary(ps):
    err = [p['act'] - p['line'] for p in ps]
    ins = sum(p['lo'] <= p['act'] <= p['up'] for p in ps) / len(ps)
    sc = st.mean(score(p['lo'], p['up'], p['act']) for p in ps)
    return (f"{len(ps):3d} pts {len({p['ge'] for p in ps}):2d} gaps  MAE {st.mean(map(abs, err)):5.1f}  "
            f"bias {st.mean(err):+6.1f}  inside {ins:4.0%}  score {sc:6.1f}")


def held_out(ps, wins, label):
    print(f"\nHeld out, window {label}:")
    for h in (15, 30, 60):
        pts = [p for p in ps if p['h'] == h and p['win'] in wins]
        days = sorted({p['day'] for p in pts})
        wins_n = tested = 0
        for d in days:
            test = [p for p in pts if p['day'] == d]
            train = [p for p in pts if p['day'] != d]
            if len(train) < 10:
                print(f"  {h:2d} min {d}: {len(test)} pts, only {len(train)} training pts, unfittable")
                continue
            c = min(2.5, max(1.0, q80([miss_ratio(p) for p in train])))
            before = st.mean(score(p['lo'], p['up'], p['act']) for p in test)
            after = st.mean(score(*scaled(p, c), p['act']) for p in test)
            ins0 = sum(p['lo'] <= p['act'] <= p['up'] for p in test)
            ins1 = sum(scaled(p, c)[0] <= p['act'] <= scaled(p, c)[1] for p in test)
            lows = sum(1 for p in test if p['act'] < 70 and p['lo'] <= p['act'] <= p['up']
                       and not scaled(p, c)[0] <= p['act'] <= scaled(p, c)[1])
            tested += 1
            wins_n += after < before
            print(f"  {h:2d} min {d}: factor {c:4.2f}  score {before:6.1f} -> {after:6.1f}  "
                  f"inside {ins0} -> {ins1} of {len(test)}  lows dropped {lows}")
        if tested:
            print(f"  {h:2d} min: better on {wins_n} of {tested} held-out days")


def main():
    ps = load(sys.argv[1])
    for kind in ('r388', 'live'):
        print(f"\n== {kind} ==")
        k = [p for p in ps if p['kind'] == kind]
        for h in (15, 30, 60):
            for w in ('g0_30', 'g30_60'):
                sel = [p for p in k if p['h'] == h and p['win'] == w]
                if sel:
                    print(f"{h:2d} min {w:7s} {summary(sel)}")
        held_out(k, {'g0_30'}, '0-30 min after the gap')
        held_out(k, {'g0_30', 'g30_60'}, '0-60 min after the gap')


if __name__ == '__main__':
    main()
