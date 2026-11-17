#!/usr/bin/env python3
"""Are forecasts worse when the latest reading sits at a local peak or trough, and would damping the
trend there help? (ForecastAccuracy.md §71)

Usage: python3 scripts/turning-points.py DIR
DIR holds readings.json ([[unix, mgdl], ...], live readings only, from glucos.readings where trend > 0)
and logs.json ([[unix, "meal" | "dose"], ...] from glucos.logbook, rapid doses only), as for
scripts/trend-reversal.py (§59).

Replays the engine's trend forecast (20-minute least-squares slope clamped at ±4, 30-minute fade,
minute midpoint integration) every 5 minutes, issued at the latest reading in each 5-minute slot, and
scores it at 15, 30 and 60 minutes at the gains the tuner fits (0.45 Mac/relay, 0.6, 0.7 iPhone).

Turning point, judged only from what the app has at issue time: take the readings nearest to now,
5, 10 and 15 minutes ago (each within 90 s, so one reading a minute of noise is not a turn). A peak
is a reading among the last three 5-minute readings (5 or 10 minutes ago) that is higher than the
5-minute readings either side of it by at least M mg/dL on each side; a trough is lower by M. M is
1, 3 and 5. The latest reading itself can't be judged until the next one lands, so "the latest
reading is a turning point" means the turn is in the last 10 minutes.

Fix, fitted on six Perth days and scored on the seventh (objective: miss at 30 + 60 minutes):
  damp   at a turning point, the trend is scaled by w (1 = as ships, 0 = no change),
         w in 1, 0.75, 0.5, 0.25, 0, with three variants:
           all      every turning point
           into     only when the trend still points into the turn (rising at a peak, falling at a
                    trough), the case where it is most likely stale
           peaks    only at peaks with a rising trend (can only lower a forecast, so it can never
                    make a low warning later)
Ship bar: better held out at both 30 and 60 minutes, and no low warning later or lows forecast higher.
"""
import bisect, datetime as dt, json, statistics as st, sys

d = sys.argv[1]
R = json.load(open(f"{d}/readings.json"))
L = json.load(open(f"{d}/logs.json"))
T = [r[0] for r in R]
G = {r[0]: r[1] for r in R}
meals = sorted(t for t, k in L if k == "meal")
FADE, TREND_W, MAX = 30.0, 20, 4.0
GAINS = (0.45, 0.6, 0.7)
H = (15, 30, 60)
MS = (1, 3, 5)
WS = (1.0, 0.75, 0.5, 0.25, 0.0)
VARIANTS = ("all", "into", "peaks")

def window(t, minutes):
    i, j = bisect.bisect_left(T, t - minutes * 60), bisect.bisect_right(T, t)
    return [((T[k] - t) / 60, R[k][1]) for k in range(i, j)]

def slope(pts, span=9):
    if len(pts) < 3 or pts[-1][0] - pts[0][0] < span: return None
    mx = st.mean(p[0] for p in pts); my = st.mean(p[1] for p in pts)
    sxx = sum((p[0] - mx) ** 2 for p in pts)
    return max(-MAX, min(MAX, sum((p[0] - mx) * (p[1] - my) for p in pts) / sxx)) if sxx else None

def line(g, trend, gain, minutes=60):
    out, u = {}, 0
    while u < minutes:
        w = max(0, 1 - (u + 0.5) / FADE)
        g += w * gain * trend
        u += 1
        out[u] = g
    return out

def at(t, tol=90):
    i = bisect.bisect_left(T, t)
    best = min((j for j in (i - 1, i) if 0 <= j < len(T)), key=lambda j: abs(T[j] - t), default=None)
    return R[best][1] if best is not None and abs(T[best] - t) <= tol else None

def perth_day(t): return dt.datetime.fromtimestamp(t + 8 * 3600, dt.UTC).strftime("%d")

