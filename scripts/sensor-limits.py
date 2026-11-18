#!/usr/bin/env python3
"""How good are forecasts near the sensor's limits, and should they be clamped? (ForecastAccuracy.md §73)

Usage: python3 scripts/sensor-limits.py DIR
DIR holds readings.json: [[unix, mgdl, live], ...] for every row of glucos.readings (live = 1 when
trend > 0). Export it with

    select count(*), sum(mgdl), string_agg(extract(epoch from at)::bigint::text || ',' ||
      round(mgdl)::int::text || ',' || (case when trend > 0 then 1 else 0 end)::text, ';' order by at)
    from glucos.readings;

and split the string on ';' and ','. Check the count and sum against the export.

The engine refuses to forecast from a reading outside 40...400 (`GlucoseForecaster.sensorRange`,
relay `sensorLow`/`sensorHigh`) and holds the drawn line and its range to 39...401. LibreLinkUp's
LO and HI would arrive as values at or past those limits; none are stored (min 43, max 353 on
10-18 Nov), so this looks at the nearest thing: forecasts starting under 55 or over 300, and
forecasts whose target ends there.

Part 1, error by start band. The engine's trend forecast as in §72 (20-minute least-squares slope
clamped at ±4, 30-minute fade, gains 0.45 Mac/relay, 0.6 and 0.7 iPhone) every 5 minutes, scored
at 15, 30 and 60 minutes against the nearest live reading. No change alongside.

Part 2, does the line run past what the sensor can show: the same line without the 39...401 hold,
how often it leaves 40...400 within 60 minutes, and how often the hold changes the score.

Part 3, held out (leave one Perth day out, pick on the other days by miss at 30 + 60, training drops
points whose 60-minute target lands on the left-out day). Candidates:
  ceiling  hold the line at or under C, C in 401 (as ships), 375, 350, 325, 300, 275, 250
  rise     when the start is over 250 and rising, scale the trend by w in 1, 0.75, 0.5, 0.25, 0
  floor    hold the line at or over F, F in 39 (as ships), 45, 50, 55 (lifts low lines by
           construction, so it is reported but can't ship)
Ship bar: better held out at both 30 and 60 minutes, and no higher line where glucose ends under 80
and no low warning (line under 70 within 30 minutes) lost.
"""
import bisect, datetime as dt, json, statistics as st, sys

R = sorted(json.load(open(f"{sys.argv[1]}/readings.json")))
T = [r[0] for r in R]
LIVE = [r for r in R if r[2] == 1]
TL = [r[0] for r in LIVE]
FADE, TREND_W, MAX = 30.0, 20, 4.0
LO, HI = 39.0, 401.0
GAINS = (0.45, 0.6, 0.7)
H = (15, 30, 60)


def perth(t): return dt.datetime.fromtimestamp(t + 8 * 3600, dt.UTC)
def day(t): return perth(t).strftime("%d")


def slope(t):
    i, j = bisect.bisect_left(T, t - TREND_W * 60), bisect.bisect_right(T, t)
    pts = [((T[k] - t) / 60, R[k][1]) for k in range(i, j)]
    if len(pts) < 3 or pts[-1][0] - pts[0][0] < 9: return None
    mx = st.mean(p[0] for p in pts); my = st.mean(p[1] for p in pts)
    sxx = sum((p[0] - mx) ** 2 for p in pts)
    return max(-MAX, min(MAX, sum((p[0] - mx) * (p[1] - my) for p in pts) / sxx)) if sxx else None


def line(g, trend, gain, lo=LO, hi=HI, minutes=60):
    out, u = {}, 0
    while u < minutes:
        g += max(0, 1 - (u + 0.5) / FADE) * gain * trend
        u += 1
        out[u] = min(hi, max(lo, g))
    return out


def nearest(ts, rows, t, tol=120):
    i = bisect.bisect_left(ts, t)
    best = min((j for j in (i - 1, i) if 0 <= j < len(ts)), key=lambda j: abs(ts[j] - t), default=None)
    return rows[best][1] if best is not None and abs(ts[best] - t) <= tol else None


pts = []
for slot in range(T[0] - T[0] % 300 + 300, T[-1] - 3600, 300):
    i = bisect.bisect_right(T, slot) - 1
    if i < 0 or slot - T[i] >= 300: continue
    t, g = T[i], R[i][1]
    if not 40 <= g <= 400: continue
    tr = slope(t)
    if tr is None: continue
    act = {h: nearest(TL, LIVE, t + h * 60) or nearest(T, R, t + h * 60) for h in H}
    if None in act.values(): continue
    pts.append(dict(t=t, g=g, tr=tr, act=act, day=day(t)))
