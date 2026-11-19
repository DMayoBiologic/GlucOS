#!/usr/bin/env python3
"""Meals whose rapid insulin is logged 15+ minutes after eating (ForecastAccuracy.md §94).

After a late dose lands, does the line run high or low at 30/60 minutes compared with meals dosed
at or before eating? And does one timing-aware, forecast-only tweak win held out?

Usage: python3 -I scripts/late-meal-doses.py DIR
DIR holds:
  readings.json  [[unix, mgdl], ...]  glucos.readings where trend > 0
  logs.json      [[unix, kind, value, food, hypo], ...]  kind "meal" (value = carbs) or "rapid"
                 (value = units), from glucos.logbook (not deleted). hypo: a hypoTreatment context
                 logged within 2 minutes.
  points.json    clean shown 15/30/60-minute accuracy-log points issued within 4 h of a meal or dose:
                 [[unix, minutes, line, lower, upper, actual, start, basis, trend], ...]

Meals: double logs (same carbs within 15 min) count once; 45 g or less with a hypo tag or under 70
is a low treatment (fast curve) and never scored. A meal's own dose = the first rapid dose from 30
min before to 90 min after it (before the next meal). Dose lag = dose - meal. "Dosed late" = 15 min
or more, "dosed with/before" = 5 min or less. Scoring starts at the dose (the meal for doses
before it) and runs 3 h or to the next entry. Replay = the engine's model forecast (20-min trend
clamped +/-4 faded over 30 min at the tuner's gain, K 2.8 x carbs - S 19.2 x insulin, carb curve
10 min / 3 h, rapid curve 10 min / 75 min / 6 h), every 5 min, scored at 15/30/60 against the
reading nearest the target; targets after a later entry are dropped.

Tweak tried (forecast only; insulin on board, the insulin curve, carbs on board, carb ratios,
sensitivity and the bolus calculator untouched): for `span` minutes after a late dose, the trend
is scaled by g with fade `fade`, and the late meal's carb clock is advanced `adv` minutes (its rise
has already partly shown up by the time of the dose). Picked on one late meal and scored on the
other (leave one meal out). Ship bar: better at 30 and 60 on every held-out meal at every gain,
15 no worse, and 5+ late-dosed meals on 3+ days.
"""
import bisect, datetime as dt, itertools, json, math, statistics as st, sys
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
    g0=at(t,600); meals.append(dict(t=t,g=v,food=food,hypo=hypo,treat=v<=45 and (hypo or (g0 is not None and g0<70))))
entries=sorted([m["t"] for m in meals]+[x[0] for x in doses])
for m in meals:
    own=[x for x in doses if -1800<=x[0]-m["t"]<=5400]
    # own doses: before the next meal
    nm=[n["t"] for n in meals if n["t"]>m["t"]+1]
    if nm: own=[x for x in own if x[0]<nm[0]]
    m["own"]=own
    m["lag"]=None if not own else own[0][0]-m["t"]
    anchor=m["t"] if not own else max(m["t"],own[0][0])
    m["anchor"]=anchor
    nxt=[e for e in entries if e>anchor+1 and e>m["t"]+1 and not any(abs(e-o[0])<1 for o in own)]
    m["end"]=min([anchor+3*3600]+nxt)
    m["grp"]=("treatment" if m["treat"] else "no dose" if m["lag"] is None else
              "no readings" if not window(m["t"]-600,anchor+1800) else
              "dosed late" if m["lag"]>=900 else "dosed with/before" if m["lag"]<=300 else "5-15 min")
print("Meals:")
for m in meals:
    lag="  -  " if m["lag"] is None else f"{m['lag']/60:+4.0f}m"
    print(f"  {lab(m['t'])} {m['g']:5.1f} g {m['food'][:30]:30s} start {at(m['t'],600)} dose {lag} at-dose {at(m['anchor'],600)} "
          f"window {(m['end']-m['anchor'])/60:4.0f}m own {[u for _,u in m['own']]} {m['grp']}")
SCORED=("dosed late","dosed with/before")
def forecast(t0,g0,tr,gain,fix=None,h=60):
    known=[m for m in meals if m["t"]<=t0 and t0-m["t"]<4*3600]
    ds=[x for x in doses if x[0]<=t0 and t0-x[0]<6.5*3600]
    fade,gn=FADE,gain
    if fix:
        late=[m for m in known if m["grp"]=="dosed late" and m["own"][0][0]<=t0 and t0-m["own"][0][0]<fix["span"]*60]
        if late: fade,gn=fix["fade"],gain*fix["g"]
    g,out=g0,{}
    for u in range(h):
        mid=t0+(u+.5)*60; w=max(0,1-(u+.5)/fade); rate=0.0
        for m in known:
            adv=fix["adv"]*60 if (fix and m["grp"]=="dosed late" and m["own"][0][0]<=t0 and t0-m["own"][0][0]<fix["span"]*60) else 0
            rate+=(1.5*K*m["g"]*carb_rate(mid-m["t"],600,1800)) if m["treat"] else K*m["g"]*carb_rate(mid-m["t"]+adv)
        for tx,un in ds: rate-=S*un*ins(mid-tx)
        g+=w*gn*tr+(1-w)*rate; out[u+1]=max(39,min(401,g))
    return out
