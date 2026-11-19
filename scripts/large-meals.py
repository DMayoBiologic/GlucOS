#!/usr/bin/env python3
"""Large meals (60 g carbs or more) vs mid-size meals (20-59 g) (ForecastAccuracy.md §95).

Does the line under- or over-call the peak's height and timing at 30/60 minutes after a large
meal, compared with mid-size meals, and is the range wide enough there? And does one size-aware,
forecast-only tweak to the carb curve win held out?

Usage: python3 -I scripts/large-meals.py DIR
DIR holds:
  readings.json  [[unix, mgdl], ...]  glucos.readings where trend > 0
  logs.json      [[unix, kind, value, food, hypo], ...]  kind "meal" (value = carbs) or "rapid"
                 (value = units), from glucos.logbook (not deleted). hypo: a hypoTreatment context
                 logged within 2 minutes.
  points.json    clean shown 15/30/60-minute accuracy-log points:
                 [[unix, minutes, line, lower, upper, actual, start, basis, trend], ...]

Meals: double logs (same carbs within 15 min) count once; 45 g or less with a hypo tag or under 70
is a low treatment (fast curve) and never scored. Size: large >= 60 g, mid 20-59 g. Scoring runs
from the meal for 3 h or to the next meal (doses within 90 min of the meal belong to it and don't
cut the window; later doses do). Peak = highest reading in that window; rise = peak - reading at
the meal. Replay = the engine's model forecast (20-min trend clamped +/-4 faded over 30 min at the
tuner's gain, K 2.8 x carbs - S 19.2 x insulin, carb curve 10 min / 3 h, rapid curve 10 min / 75 min
/ 6 h), every 5 min, scored at 15/30/60 against the reading nearest the target; targets after a
later entry are dropped.

Tweak tried (forecast only; carbs on board, the shared carb curve, insulin on board, the insulin
curve, carb ratios, sensitivity and the bolus calculator untouched): for meals of 60 g or more the
forecast's own copy of the carb curve is stretched, absorb = 3 h x (1 + a x (g - 60) / 60), and its
height scaled by c (c < 1 spreads a big meal over a longer, lower curve). a 0-1, c 0.6-1.2. Picked
on the other large meals, scored on the held-out one (leave one meal out). Ship bar: better at 30
and 60 on every held-out meal at every gain, 15 no worse, mid-size meals unchanged by
construction, and 5+ large meals on 3+ days.
"""
import bisect, datetime as dt, json, math, statistics as st, sys
from collections import defaultdict
d=sys.argv[1]
R=json.load(open(f"{d}/readings.json")); L=json.load(open(f"{d}/logs.json")); T=[r[0] for r in R]
K,S,FADE,MAX=2.8,19.2,30.0,4.0
def perth(t): return dt.datetime.fromtimestamp(t+8*3600, dt.UTC)
def lab(t): return perth(t).strftime("%d Nov %H:%M")
def at(t,tol=120):
    i=bisect.bisect_left(T,t); c=[j for j in (i-1,i) if 0<=j<len(T)]
    if not c: return None
    j=min(c,key=lambda j:abs(T[j]-t)); return R[j][1] if abs(T[j]-t)<=tol else None
def window(a,b): return R[bisect.bisect_left(T,a):bisect.bisect_right(T,b)]
def slope(t):
    pts=[((x-t)/60,g) for x,g in window(t-1200,t)]
    if len(pts)<3 or pts[-1][0]-pts[0][0]<9: return None
    mx=st.mean(p[0] for p in pts); my=st.mean(p[1] for p in pts); sxx=sum((p[0]-mx)**2 for p in pts)
    return max(-MAX,min(MAX,sum((p[0]-mx)*(p[1]-my) for p in pts)/sxx)) if sxx else None
def carb_rate(e,delay=600,absorb=10800):
    x=(e-delay)/absorb; rise,fall=0.15,0.5; sc=2/(1+fall-rise)
    u=0 if x<=0 or x>=1 else sc*x/rise if x<rise else sc if x<fall else sc*(1-x)/(1-fall)
    return u/(absorb/60)
def ins(e):
    delay,peak,dur=600.0,75*60.0,6*3600.0; tau=peak*(1-peak/dur)/(1-2*peak/dur); a=2*tau/dur
    s=1/(1-a+(1+a)*math.exp(-dur/tau)); t=e-delay
    if t<=0 or t>=dur: return 0
    return max(0,(s/tau**2)*t*(1-t/dur)*math.exp(-t/tau))*60