def turn(t, M):
    """+1 peak, -1 trough, 0 none, None if the 5-minute readings are missing."""
    g = [at(t - k * 300) for k in (0, 1, 2, 3)]  # now, 5, 10, 15 min ago
    if g[0] is None: return None
    for mid in (1, 2):
        a, b, c = g[mid - 1], g[mid], g[mid + 1]  # newer, middle, older
        if None in (a, b, c): continue
        if b - a >= M and b - c >= M: return 1
        if a - b >= M and c - b >= M: return -1
    return 0 if None not in g[:3] else None

pts = []
for slot in range(T[0] - T[0] % 300 + 300, T[-1] - 3600, 300):
    i = bisect.bisect_right(T, slot) - 1
    if i < 0 or slot - T[i] >= 60: continue
    t = T[i]
    tr = slope(window(t, TREND_W))
    if tr is None: continue
    act = {h: at(t + h * 60, 120) for h in H}
    if None in act.values(): continue
    tp = {M: turn(t, M) for M in MS}
    if None in tp.values(): continue
    j = bisect.bisect_right(meals, t) - 1
    pts.append(dict(t=t, g=G[t], tr=tr, act=act, day=perth_day(t), tp=tp,
                    meal=j >= 0 and t - meals[j] < 3 * 3600))
days = sorted({p["day"] for p in pts})

def applies(p, M, variant):
    k = p["tp"][M]
    if not k: return False
    if variant == "all": return True
    if variant == "into": return p["tr"] * k > 0
    return k > 0 and p["tr"] > 0

def pred(p, h, gain, M=None, variant=None, w=1.0):
    tr = p["tr"]
    if M is not None and applies(p, M, variant): tr *= w
    return line(p["g"], tr, gain)[h]

def mae(s, h, f): return st.mean(abs(p["act"][h] - f(p)) for p in s)

print(f"{len(pts)} forecast points over {len(days)} Perth days ({days[0]}–{days[-1]} Nov), "
      f"{sum(p['meal'] for p in pts)} within 3 h of a meal")

# 1. How much worse at turning points?
print("\n== Miss at turning points vs the rest (gain 0.6): no change / ships, bias = actual - ships")
for M in MS:
    tp = [p for p in pts if p["tp"][M]]; rest = [p for p in pts if not p["tp"][M]]
    pk = [p for p in tp if p["tp"][M] > 0]; tg = [p for p in tp if p["tp"][M] < 0]
    print(f"-- M={M}: {len(tp)} turning points ({100 * len(tp) / len(pts):.0f}%), {len(pk)} peaks "
          f"({sum(p['tr'] > 0 for p in pk)} with the trend still rising), {len(tg)} troughs "
          f"({sum(p['tr'] < 0 for p in tg)} still falling); {sum(p['meal'] for p in tp)} within 3 h of a meal")
    for h in H:
        def c(s): return (f"{mae(s, h, lambda p: p['g']):5.1f} / {mae(s, h, lambda p: pred(p, h, .6)):5.1f} "
                          f"({st.mean(p['act'][h] - pred(p, h, .6) for p in s):+5.1f})")
        print(f"   {h:2d} min  turning {c(tp)}  peaks {c(pk)}  troughs {c(tg)}  rest {c(rest)}")

