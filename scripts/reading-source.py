#!/usr/bin/env python3
"""Does forecast error depend on where the readings came from? (ForecastAccuracy.md §72)

Usage: python3 scripts/reading-source.py DIR
DIR holds readings.json: [[unix, mgdl, live], ...] for every row of glucos.readings, live = 1 when
trend > 0 (LibreLinkUp's current glucoseMeasurement, one a minute) and 0 for the 15-minute
graphData history points the relay merges in (they carry no trend arrow).

Direct readings (NFC Read sensor, Bluetooth "Live from sensor") would be a third source, but none
exist: the sensor is a Gen2 Libre 2 Plus that refuses plain reads (§ glucos sensor notes, PR #42 and
#44), the Bluetooth takeover (#40) was never merged, and the NFC screen only shows its readings, it
never stores them. So the comparison that can be made is the one inside LinkUp: live minute
readings against the 15-minute history.

Part 1, the sources side by side: how often a history point has a live reading within 90 s, and how
far apart the two values are (history minus live).

Part 2, error by source. The engine's trend forecast (20-minute least-squares slope clamped at ±4,
30-minute fade, the tuner's gains 0.45 Mac/relay, 0.6 and 0.7 iPhone) every 5 minutes, issued at
the latest reading of any source, scored at 15, 30 and 60 minutes against the nearest live reading
(falling back to history). The trend is fitted on every stored reading, as the relay does (its
Series keeps both sources; a history point usually sits a few seconds from a live one). Each point
is classed by its 20-minute window:
  live     no live minute missing (no gap over 90 s between live readings, at least 4 of them)
  filled   at least one live gap over 90 s, bridged by a history point or by nothing
and by which source the latest reading (the forecast's start) came from. Also: the same forecasts
scored against a history point instead of the live reading at the same moment.

Part 3, held out. Candidates, each picked on all but one Perth day by miss at 30 + 60 minutes and
scored on the left-out day (training drops points whose
60-minute target lands on the left-out day):
  prefer   fit the trend without history points that have a live twin within 90 s (history kept
           only where it fills a missing minute; a twin counts only if it had
           arrived by the forecast's start), and start from the latest live reading when one
           is within 90 s of a history start. Picked against "as ships" per fold.
  scale    in filled windows, scale the trend by w (1 = as ships, 0 = no change), w in 1, 0.75,
           0.5, 0.25, 0.
Ship bar: better held out at both 30 and 60 minutes, and no low warning later and no higher
forecasts where glucose ends under 80.
"""
import bisect, collections, datetime as dt, json, statistics as st, sys

d = sys.argv[1]
R = json.load(open(f"{d}/readings.json"))
R.sort()
T = [r[0] for r in R]
LIVE = [r for r in R if r[2] == 1]
TL = [r[0] for r in LIVE]
FADE, TREND_W, MAX = 30.0, 20, 4.0
LO, HI = 39.0, 401.0  # the engine emits within its 40...400 sensor range, ± 1
GAINS = (0.45, 0.6, 0.7)
H = (15, 30, 60)
WS = (1.0, 0.75, 0.5, 0.25, 0.0)


def perth(t): return dt.datetime.fromtimestamp(t + 8 * 3600, dt.UTC)
def day(t): return perth(t).strftime("%d")


def window(t, minutes, live_only=False):
    i, j = bisect.bisect_left(T, t - minutes * 60), bisect.bisect_right(T, t)
    return [((T[k] - t) / 60, R[k][1], R[k][2]) for k in range(i, j) if not live_only or R[k][2]]


def slope(pts, span=9):
    if len(pts) < 3 or pts[-1][0] - pts[0][0] < span: return None
    mx = st.mean(p[0] for p in pts); my = st.mean(p[1] for p in pts)
    sxx = sum((p[0] - mx) ** 2 for p in pts)
    return max(-MAX, min(MAX, sum((p[0] - mx) * (p[1] - my) for p in pts) / sxx)) if sxx else None


def line(g, trend, gain, minutes=60):
    out, u = {}, 0
    while u < minutes:
        g += max(0, 1 - (u + 0.5) / FADE) * gain * trend
        u += 1
        out[u] = min(HI, max(LO, g))
    return out


def nearest(ts, rows, t, tol):
    i = bisect.bisect_left(ts, t)
    best = min((j for j in (i - 1, i) if 0 <= j < len(ts)), key=lambda j: abs(ts[j] - t), default=None)
    return rows[best] if best is not None and abs(ts[best] - t) <= tol else None