days = sorted({p["day"] for p in pts})


def band(g):
    return "<55" if g < 55 else "55-70" if g < 70 else "70-250" if g <= 250 else "250-300" if g <= 300 else ">300"


BANDS = ("<55", "55-70", "70-250", "250-300", ">300")


def pred(p, h, gain, ceiling=HI, w=1.0, floor=LO):
    tr = p["tr"] * w if p["g"] > 250 and p["tr"] > 0 else p["tr"]
    return line(p["g"], tr, gain, lo=floor, hi=ceiling)[h]


def mae(s, h, f): return st.mean(abs(p["act"][h] - f(p)) for p in s) if s else float("nan")


print(f"{len(pts)} forecast points over {len(days)} Perth days ({days[0]}–{days[-1]} Nov); "
      f"readings {min(r[1] for r in R)}–{max(r[1] for r in R)} mg/dL, "
      f"≤40: {sum(r[1] <= 40 for r in R)}, ≥400: {sum(r[1] >= 400 for r in R)}")

print("\n== Part 1: miss by start band, no change / ships (bias = actual − ships), mg/dL")
for gain in GAINS:
    print(f"-- gain {gain}")
    for b in BANDS:
        s = [p for p in pts if band(p["g"]) == b]
        if not s: continue
        nd = len({p["day"] for p in s}); ne = len({p["t"] // 3600 for p in s})
        print(f"   start {b:7s} n={len(s):4d} ({nd} days, {ne} hours)  " + "  ".join(
            f"{h}: {mae(s, h, lambda p: p['g']):5.1f} / {mae(s, h, lambda p: pred(p, h, gain)):5.1f} "
            f"({st.mean(p['act'][h] - pred(p, h, gain) for p in s):+6.1f})" for h in H))
print("-- by where glucose ended (gain 0.6), ships miss (bias)")
for h in H:
    for lab, f in (("ended <55", lambda a: a < 55), ("ended >300", lambda a: a > 300)):
        s = [p for p in pts if f(p["act"][h])]
        if s:
            print(f"   {h} min {lab}: n={len(s)}, miss {mae(s, h, lambda p: pred(p, h, .6)):.1f} "
                  f"({st.mean(p['act'][h] - pred(p, h, .6) for p in s):+.1f}), no change {mae(s, h, lambda p: p['g']):.1f}")

print("\n== Part 2: does the line run past 40...400 without the hold?")
for gain in GAINS:
    under = [p for p in pts if min(line(p["g"], p["tr"], gain, lo=-1e9, hi=1e9).values()) < 40]
    over = [p for p in pts if max(line(p["g"], p["tr"], gain, lo=-1e9, hi=1e9).values()) > 400]
    changed = {h: sum(abs(line(p["g"], p["tr"], gain, lo=-1e9, hi=1e9)[h] - pred(p, h, gain)) > 1e-9 for p in pts) for h in H}
    lows = [min(line(p["g"], p["tr"], gain, lo=-1e9, hi=1e9).values()) for p in under]
    print(f"   gain {gain}: under 40 within 60 min {len(under)} (lowest {min(lows) if lows else float('nan'):.0f}, "
          f"actual at 60 min {sorted(p['act'][60] for p in under)}), over 400 {len(over)}; "
          f"hold changes the scored point at 15/30/60: {changed[15]}/{changed[30]}/{changed[60]}")

print("\n== Part 3: held out by day, miss at 15 / 30 / 60 (all points), and on starts over 250 / under 70")


def heldout(gain, options):
    held, picks = {}, []
    for dd in days:
        tr_ = [p for p in pts if p["day"] != dd and day(p["t"] + 3600) != dd]
        lab, kw = min(options, key=lambda o: sum(abs(p["act"][h] - pred(p, h, gain, **o[1])) for p in tr_ for h in (30, 60)))
        picks.append(lab)
        for p in pts:
            if p["day"] == dd:
                for h in H: held[(p["t"], h)] = pred(p, h, gain, **kw)
    return held, picks


def lows_lost(held, gain):
    """Low warnings (ships line under 70 within 30 min) the candidate drops, and the bias change
    where glucose ended under 80."""
    lost = sum(1 for p in pts if min(pred(p, h, gain) for h in (15, 30)) < 70 and min(held[(p["t"], h)] for h in (15, 30)) >= 70)
    s = [(p, h) for p in pts for h in H if p["act"][h] < 80]
    b0 = st.mean(p["act"][h] - pred(p, h, gain) for p, h in s); b1 = st.mean(p["act"][h] - held[(p["t"], h)] for p, h in s)
    raised = sum(held[(p["t"], h)] > pred(p, h, gain) + 1e-9 for p, h in s)
    return lost, b0, b1, raised


CANDS = {
    "ceiling": [(f"C={c}", dict(ceiling=c)) for c in (401, 375, 350, 325, 300, 275, 250)],
    "rise": [(f"w={w}", dict(w=w)) for w in (1.0, 0.75, 0.5, 0.25, 0.0)],
    "floor": [(f"F={f}", dict(floor=f)) for f in (39, 45, 50, 55)],
}
for gain in GAINS:
    print(f"-- gain {gain}")
    base = {(p["t"], h): pred(p, h, gain) for p in pts for h in H}
    for name, opts in CANDS.items():
        held, picks = heldout(gain, opts)
        def m(sel, h, src): s = [p for p in pts if sel(p)]; return st.mean(abs(p["act"][h] - src[(p["t"], h)]) for p in s)
        wins = {h: sum(m(lambda p, dd=dd: p["day"] == dd, h, held) < m(lambda p, dd=dd: p["day"] == dd, h, base) - 1e-9 for dd in days) for h in (30, 60)}
        line_ = "  ".join(f"{h}: {m(lambda p: True, h, base):.2f}→{m(lambda p: True, h, held):.2f}" for h in H)
        hi_ = "  ".join(f"{h}: {m(lambda p: p['g'] > 250, h, base):.1f}→{m(lambda p: p['g'] > 250, h, held):.1f}" for h in H)
        lo_ = "  ".join(f"{h}: {m(lambda p: p['g'] < 70, h, base):.1f}→{m(lambda p: p['g'] < 70, h, held):.1f}" for h in H)
        lost, b0, b1, raised = lows_lost(held, gain)
        print(f"   {name:7s} picks {','.join(sorted(set(picks)))} ({picks.count(opts[0][0])}/{len(days)} kept as ships)")
        print(f"           all {line_}; days won at 30/60 {wins[30]}/{wins[60]} of {len(days)}")
        print(f"           start >250 {hi_};  start <70 {lo_}")
        print(f"           low warnings lost {lost}; ended <80 bias {b0:+.1f}→{b1:+.1f}, lines raised {raised}")

print("\n== Part 4: a fixed ceiling, by day and by where glucose ended (gain 0.6)")
for c in (350, 325, 300, 275):
    row = []
    for dd in days:
        s_ = [p for p in pts if p["day"] == dd]
        d30 = mae(s_, 30, lambda p: pred(p, 30, .6, ceiling=c)) - mae(s_, 30, lambda p: pred(p, 30, .6))
        d60 = mae(s_, 60, lambda p: pred(p, 60, .6, ceiling=c)) - mae(s_, 60, lambda p: pred(p, 60, .6))
        if abs(d30) > 1e-9 or abs(d60) > 1e-9: row.append(f"{dd}:{d30:+.2f}/{d60:+.2f}")
    touched = {h: sum(pred(p, h, .6) > c for p in pts) for h in H}
    print(f"   C={c}: points held at 15/30/60 {touched[15]}/{touched[30]}/{touched[60]}; change in day miss 30/60 " + " ".join(row))
    for h in (30, 60):
        s_ = [p for p in pts if p["act"][h] > 300]
        t_ = [p for p in pts if pred(p, h, .6) > c]
        print(f"      {h} min: ended >300 n={len(s_)} miss {mae(s_, h, lambda p: pred(p, h, .6)):.1f}→{mae(s_, h, lambda p: pred(p, h, .6, ceiling=c)):.1f};"
              f" held points n={len(t_)} miss {mae(t_, h, lambda p: pred(p, h, .6)):.1f}→{mae(t_, h, lambda p: pred(p, h, .6, ceiling=c)):.1f},"
              f" actual there {min((p['act'][h] for p in t_), default=0)}–{max((p['act'][h] for p in t_), default=0)},"
              f" ended above C {sum(p['act'][h] > c for p in t_)}")
