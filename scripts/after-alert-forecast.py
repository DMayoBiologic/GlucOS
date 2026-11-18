#!/usr/bin/env python3
"""How good are forecasts in the 2 h after an alert nobody treated? (docs/ForecastAccuracy.md §84)

Alerts come from the Alert History store (Logbook kind "alert", one AlertRecord per delivery).
Copies of the same kind within 3 min count once, and same-side alerts (low or high) within 45 min
fold into one episode, as AlertLog.rows does. An episode is "treated" when any copy got Log
treatment, or a treatment was logged from 15 min before its first alert to 30 min after its last:
a meal for a low-side episode, a rapid dose for a high-side one. Every other episode is
"untreated" (snoozed, dismissed or no response, and nothing logged).

Forecast points are the §42 export, cleaned and drawn as today exactly like
scripts/adaptive-range.py (shown, nothing logged between issue and due). A point is "after" an
episode when it was issued within WINDOW_H hours after any of the episode's alerts; a point after
both kinds counts as treated. Points after no alert are "no alert".

Side "high*" is a high-side untreated episode where a copy was snoozed or dismissed.

The tweak (held out, leave one Perth day out): one range factor per horizon for untreated-after
points only, the 80th percentile of the other days' untreated miss ratios (as §42/§75), clamped to
>= 1 so it only widens, and left at 1 below MIN_FIT points. The line never moves, so no low can be
hidden by it. It ships only if it puts more actuals inside and lowers the interval score at both
30 and 60 min on most held-out days.

Inputs:
  points.txt  the adaptive-range.py export
  alerts.txt  select string_agg(concat_ws(',', round((payload->>'firedAt')::float)::bigint,
                payload->>'kind', coalesce(payload->>'response','none'),
                coalesce(round((payload->>'respondedAt')::float)::bigint::text,'')), ';'
                order by (payload->>'firedAt')::float)
              from glucos.logbook where kind = 'alert' and not deleted;
  log.txt     select string_agg(concat_ws(',', round((payload->>'timestamp')::float)::bigint, kind,
                coalesce(payload->>'kind',''), coalesce(payload->>'carbs', payload->>'grams',''),
                coalesce(payload->>'units',''), coalesce(payload->>'purpose','')), ';'
                order by (payload->>'timestamp')::float)
              from glucos.logbook where not deleted and payload->>'timestamp' is not null;

Usage: python3 -I scripts/after-alert-forecast.py points.txt alerts.txt log.txt [window_hours=2]
"""
import importlib.util
import os
import statistics as st
import sys

spec = importlib.util.spec_from_file_location('ar', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'adaptive-range.py'))
ar = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ar)

LOW_KINDS = {'low', 'urgentLow', 'predictedLow', 'predictedUrgentLow'}
HORIZONS = (15, 30, 45, 60)
SAME, GAP = 180, 45 * 60
MIN_FIT = 20
BEFORE, AFTER = 15 * 60, 30 * 60


def episodes(alerts, log):
    recs = []
    for x in alerts:
        t, kind, resp = int(x[0]), x[1], x[2]
        if any(r['kind'] == kind and abs(r['t'] - t) <= SAME for r in recs):
            for r in recs:
                if r['kind'] == kind and abs(r['t'] - t) <= SAME and resp != 'none':
                    r['resp'] = resp
            continue
        recs.append(dict(t=t, kind=kind, side='low' if kind in LOW_KINDS else 'high', resp=resp))
    eps = []
    for r in sorted(recs, key=lambda r: r['t']):
        open_ = [e for e in eps if e['side'] == r['side'] and r['t'] - e['times'][-1] <= GAP]
        if open_:
            open_[-1]['times'].append(r['t'])
            open_[-1]['resps'].append(r['resp'])
        else:
            eps.append(dict(side=r['side'], times=[r['t']], resps=[r['resp']]))
    meals = [int(x[0]) for x in log if x[1] == 'meal']
    rapid = [int(x[0]) for x in log if x[1] == 'dose' and x[2] == 'rapid']
    for e in eps:
        lo, hi = e['times'][0] - BEFORE, e['times'][-1] + AFTER
        logged = [t for t in (meals if e['side'] == 'low' else rapid) if lo <= t <= hi]
        e['treated'] = 'treating' in e['resps'] or bool(logged)
        e['snoozed'] = 'snoozed' in e['resps'] or 'dismissed' in e['resps']
    return eps


def label(r, eps, window):
    hit = [e for e in eps if any(0 <= r['t'] - t <= window for t in e['times'])]
    if not hit:
        return 'no alert', None
    if any(e['treated'] for e in hit):
        return 'treated', next(e['side'] for e in hit if e['treated'])
    return 'untreated', hit[-1]['side'] + ('*' if any(e['snoozed'] for e in hit) else '')