def actual(t, tol=120):
    r = nearest(TL, LIVE, t, tol) or nearest(T, R, t, tol)
    return r[1] if r else None


# Part 1
hist = [r for r in R if r[2] == 0]
pairs = []
for t, v, _ in hist:
    lv = nearest(TL, LIVE, t, 90)
    if lv: pairs.append((v - lv[1], abs(t - lv[0])))
print(f"{len(R)} readings: {len(LIVE)} live, {len(hist)} history, 0 direct (NFC/Bluetooth)")
print(f"history points with a live reading within 90 s: {len(pairs)} of {len(hist)}")
if pairs:
    diffs = [p[0] for p in pairs]
    print(f"   history − live: mean {st.mean(diffs):+.2f}, mean |diff| {st.mean(abs(x) for x in diffs):.2f}, "
          f"exactly equal {sum(x == 0 for x in diffs)}, |diff| > 5: {sum(abs(x) > 5 for x in diffs)}, "
          f"median gap {st.median(p[1] for p in pairs):.0f} s")

# Part 2
HT = [r[0] for r in hist]


def live_before(t, origin, tol=90):
    """The live reading nearest t within tol that the app already had at origin."""
    i, j = bisect.bisect_left(TL, t - tol), bisect.bisect_right(TL, min(t + tol, origin))
    return min(LIVE[i:j], key=lambda r: abs(r[0] - t), default=None)


def fit(t, prefer):
    win = window(t, TREND_W)
    if prefer: win = [p for p in win if p[2] or live_before(t + round(p[0] * 60), t) is None]
    return win, slope(win)


def start(t, prefer):
    i = bisect.bisect_right(T, t) - 1
    if prefer and not R[i][2]:
        lv = live_before(t, t)
        if lv: return lv[1]
    return R[i][1]


def classify(t):
    lw = [p[0] for p in window(t, TREND_W, live_only=True)]
    gaps = [b - a for a, b in zip(lw, lw[1:])] + ([(0 - lw[-1])] if lw else [])
    return "live" if len(lw) >= 4 and max(gaps, default=99) <= 1.5 and lw[0] <= -TREND_W + 1.5 else "filled"


pts = []
for slot in range(T[0] - T[0] % 300 + 300, T[-1] - 3600, 300):
    i = bisect.bisect_right(T, slot) - 1
    if i < 0 or slot - T[i] >= 300: continue
    t = T[i]
    _, tr = fit(t, False)
    if tr is None: continue
    _, trp = fit(t, True)
    act = {h: actual(t + h * 60) for h in H}
    if None in act.values(): continue
    hact = {h: (nearest(HT, hist, t + h * 60, 120) or [None, None])[1] for h in H}
    pts.append(dict(t=t, g=R[i][1], gp=start(t, True), start_live=R[i][2], tr=tr,
                    trp=trp if trp is not None else tr, act=act, hact=hact, kind=classify(t), day=day(t)))
days = sorted({p["day"] for p in pts})
KINDS = ("live", "filled")


def pred(p, h, gain, w=1.0, prefer=False):
    tr, g = (p["trp"], p["gp"]) if prefer else (p["tr"], p["g"])
    if p["kind"] != "live": tr *= w
    return line(g, tr, gain)[h]


def mae(s, h, f, key="act"): return st.mean(abs(p[key][h] - f(p)) for p in s)


print(f"\n{len(pts)} forecast points over {len(days)} Perth days ({days[0]}–{days[-1]} Nov): "
      + ", ".join(f"{k} {sum(p['kind'] == k for p in pts)}" for k in KINDS)
      + f"; start reading from history {sum(not p['start_live'] for p in pts)}; "
      f"trend changed by preferring live {sum(abs(p['trp'] - p['tr']) > 1e-9 for p in pts)} "
      f"(mean |change| {st.mean(abs(p['trp'] - p['tr']) for p in pts):.3f} mg/dL/min)")
print("\n== Miss by window source, no change / ships (bias = actual − ships), mg/dL")
for gain in GAINS:
    print(f"-- gain {gain}")
    for k in KINDS + ("start=history",):
        s = [p for p in pts if p["kind"] == k] if k in KINDS else [p for p in pts if not p["start_live"]]
        if not s: continue
        print(f"   {k:14s} n={len(s):4d}  " + "  ".join(
            f"{h}: {mae(s, h, lambda p: p['g']):5.1f} / {mae(s, h, lambda p: pred(p, h, gain)):5.1f} "
            f"({st.mean(p['act'][h] - pred(p, h, gain) for p in s):+5.1f})" for h in H))
