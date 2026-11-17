#!/usr/bin/env python3
"""How much does the shown 30/60-minute forecast jump between readings, and would light smoothing help?
(ForecastAccuracy.md §66)

Usage: python3 scripts/forecast-jitter.py DIR
DIR holds readings.json ([[unix, mgdl], ...], live readings only, from glucos.readings where trend > 0).

Replays the engine's trend forecast (20-minute least-squares slope clamped at ±4, 30-minute fade, minute
midpoint integration, so the line is flat after 30 minutes and the 60-minute point equals the 30-minute
one) at every live reading, the way the app redraws it, at gains 0.45 (Mac, relay) and 0.6 (iPhone).

Jitter, between consecutive readings at most 90 s apart:
  jump   |f_h(t) − f_h(t−1)|, how far the shown h-minute point moves;
  excess the jump beyond what the reading itself moved (|Δf| − |Δg|, floored at 0);
  revise |f_h(t) − f_{h+1}(t−1)|, how far the forecast for the same clock time moves;
  flips  how often the line's direction (sign of f − g, ignoring |f − g| < 3) reverses, per hour.

Smoothing candidates, all on the shown offset d = f − g so the line still starts at the current reading,
reset after a gap over 3 minutes:
  ema α     d' = α·d + (1−α)·d'_prev   (blend with the previous forecast)
  hold X    keep d'_prev unless |d − d'_prev| > X, then take d
Scored on held-out days (pick on the other Perth days by 30 + 60 minute mean absolute error, score on the
left-out day) and against real turns: a peak or trough in the readings with a swing of at least 15 mg/dL
on both sides within 30 minutes. Turn lag is the minutes from the turn until the shown line first points
the new way (offset sign), shipped vs smoothed.
"""
import bisect, datetime as dt, json, statistics as st, sys

R = json.load(open(f"{sys.argv[1]}/readings.json"))
T = [r[0] for r in R]; G = [r[1] for r in R]
FADE, MAX, HS = 30.0, 4.0, (30, 60)

def slope(i, minutes=20, span=9):
    j = bisect.bisect_left(T, T[i] - minutes * 60)
    pts = [((T[k] - T[i]) / 60, G[k]) for k in range(j, i + 1)]
    if len(pts) < 2 or pts[-1][0] - pts[0][0] < span: return None  # engine: GlucoseSeries.slope needs 2
    mx = st.mean(p[0] for p in pts); my = st.mean(p[1] for p in pts)
    sxx = sum((p[0] - mx) ** 2 for p in pts)
    return max(-MAX, min(MAX, sum((p[0] - mx) * (p[1] - my) for p in pts) / sxx)) if sxx else None

def offset(tr, gain, h):  # f − g at horizon h
    return sum(max(0, 1 - (u + 0.5) / FADE) for u in range(min(h, 60))) * gain * tr

def at(t, tol=120):
    i = bisect.bisect_left(T, t)
    best = min((j for j in (i - 1, i) if 0 <= j < len(T)), key=lambda j: abs(T[j] - t), default=None)
    return best if best is not None and abs(T[best] - t) <= tol else None

def perth(t): return dt.datetime.fromtimestamp(t + 8 * 3600, dt.UTC).strftime("%d")

base = []  # one row per reading with a trend
for i in range(len(T)):
    tr = slope(i)
    if tr is None: continue
    hit = {h: at(T[i] + h * 60) for h in HS}
    base.append(dict(i=i, t=T[i], g=G[i], tr=tr, day=perth(T[i]),
                     act={h: None if hit[h] is None else G[hit[h]] for h in HS},
                     actday={h: None if hit[h] is None else perth(T[hit[h]]) for h in HS}))

def shown(gain, kind=None, p=None):
    """Shown offsets per row for horizons 30, 31 (for revise) and 60."""
    out, prev, prev_t = [], None, None
    for r in base:
        raw = {h: offset(r["tr"], gain, h) for h in (30, 31, 60)}
        if kind is None or prev is None or r["t"] - prev_t > 180:
            d = raw
        elif kind == "ema":
            d = {h: p * raw[h] + (1 - p) * prev[h] for h in raw}
        elif kind == "hold":
            d = raw if abs(raw[30] - prev[30]) > p else prev
        out.append(d); prev, prev_t = d, r["t"]
    return out

def jitter(d):
    j = {h: [] for h in HS}; ex = {h: [] for h in HS}; rv = {h: [] for h in HS}; flips = 0; mins = 0; sign = 0
    for k in range(1, len(base)):
        a, b = base[k - 1], base[k]
        if b["t"] - a["t"] > 90: sign = 0; continue
        mins += (b["t"] - a["t"]) / 60
        dg = b["g"] - a["g"]
        for h in HS:
            fa, fb = a["g"] + d[k - 1][h], b["g"] + d[k][h]
            j[h].append(abs(fb - fa)); ex[h].append(max(0, abs(fb - fa) - abs(dg)))
            rv[h].append(abs(fb - (a["g"] + d[k - 1][h + 1 if h == 30 else h])))
        s = 1 if d[k][30] >= 3 else -1 if d[k][30] <= -3 else 0
        if s and sign and s != sign: flips += 1
        if s: sign = s
    q = lambda xs, f: sorted(xs)[int(f * (len(xs) - 1))]
    return {h: (st.mean(j[h]), q(j[h], 0.9), st.mean(ex[h]), st.mean(rv[h])) for h in HS}, 60 * flips / mins