meals,doses=[],[]
for t,k,v,food,hypo in sorted(L,key=lambda x:(x[0],x[1])):
    if k=="rapid": doses.append((t,v)); continue
    if meals and t-meals[-1]["t"]<900 and abs(v-meals[-1]["g"])<1: continue
    g0=at(t,600); meals.append(dict(t=t,g=v,food=food,hypo=hypo,g0=g0,treat=v<=45 and (hypo or (g0 is not None and g0<70))))
for i,m in enumerate(meals):
    nm=meals[i+1]["t"] if i+1<len(meals) else 1e12
    own=[x for x in doses if -1800<=x[0]-m["t"]<=5400 and x[0]<nm]
    later=[x[0] for x in doses if x[0]>m["t"]+5400]
    m["own"]=own; m["end"]=min([m["t"]+3*3600,nm]+later)
    m["size"]="large" if m["g"]>=60 else "mid" if m["g"]>=20 else "small"
    m["grp"]=("treatment" if m["treat"] else "no readings" if not window(m["t"]-600,m["t"]+1800) else m["size"])
    w=window(m["t"],m["end"])
    if w and m["g0"] is not None:
        pk=max(w,key=lambda r:r[1]); m["peak"]=pk[1]; m["rise"]=pk[1]-m["g0"]; m["peak_min"]=(pk[0]-m["t"])/60
    else: m["peak"]=m["rise"]=m["peak_min"]=None
    m["prior"]=[n for n in meals[:i] if m["t"]-n["t"]<3600]
print("Meals:")
for m in meals:
    print(f"  {lab(m['t'])} {m['g']:5.1f} g {m['food'][:28]:28s} start {m['g0']} doses {[(round((x[0]-m['t'])/60),u) for x,u in [(x,x[1]) for x in m['own']]]} "
          f"window {(m['end']-m['t'])/60:4.0f}m peak {m['peak']} rise {m['rise']} at {m['peak_min'] and round(m['peak_min'])}m "
          f"{'after '+','.join(lab(n['t'])[7:] for n in m['prior']) if m['prior'] else ''} {m['grp']}")
SCORED=("large","mid")
entries=sorted([m["t"] for m in meals]+[x[0] for x in doses])
def forecast(t0,g0,tr,gain,fix=None,h=60):
    known=[m for m in meals if m["t"]<=t0 and t0-m["t"]<4*3600*(1+(fix["a"] if fix else 0))]
    ds=[x for x in doses if x[0]<=t0 and t0-x[0]<6.5*3600]
    g,out=g0,{}
    for u in range(h):
        mid=t0+(u+.5)*60; w=max(0,1-(u+.5)/FADE); rate=0.0
        for m in known:
            if m["treat"]: rate+=1.5*K*m["g"]*carb_rate(mid-m["t"],600,1800); continue
            if fix and m["g"]>=60:
                ab=10800*(1+fix["a"]*(m["g"]-60)/60); rate+=fix["c"]*K*m["g"]*carb_rate(mid-m["t"],600,ab)
            else: rate+=K*m["g"]*carb_rate(mid-m["t"])
        for tx,un in ds: rate-=S*un*ins(mid-tx)
        g+=w*gain*tr+(1-w)*rate; out[u+1]=max(39,min(401,g))
    return out
HS=(15,30,60)
pts=[]
for m in meals:
    if m["grp"] not in SCORED: continue
    for k in range(0,181,5):
        ti=m["t"]+k*60
        if ti>=m["end"]: break
        i=bisect.bisect_right(T,ti)-1
        if i<0 or ti-T[i]>=300 or T[i]<m["t"]: continue
        t0,g0=R[i]; tr=slope(t0)
        if tr is None: continue
        act={}
        for h in HS:
            if t0+h*60>m["end"] or any(t0<e<=t0+h*60 and not any(abs(e-o[0])<1 for o in m["own"]) for e in entries): continue
            a=at(t0+h*60)
            if a is not None: act[h]=a
        if act: pts.append(dict(t0=t0,g0=g0,tr=tr,act=act,m=m,since=(t0-m["t"])/60))
print(f"\nReplay: {len(pts)} forecasts, {len({id(p['m']) for p in pts})} meals")
cache={}
def line(p,gain,fix=None):
    key=(id(p),gain,json.dumps(fix,sort_keys=True))
    if key not in cache: cache[key]=forecast(p["t0"],p["g0"],p["tr"],gain,fix)
    return cache[key]
def stats(sub,gain,h,fix=None):
    e=[p["act"][h]-line(p,gain,fix)[h] for p in sub if h in p["act"]]
    nc=[abs(p["act"][h]-p["g0"]) for p in sub if h in p["act"]]
    if not e: return None
    return len(e),st.mean(abs(x) for x in e),st.mean(e),st.mean(nc)