for k in KINDS:
    s = [p for p in pts if p["kind"] == k]
    print(f"   {k:6s} by day: " + " ".join(f"{dd}:{len([p for p in s if p['day'] == dd])}" for dd in days)
          + f"; start under 100: {sum(p['g'] < 100 for p in s)}")

print("\n== Same forecasts scored against a history point vs the live reading at the same moment (gain 0.6)")
for h in H:
    s = [p for p in pts if p["hact"][h] is not None]
    print(f"   {h} min n={len(s)}: vs live {mae(s, h, lambda p: pred(p, h, .6)):5.2f}  "
          f"vs history {mae(s, h, lambda p: pred(p, h, .6), 'hact'):5.2f}")

# Part 3
print("\n== Held out (leave one Perth day out), objective miss at 30 + 60")


def heldout(gain, options):
    """options: list of (label, kwargs); per fold pick the lowest 30+60 miss on the other days."""
    held, picks = {}, []
    for dd in days:
        tr_ = [p for p in pts if p["day"] != dd and day(p["t"] + 3600) != dd]
        lab, kw = min(options, key=lambda o: sum(abs(p["act"][h] - pred(p, h, gain, **o[1])) for p in tr_ for h in (30, 60)))
        picks.append(lab)
        for p in pts:
            if p["day"] == dd:
                for h in H: held[(p["t"], h)] = abs(p["act"][h] - pred(p, h, gain, **kw))
    return held, picks


for name, opts in (("prefer", [("ships", {}), ("prefer", {"prefer": True})]),
                   ("scale", [(f"w={w}", {"w": w}) for w in WS])):
    for gain in GAINS:
        held, picks = heldout(gain, opts)
        row, better = [], {}
        for h in H:
            b = mae(pts, h, lambda p: pred(p, h, gain)); a = st.mean(held[(p["t"], h)] for p in pts)
            row.append(f"{h}: {b:5.2f} -> {a:5.2f} ({(a / b - 1) * 100:+.1f}%)")
            better[h] = sum(st.mean(held[(p["t"], h)] for p in pts if p["day"] == dd) <
                            mae([p for p in pts if p["day"] == dd], h, lambda p: pred(p, h, gain)) - 1e-9 for dd in days)
        print(f"-- {name:6s} gain {gain}: picks {collections.Counter(picks).most_common()}")
        print("   all: " + "  ".join(row) + f"   days better 30/60: {better[30]}/{better[60]} of {len(days)}")
    print("   fixed, all days: " + "; ".join(
        f"{lab} " + "/".join(f"{mae(pts, h, lambda p: pred(p, h, .6, **kw)):5.2f}" for h in H) for lab, kw in opts))

print("\n== Lows: 30-min bias where actual < 80, and low warnings (line under 70 within 30 min)")
lows, below = [], False
for t, v, _ in R:
    if v < 70 and not below and (not lows or t - lows[-1] > 3600): lows.append(t)
    below = v < 70


def warn_at(t, gain, w=1.0, prefer=False):
    _, tr = fit(t, prefer)
    if tr is None: return None
    if classify(t) != "live": tr *= w
    g = start(t, prefer)
    if g < 70: return None
    return min(line(g, tr, gain, 30).values()) < 70


def warning(low, gain, **kw):
    for t in T[bisect.bisect_left(T, low - 90 * 60):bisect.bisect_right(T, low)]:
        if warn_at(t, gain, **kw): return (low - t) / 60
    return 0.0


lo = [p for p in pts if p["act"][30] < 80]
for gain in GAINS:
    base = [warning(l, gain) for l in lows]
    for lab, kw in (("prefer", {"prefer": True}), ("scale w=0.75", {"w": 0.75}), ("scale w=0.5", {"w": 0.5}), ("scale w=0", {"w": 0.0})):
        cand = [warning(l, gain, **kw) for l in lows]
        later = [(perth(l).strftime("%d %H:%M"), round(a, 1), round(b, 1)) for l, a, b in zip(lows, base, cand) if b < a]
        b0 = st.mean(p["act"][30] - pred(p, 30, gain) for p in lo)
        b1 = st.mean(p["act"][30] - pred(p, 30, gain, **kw) for p in lo)
        print(f"   gain {gain} {lab:11s}: {len(lows)} lows, warned later on {len(later)} {later}; "
              f"bias {b0:+.2f} -> {b1:+.2f} (n={len(lo)})")