def errors(d, rows=None):
    e = {h: [] for h in HS}
    for k, r in enumerate(base):
        if rows is not None and r["day"] not in rows: continue
        for h in HS:
            if rows is not None and r["actday"][h] not in rows: continue  # actual on the same held-out days
            if r["act"][h] is not None: e[h].append(abs(r["act"][h] - (r["g"] + d[k][h])))
    return {h: st.mean(e[h]) if e[h] else float("nan") for h in HS}, {h: len(e[h]) for h in HS}

# Real turns: local extreme with ≥15 mg/dL swing on both sides within 30 min, at least 30 min apart.
turns = []
for k, r in enumerate(base):
    i = r["i"]; lo = bisect.bisect_left(T, T[i] - 1800); hi = bisect.bisect_right(T, T[i] + 1800)
    if hi - lo < 40: continue
    seg = G[lo:hi]
    for kind, ext in (("peak", max), ("trough", min)):
        if G[i] != ext(seg): continue
        before, after = G[lo:i + 1], G[i:hi]
        sw = (G[i] - min(before), G[i] - min(after)) if kind == "peak" else (max(before) - G[i], max(after) - G[i])
        if min(sw) >= 15 and (not turns or T[i] - turns[-1][1] >= 1800):
            turns.append((k, T[i], kind))

def lags(d):
    out = []
    for k, t, kind in turns:
        want = -1 if kind == "peak" else 1
        lag = None
        for m in range(k, len(base)):
            if base[m]["t"] - t > 1800: break
            if want * d[m][30] > 0 and (m == k or True) and base[m]["t"] > t:
                lag = (base[m]["t"] - t) / 60; break
        out.append(lag if lag is not None else 30.0)
    return out

days = sorted({r["day"] for r in base})
print(f"{len(base)} replayed forecasts (one per live reading), Perth days {days}, {len(turns)} real turns")
CANDS = [("ema", a) for a in (0.7, 0.5, 0.35, 0.25)] + [("hold", x) for x in (1.0, 2.0, 3.0)]
for gain in (0.45, 0.6):
    ship = shown(gain); js, fl = jitter(ship); es, ns = errors(ship); ls = lags(ship)
    print(f"\n== Gain {gain} ==  n scored 30/60: {ns[30]}/{ns[60]}")
    def row(name, d):
        jj, ff = jitter(d); ee, _ = errors(d); ll = lags(d)
        print(f"  {name:10s} " + "  ".join(f"{h}m jump {jj[h][0]:4.2f} (p90 {jj[h][1]:4.1f}) excess {jj[h][2]:4.2f} revise {jj[h][3]:4.2f} mae {ee[h]:5.2f}" for h in HS)
              + (f"  flips/h {ff:4.2f}  turn lag mean {st.mean(ll):4.1f} med {st.median(ll):4.1f} min" if ll else f"  flips/h {ff:4.2f}  turn lag n/a (no turns)"))
    row("shipped", ship)
    for c in CANDS: row(f"{c[0]} {c[1]}", shown(gain, *c))
    # leave one day out
    print("  leave one Perth day out (pick by 30+60 MAE on the other days):")
    tot = {h: [0, 0, 0] for h in HS}; better = {h: [0, 0] for h in HS}
    for dd in days:
        others = set(days) - {dd}
        if any(errors(ship, {dd})[1][h] == 0 for h in HS):
            print(f"    {dd} Nov: no scoreable 30/60-min actuals, skipped"); continue
        best = min([None] + CANDS, key=lambda c: sum(errors(ship if c is None else shown(gain, *c), others)[0].values()))
        dsel = ship if best is None else shown(gain, *best)
        b0, n0 = errors(ship, {dd}); b1, _ = errors(dsel, {dd})
        print(f"    {dd} Nov picks {best}: 30m {b0[30]:.2f}→{b1[30]:.2f}  60m {b0[60]:.2f}→{b1[60]:.2f}")
        for h in HS:
            tot[h][0] += b0[h] * n0[h]; tot[h][1] += b1[h] * n0[h]; tot[h][2] += n0[h]
            better[h][0] += b1[h] < b0[h] - 1e-9; better[h][1] += b1[h] > b0[h] + 1e-9
    for h in HS:
        a, b = tot[h][0] / tot[h][2], tot[h][1] / tot[h][2]
        print(f"    held out {h}m: {a:.2f} → {b:.2f} ({100 * (b - a) / a:+.1f}%), better on {better[h][0]}, worse on {better[h][1]} of {len(days)} days")
    # per-day for the lightest blend
    print("  per day, ema 0.5 vs shipped (30m MAE):")
    e5 = shown(gain, "ema", 0.5)
    print("    " + "  ".join(f"{dd}: {errors(ship, {dd})[0][30]:.1f}→{errors(e5, {dd})[0][30]:.1f}" for dd in days))

# How much of the jump is the reading itself, and how big the line's own moves get (gain 0.45).
ship = shown(0.45)
dg, dd = [], []
for k in range(1, len(base)):
    if base[k]["t"] - base[k - 1]["t"] > 90: continue
    dg.append(abs(base[k]["g"] - base[k - 1]["g"])); dd.append(abs(ship[k][30] - ship[k - 1][30]))
q = lambda xs, f: sorted(xs)[int(f * (len(xs) - 1))]
print(f"\nReading moves |Δg| mean {st.mean(dg):.2f}; line's own offset change |Δd| mean {st.mean(dd):.2f}, "
      f"p90 {q(dd, .9):.1f}, p99 {q(dd, .99):.1f}, max {max(dd):.1f}; |Δd| ≥ 5 on {100 * sum(x >= 5 for x in dd) / len(dd):.1f}% of readings")