HS=(15,30,60)
pts=[]
for m in meals:
    if m["grp"] not in SCORED: continue
    for k in range(0,181,5):
        ti=m["anchor"]+k*60
        if ti>=m["end"]: break
        i=bisect.bisect_right(T,ti)-1
        if i<0 or ti-T[i]>=300 or T[i]<m["anchor"]: continue
        t0,g0=R[i]; tr=slope(t0)
        if tr is None: continue
        act={}
        for h in HS:
            if any(t0<e<=t0+h*60 for e in entries): continue
            a=at(t0+h*60)
            if a is not None: act[h]=a
        if act: pts.append(dict(t0=t0,g0=g0,tr=tr,act=act,m=m,since=(t0-m["anchor"])/60,day=perth(m["t"]).date().isoformat()))
days=sorted({p["day"] for p in pts})
print(f"\nReplay: {len(pts)} forecasts from the dose, {len({id(p['m']) for p in pts})} meals, days {days}")
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
G=[("late, 0-60 after dose",lambda p:p["m"]["grp"]=="dosed late" and p["since"]<60),
   ("late, 60-180",lambda p:p["m"]["grp"]=="dosed late" and p["since"]>=60),
   ("on time, 0-60",lambda p:p["m"]["grp"]!="dosed late" and p["since"]<60),
   ("on time, 60-180",lambda p:p["m"]["grp"]!="dosed late" and p["since"]>=60)]
for gain in (0.45,0.6,0.7):
    print(f"\n== gain {gain} (bias = actual - line; negative = line high) ==")
    for n,f in G:
        sub=[p for p in pts if f(p)]
        print(f"  {n:22s} meals={len({id(p['m']) for p in sub})} | "+" | ".join(
            (lambda s:f"{h}m n={s[0]:3d} mae {s[1]:5.1f} nc {s[3]:5.1f} bias {s[2]:+6.1f}" if s else f"{h}m -")(stats(sub,gain,h)) for h in HS))
    for m in meals:
        if m["grp"]!="dosed late": continue
        sub=[p for p in pts if p["m"] is m]
        print(f"  {lab(m['t'])} {m['food'][:20]:20s} "+" ".join(
            (lambda s:f"{h}m n={s[0]} mae {s[1]:.1f} bias {s[2]:+.1f}" if s else "")(stats(sub,gain,h)) for h in HS))
# live log
P=json.load(open(f"{d}/points.json"))
seen=set(); g=defaultdict(list)
for t,mins,f,lo,hi,a,s,basis,tr in P:
    if (t,mins,basis) in seen: continue
    seen.add((t,mins,basis))
    c=[m for m in meals if m["grp"] in SCORED and m["anchor"]<=t<m["end"]]
    if not c: continue
    m=c[-1]
    if any(t<e<=t+mins*60 for e in entries): continue
    ph="0-60" if t-m["anchor"]<3600 else "60-180"
    g[("late" if m["grp"]=="dosed late" else "on time",ph,mins)].append((a-f,a-s,lo<=a<=hi,basis))
print("\nLive log from the dose (bias = actual - line):")
for k in sorted(g):
    v=g[k]; print(f"  {k[0]:8s} {k[1]:6s} {k[2]:2d}m n={len(v):3d} mae {st.mean(abs(x[0]) for x in v):5.1f} nc {st.mean(abs(x[1]) for x in v):5.1f} "
                  f"bias {st.mean(x[0] for x in v):+6.1f} inside {100*st.mean(x[2] for x in v):3.0f}% model {sum(x[3]=='trendInsulinCarbs' for x in v)}")

GRID=[dict(g=gg,fade=fd,adv=a,span=sp) for gg in (1,.5,0) for fd in (30,15) for a in (0,15,30,45,60) for sp in (60,120,180)]
lm=[m for m in meals if m["grp"]=="dosed late"]
def sc(sub,gain,fix,hs=(30,60)): return sum((stats(sub,gain,h,fix) or (0,0))[1] for h in hs)
for gain in (0.45,0.6,0.7):
    print(f"\n== held out by late meal, gain {gain} ==")
    for test in lm:
        tr=[p for p in pts if p["m"] is not test and p["m"]["grp"]=="dosed late"]; te=[p for p in pts if p["m"] is test]
        best=min(GRID,key=lambda f:sc(tr,gain,f))
        print(" ",lab(test["t"]),best," ".join(f"{h}m {stats(te,gain,h)[1]:.1f}->{stats(te,gain,h,best)[1]:.1f} (bias {stats(te,gain,h)[2]:+.1f}->{stats(te,gain,h,best)[2]:+.1f})" for h in HS))
    allp=[p for p in pts if p["m"]["grp"]=="dosed late"]
    best=min(GRID,key=lambda f:sc(allp,gain,f))
    print("  in-sample best both:",best," ".join(f"{h}m {stats(allp,gain,h)[1]:.1f}->{stats(allp,gain,h,best)[1]:.1f}" for h in HS))
    for f in (dict(g=0,fade=15,adv=0,span=60),dict(g=1,fade=30,adv=30,span=120),dict(g=.5,fade=30,adv=0,span=120)):
        print("  fixed",f," ".join(f"{lab(m['t'])[:6]} {h}m {stats([p for p in pts if p['m'] is m],gain,h)[1]:.1f}->{stats([p for p in pts if p['m'] is m],gain,h,f)[1]:.1f}" for m in lm for h in (30,60)))
print()
for m in lm:
    for lo,hi in ((0,60),(60,181)):
        sub=[p for p in pts if p["m"] is m and lo<=p["since"]<hi]
        print(lab(m["t"]),lo,hi," ".join((lambda s:f"{h}m n={s[0]} mae {s[1]:.1f} bias {s[2]:+.1f} nc {s[3]:.1f}" if s else f"{h}m -")(stats(sub,0.45,h)) for h in HS))
