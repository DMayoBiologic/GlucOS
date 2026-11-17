#!/usr/bin/env python3
"""Scorecard sampling bias (ForecastAccuracy.md §70).

Usage: python3 scripts/scorecard-sampling.py CELLS
CELLS holds the one-string output of scripts/scorecard-sampling.sql. Prints, per device and
horizon, the replay at every reading ("truth"), the replay at the moments the app recorded,
the card's own figures, and the card reweighted to the all-readings mix of time-of-day ×
trend cells. Then the same reweighting applied in the replay world, where the truth is known:
a reweighting is only worth showing if it moves the sampled figure most of the way to the truth.
"""
import collections, sys

def parse(text):
    rows = []
    for s in text.strip().split(';'):
        f = s.split(',')
        if len(f) == 9:  # replay-at-recorded and recorded both empty
            f = f[:8] + ['', '', f[8], '', '', '']
        num = lambda x: float(x) if x else None
        rows.append(dict(dev=f[0], h=int(f[1]), tod=f[2], band=f[3], an=int(f[4]), afc=num(f[5]), anc=num(f[6]),
                         tn=int(f[7]), tfc=num(f[8]), tnc=num(f[9]), rn=int(f[10]), rfc=num(f[11]),
                         rnc=num(f[12]), rin=num(f[13])))
    return rows

def wavg(cells, n, v):
    s = sum(c[n] for c in cells if c[v] is not None)
    return sum(c[n] * c[v] for c in cells if c[v] is not None) / s if s else float('nan')

def reweight(cells, n, v, key=None):
    """Cells' `v` averaged with all-readings weights, grouping cells by `key` (None = tod × band)."""
    g = collections.defaultdict(lambda: [0, 0, 0.0])
    for c in cells:
        k = c[key] if key else (c['tod'], c['band'])
        x = g[k]; x[0] += c['an']
        if c[n] and c[v] is not None: x[1] += c[n]; x[2] += c[n] * c[v]
    used = [x for x in g.values() if x[1]]
    return sum(x[0] * x[2] / x[1] for x in used) / sum(x[0] for x in used)

rows = parse(open(sys.argv[1]).read())
for dev in ('iPhone', 'Mac'):
    for h in (15, 30, 60):
        C = [c for c in rows if c['dev'] == dev and c['h'] == h]
        af, an = wavg(C, 'an', 'afc'), wavg(C, 'an', 'anc')
        tf, tn = wavg(C, 'tn', 'tfc'), wavg(C, 'tn', 'tnc')
        rf, rn, ri = wavg(C, 'rn', 'rfc'), wavg(C, 'rn', 'rnc'), wavg(C, 'rn', 'rin')
        wf, wn = reweight(C, 'rn', 'rfc'), reweight(C, 'rn', 'rnc')
        print(f"{dev:6} {h:2}m n={sum(c['rn'] for c in C):3} | every reading {af:5.1f}/{an:5.1f} ({af/an:.2f}) | "
              f"replay at recorded {tf:5.1f}/{tn:5.1f} ({tf/tn:.2f}) | card {rf:5.1f}/{rn:5.1f} ({rf/rn:.2f}) in {ri:.2f} | "
              f"card reweighted {wf:5.1f}/{wn:5.1f} ({wf/wn:.2f})")
    C = [c for c in rows if c['dev'] == dev and c['h'] == 15]
    for key in ('tod', 'band'):
        A, R = sum(c['an'] for c in C), sum(c['rn'] for c in C)
        g = collections.defaultdict(lambda: [0, 0])
        for c in C: g[c[key]][0] += c['an']; g[c[key]][1] += c['rn']
        print('   mix (every reading / recorded):', ', '.join(f"{k} {a/A:.0%}/{r/R:.0%}" for k, (a, r) in g.items()))

print("\nReweighting in the replay world (truth = every reading):")
for dev in ('iPhone', 'Mac'):
    for h in (15, 30, 60):
        C = [c for c in rows if c['dev'] == dev and c['h'] == h]
        af, an = wavg(C, 'an', 'afc'), wavg(C, 'an', 'anc')
        tf, tn = wavg(C, 'tn', 'tfc'), wavg(C, 'tn', 'tnc')
        out = [f"{dev:6} {h:2}m truth {af:5.1f} ({af/an:.2f}) | sampled {tf:5.1f} ({tf/tn:.2f})"]
        for label, key in (('tod×band', None), ('tod', 'tod'), ('band', 'band')):
            f, n = reweight(C, 'tn', 'tfc', key), reweight(C, 'tn', 'tnc', key)
            out.append(f"{label} {f:5.1f} ({f/n:.2f})")
        print(' | '.join(out))