# 2. Held out damping.
print("\n== Held out (leave one Perth day out); objective = miss at 30 + 60 min")
summary = []
for M in MS:
    for variant in VARIANTS:
        for gain in GAINS:
            held = {}; picks = []
            for day in days:
                tr_ = [p for p in pts if p["day"] != day]; te = [p for p in pts if p["day"] == day]
                w = min(WS, key=lambda w: (sum(abs(p["act"][h] - pred(p, h, gain, M, variant, w))
                                               for p in tr_ for h in (30, 60)), -w))
                picks.append(w)
                for p in te:
                    for h in H: held[(p["t"], h)] = abs(p["act"][h] - pred(p, h, gain, M, variant, w))
            row = []
            for h in H:
                b = mae(pts, h, lambda p: pred(p, h, gain))
                a = st.mean(held[(p["t"], h)] for p in pts)
                row.append((h, b, a, (a / b - 1) * 100))
            tps = [p for p in pts if applies(p, M, variant)]
            tp_row = [(h, mae(tps, h, lambda p: pred(p, h, gain)), st.mean(held[(p["t"], h)] for p in tps)) for h in (30, 60)] if tps else []
            better = {h: sum(st.mean(held[(p["t"], h)] for p in pts if p["day"] == dd) <
                             mae([p for p in pts if p["day"] == dd], h, lambda p: pred(p, h, gain)) - 1e-9 for dd in days) for h in (30, 60)}
            summary.append((M, variant, gain, row, better))
            print(f"-- M={M} {variant:5s} gain {gain}: picks w {picks}, n affected {len(tps)}")
            print("   all: " + "  ".join(f"{h}: {b:5.2f} -> {a:5.2f} ({pc:+4.1f}%)" for h, b, a, pc in row)
                  + f"   days better 30/60: {better[30]}/{better[60]} of {len(days)}")
            if tp_row:
                print("   affected points: " + "  ".join(f"{h}: {b:5.1f} -> {a:5.1f}" for h, b, a in tp_row))

wins = [s for s in summary if s[3][1][3] < 0 and s[3][2][3] < 0]
print(f"\n== Held-out wins at both 30 and 60: {len(wins)}")
for M, variant, gain, row, better in wins:
    print(f"   M={M} {variant} gain {gain}: 30 {row[1][3]:+.1f}%, 60 {row[2][3]:+.1f}%, days 30/60 {better[30]}/{better[60]}")

# 3. Fixed settings, all days.
print("\n== Fixed damping, gain 0.6, all days: miss at 15 / 30 / 60")
for M in MS:
    for variant in VARIANTS:
        print(f"   M={M} {variant:5s} " + "  ".join(
            f"w={w}: " + "/".join(f"{mae(pts, h, lambda p: pred(p, h, .6, M, variant, w)):5.2f}" for h in H) for w in WS))

# 4. Lows: forecast bias before lows and low warnings, damping at full strength (worst case).
lows, below = [], False
for t, g in R:
    if g < 70 and not below and (not lows or t - lows[-1] > 3600): lows.append(t)
    below = g < 70
def warn(t, M, variant, w, gain):
    tr = slope(window(t, TREND_W))
    if tr is None: return False
    if M is not None:
        k = turn(t, M)
        p = dict(tp={M: k}, tr=tr)
        if k is not None and applies(p, M, variant): tr *= w
    return min(line(G[t], tr, gain, 30).values()) < 70
def first_warning(low, *a):
    for t in T[bisect.bisect_left(T, low - 90 * 60):bisect.bisect_right(T, low)]:
        if G[t] >= 70 and warn(t, *a): return (low - t) / 60
    return 0.0
print(f"\n== Lows: {len(lows)} lows under 70. Minutes of warning (trend carried 30 min); "
      f"30-min forecast bias where the actual was under 80")
for gain in GAINS:
    for M in MS:
        for variant in VARIANTS:
            for w in (0.5, 0.0):
                ws = [(first_warning(l, None, None, 1, gain), first_warning(l, M, variant, w, gain)) for l in lows]
                later = [(dt.datetime.fromtimestamp(l + 8 * 3600, dt.UTC).strftime("%d %H:%M"), a, b)
                         for l, (a, b) in zip(lows, ws) if b < a]
                lo = [p for p in pts if p["act"][30] < 80]
                b0 = st.mean(p["act"][30] - pred(p, 30, gain) for p in lo)
                b1 = st.mean(p["act"][30] - pred(p, 30, gain, M, variant, w) for p in lo)
                print(f"   gain {gain} M={M} {variant:5s} w={w}: later on {len(later)} {later}; "
                      f"low-end bias {b0:+.2f} -> {b1:+.2f} (n={len(lo)})")

