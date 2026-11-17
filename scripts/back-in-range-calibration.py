#!/usr/bin/env python3
"""Back-in-range estimate, scored and calibrated held out by day (docs/ForecastAccuracy.md §68).

Input: a JSON file of rows [device, "MM-DD HH:MM" Perth, basis, estimate_min, actual_min,
logged_within_3h, settled, min_mgdl_next_3h], from the §68 query (the §24 query plus the logbook
count and the lowest reading in the next 3 hours). Rows with no actual are left out.

Candidates, each picked on the other days and scored on the held-out one:
  offset  estimate + median(actual - estimate)
  scale   estimate * median(actual / estimate)
  range   estimate ± the 80th-percentile miss (coverage, not miss)
"""
import json, statistics as st, sys

rows = [dict(dev=d[0], day=d[1][:5], est=d[3], act=d[4], log=d[5], low=d[7])
        for d in json.load(open(sys.argv[1])) if d[4] is not None]

def summary(rs, f=lambda r: r['est']):
    m = [abs(f(r) - r['act']) for r in rs]
    return dict(n=len(m), median=round(st.median(m), 1), mean=round(st.mean(m), 1),
                within15=sum(x <= 15 for x in m),
                came_back_before_estimate=sum(r['act'] < f(r) for r in rs))

print('all', summary(rows))
print('nothing logged within 3 h', summary([r for r in rows if r['log'] == 0]))
print('something logged', summary([r for r in rows if r['log'] > 0]))
for dev in sorted({r['dev'] for r in rows}):
    print(dev, summary([r for r in rows if r['dev'] == dev]))

days = sorted({r['day'] for r in rows})
out = {k: [] for k in ('shipped', 'offset', 'scale')}
covered, widths, early = 0, [], {'shipped': 0, 'offset': 0}
for d in days:
    train = [r for r in rows if r['day'] != d]
    b = st.median([r['act'] - r['est'] for r in train])
    g = st.median([r['act'] / max(r['est'], 1) for r in train])
    miss = sorted(abs(r['act'] - r['est']) for r in train)
    q = miss[int(0.8 * (len(miss) - 1) + 0.5)]
    for r in (r for r in rows if r['day'] == d):
        shown = max(0.0, r['est'] + b)
        out['shipped'].append(abs(r['est'] - r['act']))
        out['offset'].append(abs(shown - r['act']))
        out['scale'].append(abs(r['est'] * g - r['act']))
        early['shipped'] += r['act'] > r['est']
        early['offset'] += r['act'] > shown
        covered += abs(r['est'] - r['act']) <= q
        widths.append(q)
    print(f'{d}: offset {b:+.1f} min, scale {g:.2f}, ±{q:.1f} min range')
for k, v in out.items():
    print(f'held out {k}: median {st.median(v):.1f}, mean {st.mean(v):.1f}, within 15 {sum(x <= 15 for x in v)}/{len(v)}')
print('checks where glucose came back later than the time shown:', early)
print(f'±80th-percentile range held out: covered {covered}/{len(widths)}, typical half-width {st.median(widths):.1f} min')
