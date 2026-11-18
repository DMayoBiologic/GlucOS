#!/usr/bin/env python3
"""Are forecasts worse on the first day of an injection site than on later days?
(docs/ForecastAccuracy.md §77)

Site day. GlucOS's site rotation (`SiteRotation`, PR #33) counts a site as "used recently" when
any dose (fast or long) went there in the last 3 days. So a dose starts a NEW stretch on its site
when that site had no dose in the 3 days before it, and that is site day 1. A later dose on the
same site, inside the stretch (each gap under 3 days), is on site day N = Perth calendar days since
the stretch began + 1. A site first seen in the logbook (no history before it) starts a stretch
only once the logbook is 3 days old; before that it is "unknown" and left out. Pump site changes
(`siteChange` records) would be the natural day 1, but there are none: every dose is a pen dose.

A forecast point belongs to the latest fast-acting dose with a site in the 4 hours before it was
issued (the window where a fast dose's absorption matters). Points with no such dose are the
"no recent dose" baseline. Long-acting doses only set site history: each one is followed by the
next day's at another site, so there is no day 2 of a long-acting site to compare.

error = line - actual (positive = the line ran above). Inside = actual in [lower, upper].
Clean = nothing logged between issue and the horizon (after_log = 0).

Tweak (range width only): one factor per (horizon, site-day group) that scales the drawn range's
distance above and below the line, fitted leave-one-Perth-day-out as the 80th percentile of the
training points' miss ratios (|actual - line| / half-width on the side the reading fell), and
clamped to 0.6..2.5. Score is the interval score at 80% (width + 10 x distance outside), lower is
better. Every other point keeps its drawn range. The bar: better held-out score at 30 AND 60 on
most held-out days that have such points, coverage nearer 80%, and no low (actual < 70) dropped out
of the range.

Input: points.txt, one ';'-separated line from

    select string_agg(concat_ws(',', extract(epoch from c.issued_at)::bigint, left(c.device,1),
      round(c.start_mgdl::numeric,1), e->>'minutes', round((e->>'mgdl')::numeric,1),
      round((e->>'lower')::numeric,1), round((e->>'upper')::numeric,1),
      round((e->>'actual')::numeric,1), case when (e->>'after_log')::boolean then 1 else 0 end,
      coalesce(e->>'shown','true')), ';' order by c.issued_at)
    from glucos.forecast_checks c, jsonb_array_elements(c.points) e
    where (e->>'minutes')::int in (30,60) and e->>'actual' is not null;

and doses.txt, one ';'-separated line from

    select string_agg(concat_ws(',', round((payload->>'timestamp')::numeric)::bigint,
      payload->>'kind', payload->>'units', coalesce(payload->>'site','-')), ';'
      order by (payload->>'timestamp')::float)
    from glucos.logbook where kind = 'dose' and not deleted;

Usage: python3 -I scripts/site-day-error.py points.txt doses.txt
"""
import datetime as dt
import statistics as st
import sys

RECENT_DAYS = 3
WINDOW_H = 4
FAST = ('rapid', 'ultraRapid')


def day(t):
    return dt.datetime.fromtimestamp(t + 8 * 3600, dt.timezone.utc).date()


def load_points(path):
    out = []
    for row in open(path).read().strip().split(';'):
        t, dev, start, h, line, lo, up, act, after, shown = row.split(',')
        out.append(dict(t=int(t), dev=dev, h=int(h), line=float(line), lo=float(lo), up=float(up),
                        act=float(act), clean=after == '0', shown=shown == 'true'))
    return out


def load_doses(path):
    doses = []
    for row in open(path).read().strip().split(';'):
        t, kind, units, site = row.split(',')
        doses.append(dict(t=int(t), kind=kind, units=float(units), site=None if site == '-' else site))
    first = doses[0]['t']
    last_use, stretch_start = {}, {}
    for d in doses:
        s = d['site']
        if s is None:
            d['site_day'] = None
            continue
        prev = last_use.get(s)
        if prev is not None and d['t'] - prev < RECENT_DAYS * 86400:
            start = stretch_start[s]
            d['site_day'] = None if start is None else (day(d['t']) - day(start)).days + 1
        elif prev is None and d['t'] - first < RECENT_DAYS * 86400:
            d['site_day'] = None  # history too short to know
            stretch_start[s] = None  # stays unknown until a 3-day gap starts a new stretch
        else:
            d['site_day'] = 1
            stretch_start[s] = d['t']
        last_use[s] = d['t']
    return doses


def group_of(p, fast):
    recent = [d for d in fast if d['site'] is not None and d['t'] <= p['t'] <= d['t'] + WINDOW_H * 3600]
    if not recent:
        return 'none', None
    d = recent[-1]
    if d['site_day'] is None:
        return 'unknown', d['t']
    return ('day1' if d['site_day'] == 1 else 'later'), d['t']