# 5. Highs: the peaks variant lowers rising forecasts at peaks, so predicted highs can come later.
#    Highs = first reading above 180 after at least an hour at or under it; warning = minutes before
#    it that the trend line carried 30 min first went above 180 (from at or under 180). False alarm
#    = the line went above 180 but no reading did in the next 45 min.
highs, above = [], False
for t, g in R:
    if g > 180 and not above and (not highs or t - highs[-1] > 3600): highs.append(t)
    above = g > 180
def warn_high(t, M, variant, w, gain):
    tr = slope(window(t, TREND_W))
    if tr is None: return False
    if M is not None:
        k = turn(t, M)
        if k is not None and applies(dict(tp={M: k}, tr=tr), M, variant): tr *= w
    return max(line(G[t], tr, gain, 30).values()) > 180
def high_warning(hi, *a):
    for t in T[bisect.bisect_left(T, hi - 90 * 60):bisect.bisect_right(T, hi)]:
        if G[t] <= 180 and warn_high(t, *a): return (hi - t) / 60
    return 0.0
def false_highs(*a):
    n, last = 0, -1e18
    for t in T:
        if G[t] > 180 or t - last < 45 * 60: continue
        if warn_high(t, *a):
            last = t
            j = bisect.bisect_right(T, t)
            if not any(G[T[k]] > 180 for k in range(j, bisect.bisect_right(T, t + 45 * 60))): n += 1
    return n
print(f"\n== Highs: {len(highs)} highs over 180. Warnings (median / mean minutes), highs warned later, false alarms")
for gain in GAINS:
    base = [high_warning(h, None, None, 1, gain) for h in highs]
    print(f"   gain {gain} ships: median {st.median(base):.1f} mean {st.mean(base):.1f}, false alarms {false_highs(None, None, 1, gain)}")
    for M in MS:
        w_ = [high_warning(h, M, "peaks", 0.0, gain) for h in highs]
        later = [(dt.datetime.fromtimestamp(h + 8 * 3600, dt.UTC).strftime("%d %H:%M"), round(a, 1), round(b, 1))
                 for h, a, b in zip(highs, base, w_) if b < a - 0.01]
        print(f"   gain {gain} M={M} peaks w=0: median {st.median(w_):.1f} mean {st.mean(w_):.1f}, "
              f"false alarms {false_highs(M, 'peaks', 0.0, gain)}, later on {len(later)} {later}")

# 6. Against §45's rises-only easing (S=5, k=1, floor 0), which also takes a rising trend to zero once the
#    last 5 minutes stop rising: how much of the peaks variant does it already cover?
def s45(p):
    if "s5" not in p: p["s5"] = slope(window(p["t"], 5), span=3)
    s5 = p["s5"]
    return p["tr"] * max(s5 / p["tr"], 0) if p["tr"] > 0 and s5 is not None and s5 < p["tr"] else p["tr"]
print("\n== Against §45 rises-only easing (fixed S=5 k=1 floor 0), all days: miss at 15 / 30 / 60")
for gain in GAINS:
    def f(trf): return "/".join(f"{st.mean(abs(p['act'][h] - line(p['g'], trf(p), gain)[h]) for p in pts):5.2f}" for h in H)
    print(f"   gain {gain}: ships {f(lambda p: p['tr'])}  §45 {f(s45)}  "
          f"peaks M=1 w=0 {f(lambda p: 0.0 if applies(p, 1, 'peaks') else p['tr'])}  "
          f"both {f(lambda p: 0.0 if applies(p, 1, 'peaks') else s45(p))}")
    pk = [p for p in pts if applies(p, 1, "peaks")]
    print(f"     of {len(pk)} peak points §45 already eases {sum(s45(p) < p['tr'] for p in pk)}, "
          f"to zero {sum(s45(p) == 0 for p in pk)}")