def fmt(s,h): return f"{h}m n={s[0]:3d} mae {s[1]:5.1f} nc {s[3]:5.1f} bias {s[2]:+6.1f}" if s else f"{h}m -"
G=[(f"{sz}, {a}-{b} min",(lambda sz,a,b:lambda p:p["m"]["grp"]==sz and a<=p["since"]<b)(sz,a,b)) for sz in SCORED for a,b in ((0,60),(60,120),(120,181))]
for gain in (0.45,0.6,0.7):
    print(f"\n== gain {gain} (bias = actual - line; negative = line high) ==")
    for n,f in G:
        sub=[p for p in pts if f(p)]
        print(f"  {n:20s} meals={len({id(p['m']) for p in sub})} | "+" | ".join(fmt(stats(sub,gain,h),h) for h in HS))
    for m in meals:
        if m["grp"] not in SCORED: continue
        sub=[p for p in pts if p["m"] is m and p["since"]<120]
        print(f"  {lab(m['t'])} {m['g']:5.1f} {m['food'][:18]:18s} first 2 h "+" ".join(fmt(stats(sub,gain,h),h) for h in HS))
# Peak call: for forecasts issued in the first 60 min, the line's own highest point vs the real peak.
print("\nPeak call (gain 0.45), forecasts issued 0-60 min after the meal whose 60-min target is at or after the real peak:")
for m in meals:
    if m["grp"] not in SCORED or m["peak"] is None: continue
    sub=[p for p in pts if p["m"] is m and p["since"]<60]
    if not sub: continue
    hi=[max(line(p,0.45).values()) for p in sub]
    tm=[max(line(p,0.45),key=lambda u:line(p,0.45)[u])+p["since"] for p in sub]
    reach=[p for p in sub if p["since"]+60>=m["peak_min"]]
    hr=[max(line(p,0.45).values())-m["peak"] for p in reach]
    print(f"  {lab(m['t'])} {m['g']:5.1f} g {m['size']:5s} real peak {m['peak']:.0f} (+{m['rise']:.0f}) at {m['peak_min']:.0f} min | line's highest {st.mean(hi):.0f} "
          f"at ~{st.mean(tm):.0f} min | reaching forecasts n={len(reach)} line peak - real {st.mean(hr) if hr else float('nan'):+.0f}")
# Live log
P=json.load(open(f"{d}/points.json"))
seen=set(); g=defaultdict(list)
for t,mins,f,lo,hi,a,s,basis,tr in P:
    if (t,mins,basis) in seen: continue
    seen.add((t,mins,basis))
    c=[m for m in meals if m["grp"] in SCORED and m["t"]<=t<m["end"]]
    if not c: continue
    m=c[-1]
    if t+mins*60>m["end"]: continue
    ph="0-60" if t-m["t"]<3600 else "60-180"
    g[(m["size"],ph,mins)].append((a-f,a-s,lo<=a<=hi,basis,hi-lo,a>hi))
print("\nLive log (bias = actual - line):")
for k in sorted(g):
    v=g[k]; print(f"  {k[0]:5s} {k[1]:6s} {k[2]:2d}m n={len(v):3d} mae {st.mean(abs(x[0]) for x in v):5.1f} nc {st.mean(abs(x[1]) for x in v):5.1f} "
                  f"bias {st.mean(x[0] for x in v):+6.1f} inside {100*st.mean(x[2] for x in v):3.0f}% above {100*st.mean(x[5] for x in v):3.0f}% width {st.mean(x[4] for x in v):5.1f} model {sum(x[3]=='trendInsulinCarbs' for x in v)}")
lm=[m for m in meals if m["grp"]=="large" and any(p["m"] is m for p in pts)]
GRID=[dict(a=a,c=c) for a in (0,.25,.5,.75,1) for c in (.6,.7,.8,.9,1,1.1,1.2)]
def sc(sub,gain,fix,hs=(30,60)): return sum((stats(sub,gain,h,fix) or (0,0))[1] for h in hs)
for gain in (0.45,0.6,0.7):
    print(f"\n== held out by large meal, gain {gain} ==")
    for test in lm:
        tr=[p for p in pts if p["m"] is not test and p["m"]["grp"]=="large"]; te=[p for p in pts if p["m"] is test]
        best=min(GRID,key=lambda f:sc(tr,gain,f)) if tr else None
        print(" ",lab(test["t"]),best," ".join(f"{h}m {stats(te,gain,h)[1]:.1f}->{stats(te,gain,h,best)[1]:.1f} (bias {stats(te,gain,h)[2]:+.1f}->{stats(te,gain,h,best)[2]:+.1f})" for h in HS if stats(te,gain,h)))
    for test in lm:
        te=[p for p in pts if p["m"] is test]; best=min(GRID,key=lambda f:sc(te,gain,f))
        print("  in-sample best for",lab(test["t"]),best)