def stats(rs, off=None):
    off = off or {}
    if not rs:
        return None
    errs, inside = [], 0
    for r in rs:
        b = off.get(id(r), 0.0)
        e = r['a'] - (r['f'] + b)
        errs.append(e)
        inside += r['lo'] + b <= r['a'] <= r['hi'] + b
    return len(rs), st.mean(errs), st.mean(abs(e) for e in errs), 100 * inside / len(rs)


def fmt(s):
    return '   -' if not s else f"n{s[0]:4d} bias{s[1]:+6.1f} mae{s[2]:5.1f} in{s[3]:4.0f}%"


def main(points, alerts, logf, window_h=2.0):
    window = window_h * 3600
    rows = lambda p: [x.split(',') for x in open(p).read().strip().split(';') if x.strip()]
    eps = episodes(rows(alerts), rows(logf))
    clean = [r for r in ar.load(points) if not r['log'] and r['shown']
             and not (r['ver'] == (0,) and r['t'] >= ar.WIDENING_FROM)]
    first = min(t for e in eps for t in e['times'])
    clean = [r for r in clean if r['t'] >= first]
    for r in clean:
        ar.as_drawn_today(r)
        r['grp'], r['side'] = label(r, eps, window)
    days = sorted({r['day'] for r in clean})
    print(f"{len(eps)} episodes ({sum(e['treated'] for e in eps)} treated, "
          f"{sum(e['snoozed'] for e in eps)} snoozed/dismissed); low side "
          f"{sum(e['side'] == 'low' for e in eps)}, high side {sum(e['side'] == 'high' for e in eps)}")
    for e in eps:
        if e['treated'] or e['snoozed']:
            print(f"  {e['side']:4s} {ar.dt.datetime.fromtimestamp(e['times'][0] + 8 * 3600, ar.dt.timezone.utc):%d %b %H:%M} "
                  f"x{len(e['times'])} {'treated' if e['treated'] else ''} {'snoozed' if e['snoozed'] else ''}")
    print(f"{len(clean)} clean points since the first alert, {days[0]}..{days[-1]} (Perth), window {window_h:g} h")
    print("\nas drawn: by group (and side)")
    for m in HORIZONS:
        rs = [r for r in clean if r['m'] == m]
        print(f"{m:2d} min")
        for g in ('no alert', 'treated', 'untreated'):
            print(f"   {g:16s} {fmt(stats([r for r in rs if r['grp'] == g]))}")
            if g != 'no alert':
                for side in ('low', 'high', 'high*'):
                    sub = [r for r in rs if r['grp'] == g and r['side'] == side]
                    if sub:
                        print(f"     {side:14s} {fmt(stats(sub))}  days {len({r['day'] for r in sub})}")
    print("\nuntreated by day (30 / 60)")
    for d in days:
        parts = [fmt(stats([r for r in clean if r['grp'] == 'untreated' and r['m'] == m and r['day'] == d])) for m in (30, 60)]
        print(f"   {d}  {parts[0]} | {parts[1]}")

    print(f"\nheld out: untreated-only range factor (q80 miss ratio of the other days' untreated points, >= 1)")
    for r in clean:
        r['ratio'] = ar.ratio(r)
    C = {}
    for d in days:
        for m in HORIZONS:
            xs = [p['ratio'] for p in clean if p['grp'] == 'untreated' and p['m'] == m and p['day'] != d and p['ratio'] is not None]
            c = max(1.0, ar.q80(xs)) if len(xs) >= MIN_FIT else 1.0
            for r in clean:
                if r['day'] == d and r['m'] == m and r['grp'] == 'untreated':
                    C[id(r)] = c
    for m in HORIZONS:
        rs = [r for r in clean if r['m'] == m and r['grp'] == 'untreated']
        if not rs:
            continue
        def sc(sub, F):
            s = [ar.score(r, F.get(id(r), 1.0)) for r in sub]
            return 100 * sum(x[0] for x in s) / len(s), st.mean(x[1] for x in s), st.mean(x[2] for x in s)
        b0, b1 = sc(rs, {}), sc(rs, C)
        dd = sorted({r['day'] for r in rs})
        better = sum(1 for d in dd if (lambda u, v: v[0] > u[0] and v[2] < u[2])(sc([r for r in rs if r['day'] == d], {}), sc([r for r in rs if r['day'] == d], C)))
        fitted = sorted({round(C[id(r)], 2) for r in rs})
        print(f"{m:2d} min  shipped in{b0[0]:4.0f}% w{b0[1]:6.1f} s{b0[2]:6.1f}  tweak in{b1[0]:4.0f}% w{b1[1]:6.1f} s{b1[2]:6.1f}  "
              f"days better {better}/{len(dd)}  factors {fitted}")

if __name__ == '__main__':
    a = sys.argv[1:]
    main(a[0], a[1], a[2], *(float(x) for x in a[3:]))
