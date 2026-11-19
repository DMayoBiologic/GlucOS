#!/usr/bin/env python3
"""Meals with no rapid insulin logged within 30 minutes either side (ForecastAccuracy.md §101).

Does the 30/60-minute forecast run high or low after a meal logged with no rapid dose within 30
minutes before or after it, compared with meals that have one, and how is range coverage there?
And does one forecast-only tweak win held out (leave one day out)?

Usage: python3 -I scripts/unbolused-meals.py DIR
DIR holds (same exports as scripts/large-meals.py, §95):
  readings.json  [[unix, mgdl], ...]  glucos.readings where trend > 0
  logs.json      [[unix, kind, value, food, hypo], ...]  kind "meal" (value = carbs) or "rapid"
                 (value = units), from glucos.logbook (not deleted). hypo: a hypoTreatment context
                 logged within 2 minutes.
  points.json    clean shown 15/30/60-minute accuracy-log points issued from 10 min before to 3 h
                 after a meal: [[unix, minutes, line, lower, upper, actual, start, basis, trend], ...]

Meals: double logs (same carbs within 15 min) count once. Low treatment = 45 g or less with a hypo
tag or a reading under 70 at the meal (fast curve, §37). Groups:
  unbolused  not a low treatment, no rapid dose from 30 min before to 30 min after
  bolused    a rapid dose from 30 min before to 30 min after (those doses belong to the meal)
  treatment  low treatments, with or without a dose (the engine draws them on the fast curve
             whatever is dosed), shown for reference, not tuned
Scoring runs from the meal for 3 h, cut at the next meal or any dose that isn't the meal's own.
Replay = the engine's model forecast (20-min trend clamped +/-4 faded over 30 min at the tuner's
gain, K 2.8 x carbs - S 19.2 x insulin, carb curve 10 min / 3 h, treated lows 30 min x 1.5,
rapid curve 10 min / 75 min / 6 h), every 5 min, scored at 15/30/60 against the reading nearest
the target; targets after a later entry are dropped. Bias = actual - line (negative = line high).

Tweak tried (forecast only; carbs on board, the carb curve shared with Insights, insulin on board,
the insulin curve, carb ratios, sensitivity and the bolus calculator untouched): while an unbolused
meal is in its first 3 h, the forecast's own carb effect from that meal is scaled by c (0.5-1.5)
and the trend term by w (0.5-1.5). Picked on the other days, scored on the held-out day (leave one
day out). Ship bar: better at 30 and 60 on most held-out days at every gain, 15 no worse, bolused
meals unchanged by construction, and 6+ unbolused meals on 4+ days.
"""
import bisect, datetime as dt, json, math, statistics as st, sys
from collections import defaultdict
d=sys.argv[1]
R=json.load(open(f"{d}/readings.json")); L=json.load(open(f"{d}/logs.json")); T=[r[0] for r in R]
K,S,FADE,MAX=2.8,19.2,30.0,4.0
def perth(t): return dt.datetime.fromtimestamp(t+8*3600, dt.UTC)
def lab(t): return perth(t).strftime("%d Nov %H:%M")
def day(t): return perth(t).strftime("%d Nov")
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
    m["own"]=[x for x in doses if abs(x[0]-m["t"])<=1800]
    later=[x[0] for x in doses if x[0]>m["t"] and x not in m["own"]]
    m["end"]=min([m["t"]+3*3600,nm]+later)
    m["grp"]=("treatment" if m["treat"] else "bolused" if m["own"] else "unbolused")
    if not window(m["t"]-600,m["t"]+1800) or m["g0"] is None: m["grp"]="no readings"
    near=[round((x[0]-m["t"])/60) for x in doses if abs(x[0]-m["t"])<=3*3600]
    w=window(m["t"],m["end"]); pk=max(w,key=lambda r:r[1]) if w else None
    print(f"  {lab(m['t'])} {m['g']:5.1f} g {m['food'][:30]:30s} start {m['g0']} doses(min) {near} window {(m['end']-m['t'])/60:4.0f}m "
          f"peak {pk and pk[1]} {m['grp']}")
