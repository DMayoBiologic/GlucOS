#!/usr/bin/env python3
"""Forecasts after single-reading spikes, and would rejecting them help? (ForecastAccuracy.md §74)

Usage: python3 scripts/reading-spikes.py DIR
DIR holds readings.json: [[unix, mgdl, live], ...] for every row of glucos.readings (live = 1 when
trend > 0, the LinkUp glucoseMeasurement; 0 is a 15-minute graphData history point). Export as in
scripts/sensor-limits.py, or delta-coded to keep it under the MCP limit:

    with r as (select extract(epoch from at)::bigint e, round(mgdl)::int v, (trend > 0)::int l
               from glucos.readings),
         d as (select e - lag(e) over (order by e) de, v - lag(v) over (order by e) dv, e, v, l from r)
    select count(*), sum(v), min(e), (select v from r order by e limit 1),
           string_agg(coalesce(de, 0)::text || ',' || coalesce(dv, 0)::text ||
                      (case when l = 1 then '' else 'h' end), ';' order by e) from d;

Check the count and sum against the decoded rows.

A spike is one reading more than S mg/dL (15) away from both neighbours in the same direction,
with the neighbours back within 10 of each other and each under 3 minutes away.

Part 1, where spikes come from: in the merged series the engine fits (live + history twins), and
in the live readings alone.

Part 2, error after spikes. The engine's trend forecast as in §72/§73 (20-minute least-squares slope
over every stored reading, clamped at ±4, 30-minute fade, line held to 39...401) made at every live
reading, started from that live reading, scored at 15/30/60 min against the nearest live reading.
"After a spike" = a spike sits in the 20-minute slope window. Gains 0.45 (Mac/relay), 0.6, 0.7.

Part 3, held out (leave one Perth day out, pick on the other days by miss at 30 + 60, training drops
points whose 60-minute target lands on the left-out day). Candidates, each with an "off" option:
  retro  leave a confirmed spike (both neighbours already in) out of the slope fit, S in 25/20/15/10
  twin   leave a history point out of the fit when a live reading within 90 s differs by more than D,
         D in 25/20/15/10 (needs no later reading)
  hold   when the newest live reading jumps more than S from the one before, forecast from the one
         before until the next arrives, S in 25/20/15 (the only rule that can catch a spike as it
         happens; it costs a minute on every real jump)
Ship bar: better held out at both 30 and 60, no low warning (line under 70 within 30 min) later or
lost, and no line raised where glucose ended under 80.
"""
import bisect, datetime as dt, json, statistics as st, sys

R = sorted(json.load(open(f"{sys.argv[1]}/readings.json")))
T = [r[0] for r in R]
LIVE = [r for r in R if r[2] == 1]
TL = [r[0] for r in LIVE]
FADE, TREND_W, MAX, LO, HI = 30.0, 20, 4.0, 39.0, 401.0
GAINS = (0.45, 0.6, 0.7)
H = (15, 30, 60)
GAP, REV = 180, 10


def day(t): return dt.datetime.fromtimestamp(t + 8 * 3600, dt.UTC).strftime("%d")


def find_spikes(rows, s=15):
    """Indices into rows of single-reading spikes, with (jump from previous, jump to next)."""
    out = {}
    for i in range(1, len(rows) - 1):
        p, c, n = rows[i - 1], rows[i], rows[i + 1]
        if c[0] - p[0] > GAP or n[0] - c[0] > GAP: continue
        a, b = c[1] - p[1], c[1] - n[1]
        if a * b > 0 and min(abs(a), abs(b)) > s and abs(n[1] - p[1]) <= REV: out[i] = (a, -b)
    return out


SPIKES = {s: find_spikes(R, s) for s in (25, 20, 15, 10)}
# When each spike is confirmed: its next reading's time.
CONF = {s: {i: T[i + 1] for i in d} for s, d in SPIKES.items()}
# History points whose live twin (within 90 s) differs by more than D.
TWIN_DIFF = {}
for i, r in enumerate(R):
    if r[2] == 0:
        k = bisect.bisect_left(TL, r[0])
        near = [LIVE[j] for j in (k - 1, k) if 0 <= j < len(TL) and abs(TL[j] - r[0]) <= 90]
        if near: TWIN_DIFF[i] = min(abs(x[1] - r[1]) for x in near)


def slope(t, skip=lambda i: False):
    i, j = bisect.bisect_left(T, t - TREND_W * 60), bisect.bisect_right(T, t)
    pts = [((T[k] - t) / 60, R[k][1]) for k in range(i, j) if not skip(k)]
    if len(pts) < 3 or pts[-1][0] - pts[0][0] < 9: return None
    mx = st.mean(p[0] for p in pts); my = st.mean(p[1] for p in pts)
    sxx = sum((p[0] - mx) ** 2 for p in pts)
    return max(-MAX, min(MAX, sum((p[0] - mx) * (p[1] - my) for p in pts) / sxx)) if sxx else None


