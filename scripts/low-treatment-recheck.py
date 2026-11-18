#!/usr/bin/env python3
"""§78: do logged low treatments on the fast curve (§37, #193) still beat what shipped before?

Replays the engine's forecast (GlucoseForecaster: 20-min least-squares trend, capped at ±4, faded
over 30 min at the device's gain, the model's rate weighted by 1 − fade) after every carb entry
of 45 g or less logged under 70 mg/dL or with a hypo treatment tag, then scores 15/30/60-minute
points against the readings. Only clean points count: a point whose target time comes after a
carb entry logged later than the forecast is dropped (the forecast log's after_log rule).

Usage: python3 -I scripts/low-treatment-recheck.py windows.txt

windows.txt: one line per low, "<ISO start> <sec>:<mgdl>,<sec>:<mgdl>,...", seconds from start.
Export, per window (Supabase, glucos.readings):

    select to_char(w.s at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') || ' ' ||
      string_agg(round(extract(epoch from r.at - w.s))::text||':'||r.mgdl::int, ',' order by r.at)
    from (values ('2026-11-18 01:45'::timestamptz)) w(s)
    join glucos.readings r on r.at between w.s and w.s + interval '200 min' group by w.s;

The logged entries are listed in LOWS / OTHER_CARBS / DOSES below (Logbook, 12–18 Nov 2026).
To rerun on new lows, add each new treatment to LOWS (episode label, UTC time, grams; a second
treatment inside the same low shares its episode), each later carb entry that ends a clean window
to OTHER_CARBS, each rapid dose to DOSES, each new episode to NEW, and a readings window for it.
"""
import sys, math
from datetime import datetime, timezone

def ts(s): return datetime.fromisoformat(s.replace('Z', '+00:00')).timestamp()

# (label, episode, logged at UTC, grams)
LOWS = [
    ("12 Nov 19:08 burrito bowl", "12a", "2026-11-12T11:08:32Z", 37.5),
    ("12 Nov 23:42 sports drink", "12b", "2026-11-12T15:42:26Z", 36.8),
    ("13 Nov 19:27 sports drink", "13",  "2026-11-13T11:27:19Z", 21.4),
    ("16 Nov 01:19 Coke",         "16",  "2026-11-15T17:19:11Z", 35.0),
    ("18 Nov 10:23 Smarties+Snickers (tagged)", "18", "2026-11-18T02:23:38Z", 17.1),
    ("18 Nov 11:19 chocolate croissant",        "18", "2026-11-18T03:19:47Z", 41.0),
]
# Later carbs that end the clean window (meal curve, 82.9 g tagged: not a treatment, > 45 g).
OTHER_CARBS = [("2026-11-18T03:51:32Z", 82.9)]
DOSES = [("2026-11-12T11:08:32Z", 4.0)]          # rapid, units
NEW = {"18"}                                      # episodes since #193 shipped

K = 2.8      # mg/dL per g, learnt carb effect (checked against the live checks below)
S = 19.2     # mg/dL per U
GAIN = 1.0   # live checks on 18 Nov fit a trend gain of 1.0 (trend-only 15-min points)
FADE = 30.0

def carb_rate(elapsed_s, delay_min, absorb_min):
    """CarbAbsorptionCurve.rate, share per minute."""
    x = (elapsed_s - delay_min * 60) / (absorb_min * 60)
    rise, fall = 0.15, 0.5
    scale = 2 / (1 + fall - rise)
    if x <= 0: u = 0
    elif x < rise: u = scale * x / rise
    elif x < fall: u = scale
    elif x < 1: u = scale * (1 - x) / (1 - fall)
    else: u = 0
    return u / absorb_min

def insulin_activity(elapsed_s):
    """InsulinActionCurve.rapid activity, share per minute."""
    delay, peak, dur = 600.0, 75 * 60.0, 6 * 3600.0
    tau = peak * (1 - peak / dur) / (1 - 2 * peak / dur)
    a = 2 * tau / dur
    s = 1 / (1 - a + (1 + a) * math.exp(-dur / tau))
    t = elapsed_s - delay
    if t <= 0 or t >= dur: return 0
    return max(0, (s / tau ** 2) * t * (1 - t / dur) * math.exp(-t / tau)) * 60

def load(path):
    series = []
    for line in open(path):
        if not line.strip(): continue
        start, data = line.split()
        t0 = ts(start)
        pts = sorted((t0 + float(a), float(b)) for a, b in (p.split(':') for p in data.split(',')))
        kept = []
        for t, g in pts:   # drop graph-point twins within 30 s of the previous reading
            if kept and t - kept[-1][0] < 30: continue
            kept.append((t, g))
        series += kept
    return sorted(series)

def trend(series, t0):
    r = [(t, g) for t, g in series if t0 - 1200 <= t <= t0]
    if len(r) < 2 or r[-1][0] - r[0][0] < 540: return None
    xs = [(t - t0) / 60 for t, _ in r]; ys = [g for _, g in r]
    mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
    den = sum((x - mx) ** 2 for x in xs)
    return max(-4, min(4, sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den))

def actual(series, t):
    near = [(abs(tt - t), g) for tt, g in series if abs(tt - t) <= 150]
    return min(near)[1] if near else None

