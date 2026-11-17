#!/usr/bin/env python3
"""ForecastAccuracy §58: forecast error during flat-lined readings.

Input: points.json, a list of clean drawn points (export query in §58) with
streak (identical live readings in a row ending at the issue time), span10
(max - min of live readings in the 10 min before issue) and n10 (their count).

    python3 scripts/flat-runs.py points.json
"""
import json, sys, statistics as stt
from collections import defaultdict

rows = json.load(open(sys.argv[1]))
for r in rows:
    r["day"] = (r["t"] + 8 * 3600) // 86400  # Perth date
H = (15, 30, 45, 60)

def iscore(r, lo, hi):  # 80% interval score
    a = r["a"]
    return (hi - lo) + 10 * max(0, lo - a) + 10 * max(0, a - hi)

def stats(pts):
    if not pts: return None
    return dict(n=len(pts), days=len({p["day"] for p in pts}),
                mae=stt.mean(abs(p["a"] - p["fc"]) for p in pts),
                nc=stt.mean(abs(p["a"] - p["st"]) for p in pts),
                cov=stt.mean(p["lo"] <= p["a"] <= p["hi"] for p in pts),
                isc=stt.mean(iscore(p, p["lo"], p["hi"]) for p in pts))

DEFS = {
    "streak>=3": lambda r: (r["streak"] or 0) >= 3,
    "streak>=5": lambda r: (r["streak"] or 0) >= 5,
    "flat10 (span<=1, 6+ live)": lambda r: r["n10"] >= 6 and r["span10"] is not None and r["span10"] <= 1,
    "flat10 (span<=2, 6+ live)": lambda r: r["n10"] >= 6 and r["span10"] is not None and r["span10"] <= 2,
}

print("== Error split (drawn / no change / coverage / interval score)")
for name, f in DEFS.items():
    for h in H:
        hp = [r for r in rows if r["m"] == h]
        a, b = stats([r for r in hp if f(r)]), stats([r for r in hp if not f(r)])
        fmt = lambda s: "-" if not s else f"{s['n']:4d} pts {s['days']}d  {s['mae']:5.1f} / {s['nc']:5.1f} / {s['cov']*100:3.0f}% / {s['isc']:6.1f}"
        print(f"{name:28s} {h:2d}  flat: {fmt(a)}   rest: {fmt(b)}")

WS = [1.0, 0.9, 0.75, 0.5, 0.25, 0.0]
KS = [1.0, 1.1, 1.25, 1.5, 1.75, 2.0]

def held_out(pts, choices, err):
    """Leave one Perth day out: pick the choice best on the other days."""
    days = sorted({p["day"] for p in pts}); out = []; picks = []
    for d in days:
        train = [p for p in pts if p["day"] != d]
        if not train: continue
        best = min(choices, key=lambda c: (sum(err(p, c) for p in train) / len(train), -c if choices is WS else c))
        picks.append(best)
        out += [err(p, best) for p in pts if p["day"] == d]
    return (stt.mean(out) if out else None), picks

print("\n== Held-out tests on flat points (leave one day out)")
for name, f in DEFS.items():
    for h in H:
        pts = [r for r in rows if r["m"] == h and f(r)]
        if len({p["day"] for p in pts}) < 3:
            print(f"{name:28s} {h:2d}  {len(pts)} pts, under 3 days, skipped"); continue
        mae = stt.mean(abs(p["a"] - p["fc"]) for p in pts)
        w_err = lambda p, w: abs(p["a"] - (p["st"] + w * (p["fc"] - p["st"])))
        wo, wp = held_out(pts, WS, w_err)
        def k_err(p, k):
            c = p["fc"]; return iscore(p, c - k * (c - p["lo"]), c + k * (p["hi"] - c))
        isc = stt.mean(iscore(p, p["lo"], p["hi"]) for p in pts)
        ko, kp = held_out(pts, KS, k_err)
        print(f"{name:28s} {h:2d}  n={len(pts):3d}  line: drawn {mae:5.1f} -> {wo:5.1f} ({(wo/mae-1)*100:+5.1f}%) w={wp}"
              f"   range: score {isc:6.1f} -> {ko:6.1f} ({(ko/isc-1)*100:+5.1f}%) k={kp}")