def line(g, tr, gain):
    out, u = {}, 0
    while u < 60:
        g += max(0, 1 - (u + 0.5) / FADE) * gain * tr
        u += 1
        out[u] = min(HI, max(LO, g))
    return out


def nearest_live(t, tol=120):
    i = bisect.bisect_left(TL, t)
    best = min((j for j in (i - 1, i) if 0 <= j < len(TL)), key=lambda j: abs(TL[j] - t), default=None)
    return LIVE[best][1] if best is not None and abs(TL[best] - t) <= tol else None


# Forecast points: every live reading with a slope and live actuals at 15/30/60.
pts = []
for k, (t, g, _) in enumerate(LIVE):
    if not 40 <= g <= 400: continue
    act = {h: nearest_live(t + h * 60) for h in H}
    if None in act.values(): continue
    base_tr = slope(t)
    if base_tr is None: continue
    lo_i, hi_i = bisect.bisect_left(T, t - TREND_W * 60), bisect.bisect_right(T, t)
    in_win = {s: [i for i in range(lo_i, hi_i) if i in SPIKES[s]] for s in SPIKES}
    prev = LIVE[k - 1] if k > 0 and t - LIVE[k - 1][0] <= GAP else None
    pts.append(dict(t=t, g=g, tr=base_tr, act=act, day=day(t), win=in_win, prev=prev, lo=lo_i, hi=hi_i))
days = sorted({p["day"] for p in pts})


def make(p, rule, x, gain):
    """The line for point p under a rule; (start, trend) recomputed only when the rule touches it."""
    g, tr = p["g"], p["tr"]
    if rule == "retro" and x is not None:
        drop = {i for i in p["win"][x] if CONF[x][i] <= p["t"]}
        if drop: tr = slope(p["t"], lambda i: i in drop) or 0.0
    elif rule == "twin" and x is not None:
        drop = {i for i in range(p["lo"], p["hi"]) if TWIN_DIFF.get(i, -1) > x}
        if drop: tr = slope(p["t"], lambda i: i in drop) or 0.0
    elif rule == "hold" and x is not None and p["prev"] and abs(p["g"] - p["prev"][1]) > x:
        g = p["prev"][1]; tr = slope(p["prev"][0]) or 0.0
    return line(g, tr, gain)


CACHE = {}


def L(p, rule, x, gain):
    key = (p["t"], rule, x, gain)
    if key not in CACHE: CACHE[key] = make(p, rule, x, gain)
    return CACHE[key]


def mae(s, h, f): return st.mean(abs(p["act"][h] - f(p)) for p in s) if s else float("nan")


print(f"{len(R)} readings ({len(LIVE)} live, {len(R) - len(LIVE)} history), {len(pts)} forecast points, "
      f"{len(days)} Perth days ({days[0]}–{days[-1]} Nov)")

print("\n== Part 1: where single-reading spikes come from")
live_rows = [[r[0], r[1], 1] for r in LIVE]
for s in (25, 20, 15, 10):
    m = SPIKES[s]; lv = find_spikes(live_rows, s)
    print(f"   > {s} mg/dL: merged series {len(m)} (history points {sum(R[i][2] == 0 for i in m)}, "
          f"up {sum(a > 0 for a, _ in m.values())}), live readings alone {len(lv)}")
print("   spikes > 15 in the merged series (Perth time, previous / spike / next, source, glucose):")
for i, (a, b) in SPIKES[15].items():
    print(f"     {dt.datetime.fromtimestamp(T[i] + 8 * 3600, dt.UTC):%d %b %H:%M}  {R[i - 1][1]:3.0f} / {R[i][1]:3.0f} / "
          f"{R[i + 1][1]:3.0f}  {'live' if R[i][2] else 'history'}  twin diff {TWIN_DIFF.get(i, float('nan')):.0f}")
lv1 = [abs(b[1] - a[1]) for a, b in zip(LIVE, LIVE[1:]) if b[0] - a[0] <= GAP]
print(f"   live minute-to-minute change: mean {st.mean(lv1):.2f}, p99 {sorted(lv1)[int(.99 * len(lv1))]}, "
      f"max {max(lv1)}, over 15: {sum(x > 15 for x in lv1)}")
td = sorted(TWIN_DIFF.values())
print(f"   history points with a live twin: {len(td)}, |diff| mean {st.mean(td):.1f}, over 15: {sum(x > 15 for x in td)}, "
      f"over 10: {sum(x > 10 for x in td)}")