def summary(ps):
    if not ps:
        return '0 pts'
    err = [p['line'] - p['act'] for p in ps]
    inside = sum(p['lo'] <= p['act'] <= p['up'] for p in ps) / len(ps)
    days = len({day(p['t']) for p in ps})
    return (f"{len(ps):3d} pts {days} days  MAE {st.mean(abs(e) for e in err):5.1f}  "
            f"bias {st.mean(err):+6.1f}  inside {inside:4.0%}")


def miss_ratio(p):
    if p['act'] >= p['line']:
        half = max(p['up'] - p['line'], 1e-6)
    else:
        half = max(p['line'] - p['lo'], 1e-6)
    return abs(p['act'] - p['line']) / half


def scaled(p, c):
    return p['line'] - c * (p['line'] - p['lo']), p['line'] + c * (p['up'] - p['line'])


def score(lo, up, a):
    return (up - lo) + 10 * (max(lo - a, 0) + max(a - up, 0))


def q80(xs):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(0.8 * len(xs)))]


def held_out(ps, g):
    days = sorted({day(p['t']) for p in ps if p['g'] == g})
    rows, won, tried, per_dose = [], 0, 0, {}
    for d in days:
        train = [p for p in ps if p['g'] == g and day(p['t']) != d]
        test = [p for p in ps if p['g'] == g and day(p['t']) == d]
        if len(train) < 15:
            continue
        c = min(2.5, max(0.6, q80([miss_ratio(p) for p in train])))
        s0 = sum(score(p['lo'], p['up'], p['act']) for p in test)
        s1 = sum(score(*scaled(p, c), p['act']) for p in test)
        in1 = sum(scaled(p, c)[0] <= p['act'] <= scaled(p, c)[1] for p in test)
        lows_lost = sum(p['act'] < 70 and p['lo'] <= p['act'] <= p['up']
                        and not scaled(p, c)[0] <= p['act'] <= scaled(p, c)[1] for p in test)
        for p in test:
            k = p['dose']
            a, b, n = per_dose.get(k, (0.0, 0.0, 0))
            per_dose[k] = (a + score(p['lo'], p['up'], p['act']), b + score(*scaled(p, c), p['act']), n + 1)
        tried += 1
        won += s1 < s0
        rows.append((d, len(test), c, s0 / len(test), s1 / len(test), in1, lows_lost))
    return rows, won, tried, per_dose


def main():
    pts = load_points(sys.argv[1])
    doses = load_doses(sys.argv[2])
    fast = [d for d in doses if d['kind'] in FAST]
    print('Fast doses with a site, by site day:')
    for d in fast:
        print(' ', day(d['t']), dt.datetime.fromtimestamp(d['t'] + 8 * 3600, dt.timezone.utc).strftime('%H:%M'),
              d['units'], d['site'], d['site_day'])
    for p in pts:
        p['g'], p['dose'] = group_of(p, fast)
    for h in (30, 60):
        print(f'\n== {h} min ==')
        for g in ('day1', 'later', 'unknown', 'none'):
            sel = [p for p in pts if p['h'] == h and p['g'] == g]
            print(f'  {g:8s} all   {summary(sel)}')
            print(f'  {g:8s} clean {summary([p for p in sel if p["clean"]])}')
        # one point per dose and device, to see how much hangs on single doses
        means = {}
        for g in ('day1', 'later'):
            per = {}
            for p in pts:
                if p['h'] == h and p['g'] == g:
                    per.setdefault(p['dose'], []).append(p['line'] - p['act'])
            print(f'  {g} doses: ' + ', '.join(
                f"{day(k).strftime('%d')}/{len(v)}pts/{st.mean(v):+.0f}" for k, v in sorted(per.items())))
            means[g] = [st.mean(v) for v in per.values()]
        a, b = means['day1'], means['later']
        if len(a) > 1 and len(b) > 1:
            se = (st.variance(a) / len(a) + st.variance(b) / len(b)) ** 0.5
            print(f'  per-dose bias: day1 {st.mean(a):+.1f} ({len(a)} doses), later {st.mean(b):+.1f} '
                  f'({len(b)} doses), later - day1 {st.mean(b) - st.mean(a):+.1f} +/- {se:.1f} (1 SE)')
    print('\nHeld-out width factor (LODO), per group:')
    for h in (30, 60):
        hp = [p for p in pts if p['h'] == h]
        for g in ('day1', 'later'):
            rows, won, tried, per_dose = held_out(hp, g)
            print(f'  {h} min {g}: days won {won} of {tried}, '
                  f'doses won {sum(b < a for a, b, _ in per_dose.values())} of {len(per_dose)}')
            for d, n, c, s0, s1, in1, lost in rows:
                print(f'    {d} n={n:2d} c={c:.2f} score {s0:6.1f} -> {s1:6.1f} inside {in1}/{n} lows lost {lost}')
            for k, (a, b, n) in sorted(per_dose.items()):  # n = held-out points scored
                print(f'    dose {dt.datetime.fromtimestamp(k + 8 * 3600, dt.timezone.utc):%d %b %H:%M} '
                      f'n={n:2d} score {a / n:6.1f} -> {b / n:6.1f}')


if __name__ == '__main__':
    main()
