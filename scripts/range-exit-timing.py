#!/usr/bin/env python3
"""How well does the forecast call exits from the target range, and how early?
(docs/ForecastAccuracy.md §76)

For every stored forecast check that started inside the target range (70-180 mg/dL) and has a
point at the horizon H (30 or 60 min), the drawn central line (start, then the stored points,
straight between them) "predicts an exit" when it first crosses 70 or 180 by H. The readings
say whether the glucose actually left the range by H: the first reading in (issue, issue + H]
under 70 or over 180. A check counts only when the readings cover the whole window (no gap over
15 min, one within 5 min of the end).

  hit          predicted and actual exit on the same side by H
  false alarm  predicted, but the glucose stayed in range for the whole window
  missed       actual exit by H that the line did not call (or called on the other side)

precision = hits / predicted, recall = hits / actual. "Lead" is how long before the actual exit
the check was issued (the warning a hit gave), and "timing" is the line's crossing minute minus
the actual one (positive = the line crossed later than the glucose did). Clean = no point of the
check up to H was flagged after_log (nothing logged between issue and H).

Event view: each actual exit (a reading out of range after 30+ min in range) gets the earliest
check from any device, issued in the H minutes before, whose line called it on that side.

The tweak tried is one boundary margin d per horizon: a line counts as an exit once it comes
within d mg/dL of the edge (d > 0, earlier calls) or only once it is d past it (d < 0, fewer
calls). d is picked from -10..+10 by leave-one-Perth-day-out on F1, with the bar: better
held-out recall AND no more false alarms than d = 0, on most held-out days.

Input: checks.txt (one ';'-separated line):

    select string_agg(concat_ws(',', extract(epoch from c.issued_at)::bigint, left(c.device,1),
      round(c.start_mgdl::numeric,1), round(c.trend_per_minute::numeric,2),
      case when coalesce(c.extra,false) then 1 else 0 end, c.basis, coalesce(c.app_version,'0'),
      (select string_agg(concat_ws(':', e->>'minutes', round((e->>'mgdl')::numeric,1),
         round((e->>'lower')::numeric,1), round((e->>'upper')::numeric,1),
         coalesce(e->>'shown','true'), case when (e->>'after_log')::boolean then 1 else 0 end),
         '|' order by (e->>'minutes')::int) from jsonb_array_elements(c.points) e)),
      ';' order by c.issued_at) from glucos.forecast_checks c;

and readings.json ([[epoch, mgdl], ...] from glucos.readings, delta-encoded export as §42).

Usage: python3 -I scripts/range-exit-timing.py checks.txt readings.json
"""
import bisect
import datetime as dt
import json
import statistics as st
import sys

LOW, HIGH = 70.0, 180.0
HORIZONS = (30, 60)
MARGINS = (-10, -6, -4, -2, 0, 2, 4, 6, 10)


def day(t):
    return dt.datetime.fromtimestamp(t + 8 * 3600, dt.timezone.utc).date().isoformat()


def load_checks(path):
    out = []
    for x in open(path).read().strip().split(';'):
        f = x.split(',')
        if len(f) < 8 or not f[7]:
            continue
        pts = []
        for p in f[7].split('|'):
            q = p.split(':')
            pts.append(dict(m=int(q[0]), f=float(q[1]), shown=q[4] == 'true', log=q[5] == '1'))
        out.append(dict(t=int(f[0]), dev=f[1], s=float(f[2]), trend=float(f[3]), extra=f[4] == '1',
                        basis=f[5], pts=pts, day=day(int(f[0]))))
    return out


def window(R, T, t0, t1):
    i, j = bisect.bisect_right(T, t0), bisect.bisect_right(T, t1)
    w = R[i:j]
    if not w or t1 - w[-1][0] > 300 or w[0][0] - t0 > 900:
        return None
    if any(b[0] - a[0] > 900 for a, b in zip(w, w[1:])):
        return None
    return w