print("\n== Part 2: miss after a spike (a spike > 15 in the slope window) vs the rest; no change / ships (bias)")
aff = [p for p in pts if p["win"][15]]
rest = [p for p in pts if not p["win"][15]]
for gain in GAINS:
    print(f"-- gain {gain}")
    for lab, s in (("after a spike", aff), ("rest", rest)):
        print(f"   {lab:14s} n={len(s):5d} ({len({p['t'] // 3600 for p in s})} h) " + "  ".join(
            f"{h}: {mae(s, h, lambda p: p['g']):5.1f} / {mae(s, h, lambda p: L(p, None, None, gain)[h]):5.1f} "
            f"({st.mean(p['act'][h] - L(p, None, None, gain)[h] for p in s):+5.1f})" for h in H))
    up = [p for p in aff if sum(SPIKES[15][i][0] for i in p["win"][15]) > 0]
    dn = [p for p in aff if p not in up]
    for lab, s in (("  spike up", up), ("  spike down", dn)):
        if s: print(f"   {lab:14s} n={len(s):5d} " + "  ".join(
            f"{h}: bias {st.mean(p['act'][h] - L(p, None, None, gain)[h] for p in s):+5.1f}" for h in H))
    dtr = [abs(slope(p["t"], lambda i, p=p: i in p["win"][15]) - p["tr"]) for p in aff
           if slope(p["t"], lambda i, p=p: i in p["win"][15]) is not None]
    if gain == GAINS[0]: print(f"   trend shift from one spike: mean {st.mean(dtr):.2f}, max {max(dtr):.2f} mg/dL/min")

print("\n== Part 3: held out by day; miss at 15 / 30 / 60, all points and after a spike")
CANDS = {"retro": [None, 25, 20, 15, 10], "twin": [None, 25, 20, 15, 10], "hold": [None, 25, 20, 15]}


def warns(ln): return min(ln[u] for u in range(1, 31)) < 70


for gain in GAINS:
    print(f"-- gain {gain}")
    for rule, opts in CANDS.items():
        held, picks = {}, []
        for dd in days:
            tr_ = [p for p in pts if p["day"] != dd and day(p["t"] + 3600) != dd]
            x = min(opts, key=lambda o: sum(abs(p["act"][h] - L(p, rule, o, gain)[h]) for p in tr_ for h in (30, 60)))
            picks.append(x)
            for p in pts:
                if p["day"] == dd: held[p["t"]] = L(p, rule, x, gain)
        b = {p["t"]: L(p, None, None, gain) for p in pts}
        def m(s, h, src): return st.mean(abs(p["act"][h] - src[p["t"]][h]) for p in s)
        wins = {h: sum(m([p for p in pts if p["day"] == dd], h, held) < m([p for p in pts if p["day"] == dd], h, b) - 1e-9
                       for dd in days) for h in (30, 60)}
        losses = {h: sum(m([p for p in pts if p["day"] == dd], h, held) > m([p for p in pts if p["day"] == dd], h, b) + 1e-9
                         for dd in days) for h in (30, 60)}
        lost = sum(warns(b[p["t"]]) and not warns(held[p["t"]]) for p in pts)
        gained = sum(warns(held[p["t"]]) and not warns(b[p["t"]]) for p in pts)
        lowpts = [(p, h) for p in pts for h in H if p["act"][h] < 80]
        raised = sum(held[p["t"]][h] > b[p["t"]][h] + 1e-9 for p, h in lowpts)
        changed = sum(any(abs(held[p["t"]][h] - b[p["t"]][h]) > 1e-9 for h in H) for p in pts)
        print(f"   {rule:5s} picks {sorted(set(map(str, picks)))} (off on {picks.count(None)}/{len(days)} days), {changed} forecasts changed")
        print("          all " + "  ".join(f"{h}: {m(pts, h, b):.2f}→{m(pts, h, held):.2f}" for h in H)
              + f"; days better/worse at 30 {wins[30]}/{losses[30]}, at 60 {wins[60]}/{losses[60]}")
        print("          after a spike " + "  ".join(f"{h}: {m(aff, h, b):.2f}→{m(aff, h, held):.2f}" for h in H))
        print(f"          low warnings lost {lost}, new {gained}; lines raised where glucose ended <80: {raised}")

print("\n== Part 4: each rule at a fixed setting, all points (gain 0.6), and low warnings")
for rule, opts in CANDS.items():
    for x in opts[1:]:
        ch = [p for p in pts if any(abs(L(p, rule, x, .6)[h] - L(p, None, None, .6)[h]) > 1e-9 for h in H)]
        lost = sum(warns(L(p, None, None, .6)) and not warns(L(p, rule, x, .6)) for p in pts)
        print(f"   {rule} {x}: changed {len(ch)}; all " + "  ".join(
            f"{h}: {mae(pts, h, lambda p: L(p, None, None, .6)[h]):.2f}→{mae(pts, h, lambda p: L(p, rule, x, .6)[h]):.2f}" for h in H)
            + (("; changed only " + "  ".join(f"{h}: {mae(ch, h, lambda p: L(p, None, None, .6)[h]):.1f}→"
                f"{mae(ch, h, lambda p: L(p, rule, x, .6)[h]):.1f}" for h in H)) if ch else "") + f"; low warnings lost {lost}")