SCORED=("unbolused","bolused","treatment")
entries=sorted([m["t"] for m in meals]+[x[0] for x in doses])
def forecast(t0,g0,tr,gain,fix=None,h=60):
    known=[m for m in meals if m["t"]<=t0 and t0-m["t"]<4*3600]
    ds=[x for x in doses if x[0]<=t0 and t0-x[0]<6.5*3600]
    act=fix and any(m["grp"]=="unbolused" and t0-m["t"]<3*3600 for m in known)
    g,out=g0,{}
    for u in range(h):
        mid=t0+(u+.5)*60; w=max(0,1-(u+.5)/FADE); rate=0.0
        for m in known:
            if m["treat"]: rate+=1.5*K*m["g"]*carb_rate(mid-m["t"],600,1800); continue
            c=fix["c"] if act and m["grp"]=="unbolused" else 1
            rate+=c*K*m["g"]*carb_rate(mid-m["t"])
        for tx,un in ds: rate-=S*un*ins(mid-tx)
        g+=w*gain*tr*(fix["w"] if act else 1)+(1-w)*rate; out[u+1]=max(39,min(401,g))
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
        if act: pts.append(dict(t0=t0,g0=g0,tr=tr,act=act,m=m,since=(t0-m["t"])/60,day=day(m["t"])))
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
G=[(f"{g}, {a}-{b} min",(lambda g,a,b:lambda p:p["m"]["grp"]==g and a<=p["since"]<b)(g,a,b)) for g in SCORED for a,b in ((0,60),(60,181))]
G+= [(f"{g}, all",(lambda g:lambda p:p["m"]["grp"]==g)(g)) for g in SCORED]
for gain in (0.45,0.6,0.7):
    print(f"\n== gain {gain} (bias = actual - line; negative = line high) ==")
    for n,f in G:
        sub=[p for p in pts if f(p)]
        print(f"  {n:22s} meals={len({id(p['m']) for p in sub})} | "+" | ".join(fmt(stats(sub,gain,h),h) for h in HS))
    if gain==0.45:
        for m in meals:
            if m["grp"] not in SCORED: continue
            sub=[p for p in pts if p["m"] is m]
            print(f"    {lab(m['t'])} {m['g']:5.1f} {m['food'][:18]:18s} {m['grp']:9s} "+" ".join(fmt(stats(sub,gain,h),h) for h in HS))
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
    for k in ((m["grp"],ph,mins),(m["grp"],"all",mins)): g[k].append((a-f,a-s,lo<=a<=hi,basis,hi-lo,a>hi,a<lo,day(m["t"])))
print("\nLive log (bias = actual - line):")
for k in sorted(g):
    v=g[k]; print(f"  {k[0]:9s} {k[1]:6s} {k[2]:2d}m n={len(v):3d} days={len({x[7] for x in v})} mae {st.mean(abs(x[0]) for x in v):5.1f} nc {st.mean(abs(x[1]) for x in v):5.1f} "
                  f"bias {st.mean(x[0] for x in v):+6.1f} inside {100*st.mean(x[2] for x in v):3.0f}% above {100*st.mean(x[5] for x in v):3.0f}% below {100*st.mean(x[6] for x in v):3.0f}% "
                  f"width {st.mean(x[4] for x in v):5.1f} model {sum(x[3]=='trendInsulinCarbs' for x in v)}")
# Held out by day
U=[p for p in pts if p["m"]["grp"]=="unbolused"]
days=sorted({p["day"] for p in U})
GRID=[dict(c=c,w=w) for c in (.5,.75,1,1.25,1.5) for w in (.5,.75,1,1.25,1.5)]
def sc(sub,gain,fix,hs=(30,60)): return sum((stats(sub,gain,h,fix) or (0,0))[1] for h in hs)
for gain in (0.45,0.6,0.7):
    print(f"\n== held out by day (unbolused meals), gain {gain} ==")
    win={h:0 for h in HS}; n={h:0 for h in HS}
    for dd in days:
        tr=[p for p in U if p["day"]!=dd]; te=[p for p in U if p["day"]==dd]
        best=min(GRID,key=lambda f:sc(tr,gain,f))
        row=[]
        for h in HS:
            a,b=stats(te,gain,h),stats(te,gain,h,best)
            if not a: continue
            n[h]+=1; win[h]+=b[1]<a[1]-0.05
            row.append(f"{h}m {a[1]:.1f}->{b[1]:.1f} (bias {a[2]:+.1f}->{b[2]:+.1f})")
        print(f"  {dd} {best} "+" ".join(row))
    print("  held-out days better: "+" ".join(f"{h}m {win[h]}/{n[h]}" for h in HS))
    allb=min(GRID,key=lambda f:sc(U,gain,f)); print("  in-sample best",allb," ".join(fmt(stats(U,gain,h,allb),h) for h in HS))