def actual_exit(R, T, c, H):
    w = window(R, T, c['t'], c['t'] + 60 * H)
    if w is None:
        return 'nodata', None
    for t, g in w:
        if g < LOW:
            return 'low', (t - c['t']) / 60
        if g > HIGH:
            return 'high', (t - c['t']) / 60
    return None, None


def predicted_exit(c, H, d=0.0):
    path = [(0, c['s'])] + [(p['m'], p['f']) for p in c['pts'] if p['m'] <= H]
    lo, hi = LOW + d, HIGH - d
    for (a, fa), (b, fb) in zip(path, path[1:]):
        for k in range(1, 61):  # walk each segment finely so the crossing minute is exact enough
            m = a + (b - a) * k / 60
            v = fa + (fb - fa) * k / 60
            if v < lo:
                return 'low', m
            if v > hi:
                return 'high', m
    return None, None


def usable(c, H):
    return LOW <= c['s'] <= HIGH and any(p['m'] == H for p in c['pts'])


def clean(c, H):
    return not any(p['log'] for p in c['pts'] if p['m'] <= H)


def classify(cases, d):
    out = []
    for c, H, act, am in cases:
        pred, pm = predicted_exit(c, H, d)
        out.append((c, H, act, am, pred, pm))
    return out


def tally(rows):
    hit = sum(1 for r in rows if r[4] and r[4] == r[2])
    fa = sum(1 for r in rows if r[4] and not r[2])
    pred = sum(1 for r in rows if r[4])
    act = sum(1 for r in rows if r[2])
    miss = act - hit
    prec = hit / pred if pred else float('nan')
    rec = hit / act if act else float('nan')
    f1 = 2 * hit / (pred + act) if pred + act else float('nan')
    return dict(n=len(rows), act=act, pred=pred, hit=hit, fa=fa, miss=miss, prec=prec, rec=rec, f1=f1)


def fmt(t):
    return (f"n{t['n']:4d} exits {t['act']:3d} called {t['pred']:3d} hit {t['hit']:3d} FA {t['fa']:3d} "
            f"miss {t['miss']:3d}  precision {100 * t['prec']:4.0f}%  recall {100 * t['rec']:4.0f}%  F1 {t['f1']:.2f}")


def timing(rows):
    hits = [r for r in rows if r[4] and r[4] == r[2]]
    if not hits:
        return 'no hits'
    lead = [r[3] for r in hits]
    err = [r[5] - r[3] for r in hits]
    return (f"hits {len(hits)}: lead median {st.median(lead):.0f} mean {st.mean(lead):.1f} min; "
            f"line crossing vs actual median {st.median(err):+.0f} mean {st.mean(err):+.1f} min "
            f"({sum(e > 0 for e in err)} late, {sum(e <= 0 for e in err)} on time or early)")


def events(R, H):
    """Actual exits: first reading out of range after 30+ min of readings in range."""
    ev, inside_since = [], None
    for (t0, g0), (t, g) in zip(R, R[1:]):
        if t - t0 > 900:
            inside_since = None
        if LOW <= g0 <= HIGH:
            inside_since = inside_since or t0
        else:
            inside_since = None
        if inside_since and t - inside_since >= 1800 and not (LOW <= g <= HIGH):
            ev.append((t, 'low' if g < LOW else 'high'))
    return ev