def forecast(t0, g0, tr, h, treat, model=True):
    """treat: (delay, absorb, scale) for treatments, None = meal curve, 'trend' = trend only."""
    g = g0
    for m in range(h):
        mid = m + 0.5
        w = max(0, 1 - mid / FADE)
        at = t0 + mid * 60
        rate = 0.0
        if treat != 'trend':
            for _, _, lt, grams in LOWS:
                e = at - ts(lt)
                if ts(lt) > t0: continue
                if treat is None: rate += K * grams * carb_rate(e, 10, 180)
                else: rate += treat[2] * K * grams * carb_rate(e, treat[0], treat[1])
            for lt, grams in OTHER_CARBS:
                if ts(lt) <= t0: rate += K * grams * carb_rate(at - ts(lt), 10, 180)
            for lt, u in DOSES:
                if ts(lt) <= t0: rate -= S * u * insulin_activity(at - ts(lt))
        g += w * GAIN * tr + (1 - w) * rate
    return max(39, min(401, g))

def points(series, horizons=(15, 30, 60)):
    """Forecasts every 5 min from each treatment to an hour after it."""
    logs = sorted([ts(l[2]) for l in LOWS] + [ts(o[0]) for o in OTHER_CARBS])
    out = []
    for label, ep, lt, grams in LOWS:
        t_log = ts(lt)
        for k in range(1, 62, 5):
            t_iss = t_log + k * 60
            latest = [(t, g) for t, g in series if t_iss - 300 <= t <= t_iss]
            if not latest: continue
            t0, g0 = latest[-1]
            if t0 < t_log: continue                  # the reading must come after the log
            if any(t_log < l <= t0 for l in logs): break   # next entry logged: its own forecasts
            tr = trend(series, t0)
            if tr is None: continue
            nxt = min([log for log in logs if log > t0], default=1e18)
            for h in horizons:
                if t0 + h * 60 > nxt: continue       # after a later log: not clean
                a = actual(series, t0 + h * 60)
                if a is None: continue
                out.append(dict(label=label, ep=ep, h=h, t0=t0, g0=g0, tr=tr, a=a))
    return out

GRID = [(d, ab, sc) for d in (0, 5, 10, 15, 20) for ab in (20, 30, 45, 60, 90)
        for sc in (0.5, 0.75, 1.0, 1.25, 1.5, 2.0)]
SHIPPED = (10, 30, 1.5)

def mae(pts, treat):
    return sum(abs(p['a'] - forecast(p['t0'], p['g0'], p['tr'], p['h'], treat)) for p in pts) / len(pts) if pts else float('nan')

def main(path):
    series = load(path)
    pts = points(series)
    eps = sorted({p['ep'] for p in pts})
    print("clean points per episode and horizon:")
    for ep in eps:
        print(" ", ep, {h: sum(1 for p in pts if p['ep'] == ep and p['h'] == h) for h in (15, 30, 60)})
    rows = [("No change", 'none'), ("Trend only (what 18 Nov drew before #193)", 'trend'),
            ("Meal curve", None), ("Fast curve as shipped (10/30/1.5x)", SHIPPED)]
    def score(sub, treat):
        if treat == 'none':
            return sum(abs(p['a'] - p['g0']) for p in sub) / len(sub) if sub else float('nan')
        return mae(sub, treat)
    for scope, pred in (("old lows (12–16 Nov)", lambda p: p['ep'] not in NEW),
                        ("new lows since #193 (18 Nov)", lambda p: p['ep'] in NEW),
                        ("all six", lambda p: True)):
        print(f"\n{scope}: mean miss, mg/dL")
        for name, tr in rows:
            print(f"  {name:45s}", "  ".join(f"{h}m {score([p for p in pts if p['h']==h and pred(p)], tr):6.1f}" for h in (15, 30, 60)))
    print("\nper treatment (30 / 60 min): shipped, meal, trend only, no change")
    for label, ep, lt, g in LOWS:
        sub = [p for p in pts if p['label'] == label]
        cells = []
        for tr in (SHIPPED, None, 'trend', 'none'):
            cells.append(" / ".join(f"{score([p for p in sub if p['h']==h], tr):5.1f}" for h in (30, 60)))
        print(f"  {label:42s}", " | ".join(cells))
    print("\nleave one episode out: refit (delay, absorb, scale) on the rest, score the held-out one")
    tot = {}
    for ep in eps:
        train = [p for p in pts if p['ep'] != ep and p['h'] in (15, 30, 60)]
        if not train:
            print(f"  hold out {ep:4s}: no other lows to fit on, refit unavailable"); continue
        best = min(GRID, key=lambda c: mae(train, c))
        test = [p for p in pts if p['ep'] == ep]
        line = []
        for h in (30, 60):
            sub = [p for p in test if p['h'] == h]
            if not sub: line.append(f"{h}m  -"); continue
            r = (mae(sub, best), mae(sub, SHIPPED), mae(sub, 'trend'), mae(sub, None))
            for name, v in zip(("refit", "shipped", "trend", "meal"), r):
                tot.setdefault((h, name), []).append((v, len(sub)))
            line.append(f"{h}m refit {r[0]:5.1f} shipped {r[1]:5.1f} trend {r[2]:5.1f} meal {r[3]:5.1f} (n={len(sub)})")
        print(f"  hold out {ep:4s} fit {best}: ", " | ".join(line))
    print("\nheld-out totals (point-weighted mean miss):")
    for h in (30, 60):
        print(f"  {h}m", "  ".join(f"{n} {sum(v*k for v,k in tot[(h,n)])/sum(k for _,k in tot[(h,n)]):5.1f}"
                                  for n in ("refit", "shipped", "trend", "meal") if (h, n) in tot))

if __name__ == '__main__':
    main(sys.argv[1])