def main(cpath, rpath):
    R = [tuple(x) for x in json.load(open(rpath))]
    R.sort()
    T = [x[0] for x in R]
    checks = load_checks(cpath)
    print(f"{len(checks)} checks {checks[0]['day']}..{checks[-1]['day']} (Perth), {len(R)} readings, range {LOW:g}-{HIGH:g}")
    base = {}
    for H in HORIZONS:
        cases = []
        nodata = 0
        for c in checks:
            if not usable(c, H):
                continue
            act, am = actual_exit(R, T, c, H)
            if act == 'nodata':
                nodata += 1
                continue
            cases.append((c, H, act, am))
        base[H] = cases
        print(f"\n== {H} min: {len(cases)} checks started in range ({nodata} dropped for reading gaps)")
        rows = classify(cases, 0)
        for name, sel in (('all', lambda r: True), ('clean', lambda r: clean(r[0], H)),
                          ('relay', lambda r: r[0]['dev'] == 'r'), ('apps', lambda r: r[0]['dev'] != 'r')):
            rs = [r for r in rows if sel(r)]
            print(f"  {name:6s} {fmt(tally(rs))}")
        for side in ('low', 'high'):
            rs = [r for r in rows if r[2] == side or r[4] == side]
            hit = sum(1 for r in rs if r[2] == side and r[4] == side)
            act = sum(1 for r in rs if r[2] == side)
            pred = sum(1 for r in rs if r[4] == side)
            fa = sum(1 for r in rs if r[4] == side and not r[2])
            print(f"  {side:6s} exits {act:3d} called {pred:3d} hit {hit:3d} FA {fa:3d}")
        print(f"  timing {timing(rows)}")
        print(f"  clean  {timing([r for r in rows if clean(r[0], H)])}")
        miss = [r for r in rows if r[2] and r[4] != r[2]]
        if miss:
            print(f"  missed: exit minute median {st.median(r[3] for r in miss):.0f}, "
                  f"{sum(1 for r in miss if r[3] <= 10)} of {len(miss)} within 10 min of issue, "
                  f"{sum(1 for r in miss if not clean(r[0], H))} with a log after issue")
        fas = [r for r in rows if r[4] and not r[2]]
        if fas:
            closest = []
            for r in fas:
                w = window(R, T, r[0]['t'], r[0]['t'] + 60 * H)
                g = [x[1] for x in w]
                closest.append(min(g) - LOW if r[4] == 'low' else HIGH - max(g))
            print(f"  false alarms: glucose came within median {st.median(closest):.0f} mg/dL of the edge "
                  f"({sum(1 for x in closest if x <= 10)} of {len(fas)} within 10)")

    print("\n== event view (each exit after 30+ min in range, earliest calling check in the H min before)")
    ev = events(R, 60)
    span = (checks[0]['t'], checks[-1]['t'])
    ev = [e for e in ev if span[0] + 3600 <= e[0] <= span[1]]
    for H in HORIZONS:
        rows = classify(base[H], 0)
        leads = []
        for t, side in ev:
            best = None
            for r in rows:
                c = r[0]
                if r[4] == side and t - 60 * H <= c['t'] < t and c['t'] + 60 * r[5] <= t + 60 * H:
                    lead = (t - c['t']) / 60
                    best = lead if best is None else max(best, lead)
            leads.append(best)
        got = [x for x in leads if x is not None]
        print(f"  {H} min: {len(ev)} exits ({sum(1 for e in ev if e[1] == 'low')} low), called by some check {len(got)} "
              + (f"lead median {st.median(got):.0f} mean {st.mean(got):.1f} min" if got else ""))

    print("\n== boundary margin d (in-sample, then leave-one-day-out)")
    for H in HORIZONS:
        cases = base[H]
        b = tally(classify(cases, 0))
        for d in MARGINS:
            t = tally(classify(cases, d))
            print(f"  {H} d{d:+3d} {fmt(t)}")
        days = sorted({c[0]['day'] for c in cases})
        held, won = [], 0
        dtot = []
        for dd in days:
            train = [c for c in cases if c[0]['day'] != dd]
            test = [c for c in cases if c[0]['day'] == dd]
            best = max(MARGINS, key=lambda d: (tally(classify(train, d))['f1'], -abs(d)))
            tb, tt = tally(classify(test, 0)), tally(classify(test, best))
            held.extend(classify(test, best))
            dtot.append((dd, best, tb, tt))
            if tt['hit'] > tb['hit'] and tt['fa'] <= tb['fa']:
                won += 1
        h = tally(held)
        print(f"  {H} LODO picks {[x[1] for x in dtot]}")
        print(f"  {H} held out {fmt(h)}")
        print(f"  {H} as drawn {fmt(b)}")
        print(f"  {H} days with more hits and no more FA: {won} of {len(days)}")


if __name__ == '__main__':
    main(*sys.argv[1:3])
