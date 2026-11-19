#!/usr/bin/env python3
"""Forecast error after small vs larger rapid doses, with and without a meal (ForecastAccuracy.md §102).

Usage: python3 -I scripts/dose-size.py DIR
DIR holds the same exports as scripts/unbolused-meals.py (§101): readings.json, logs.json and
points.json (clean shown 15/30/60-minute accuracy-log points issued from 10 min before to 3 h after
a rapid dose).

Doses: small = SMALL units or less (4; the asked-for 2 u cut has one dose), large = more. Meal = a
meal logged within 30 min either side (it belongs to the dose). Each dose is scored from when it's
logged for 3 h, cut at any later entry that isn't its own meal. Replay = the engine's model forecast
(same as §101), every 5 min, scored at 15/30/60. Bias = actual - line (negative = line high).

Tweak tried (forecast only; insulin on board, the insulin curve, sensitivity, carb ratios and the
bolus calculator untouched): the trend term scaled by w (0.5-1.5) per size x meal group for 3 h after
a dose, picked on the other days and scored on the held-out day (leave one day out).
"""
import bisect, datetime as dt, json, math, statistics as st, sys
from collections import defaultdict
d=sys.argv[1]
R=json.load(open(f"{d}/readings.json")); L=json.load(open(f"{d}/logs.json")); T=[r[0] for r in R]
K,S,FADE,MAX=2.8,19.2,30.0,4.0
SMALL=float(sys.argv[2]) if len(sys.argv)>2 else 4.0
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
    g0=at(t,600); meals.append(dict(t=t,g=v,food=food,treat=v<=45 and (hypo or (g0 is not None and g0<70))))
entries=sorted([m["t"] for m in meals]+[x[0] for x in doses])
D=[]
for i,(t,u) in enumerate(doses):
    own=[m for m in meals if abs(m["t"]-t)<=1800]
    ownt=[m["t"] for m in own]+[t]
    later=[e for e in entries if e>t and not any(abs(e-o)<1 for o in ownt)]
    end=min([t+3*3600]+later)
    g0=at(t,600)
    size="small" if u<=SMALL else "large"
    grp=f"{size}, {'meal' if own else 'no meal'}"
    if g0 is None or not window(t-600,t+1800): grp="no readings"
    D.append(dict(t=t,u=u,own=ownt,end=end,g0=g0,grp=grp,day=day(t),meal=own and own[0]["food"][:20]))
    print(f"  {lab(t)} {u:4.1f} u start {g0} meal {D[-1]['meal'] or '-':20s} window {(end-t)/60:4.0f}m {grp}")
GROUPS=sorted({x["grp"] for x in D if x["grp"]!="no readings"})
def forecast(t0,g0,tr,gain,fix=None,h=60,dz=None):
    known=[m for m in meals if m["t"]<=t0 and t0-m["t"]<4*3600]
    ds=[x for x in doses if x[0]<=t0 and t0-x[0]<6.5*3600]
    w_=fix.get(dz["grp"],1) if fix and dz else 1
    g,out=g0,{}
    for u in range(h):
        mid=t0+(u+.5)*60; w=max(0,1-(u+.5)/FADE); rate=0.0
        for m in known:
            if m["treat"]: rate+=1.5*K*m["g"]*carb_rate(mid-m["t"],600,1800); continue
            rate+=K*m["g"]*carb_rate(mid-m["t"])
        for tx,un in ds: rate-=S*un*ins(mid-tx)
        g+=w*gain*tr*w_+(1-w)*rate; out[u+1]=max(39,min(401,g))
    return out
HS=(15,30,60)
pts=[]
for dz in D:
    if dz["grp"]=="no readings": continue
    for k in range(0,181,5):
        ti=dz["t"]+k*60
        if ti>=dz["end"]: break
        i=bisect.bisect_right(T,ti)-1
        if i<0 or ti-T[i]>=300 or T[i]<dz["t"]: continue
        t0,g0=R[i]; tr=slope(t0)
        if tr is None: continue
        act={}
        for h in HS:
            if t0+h*60>dz["end"]: continue
            a=at(t0+h*60)
            if a is not None: act[h]=a
        if act: pts.append(dict(t0=t0,g0=g0,tr=tr,act=act,dz=dz,since=(t0-dz["t"])/60,day=dz["day"]))
print(f"\nReplay: {len(pts)} forecasts, {len({id(p['dz']) for p in pts})} doses")
cache={}
def line(p,gain,fix=None):
    key=(id(p),gain,json.dumps(fix,sort_keys=True))
    if key not in cache: cache[key]=forecast(p["t0"],p["g0"],p["tr"],gain,fix,dz=p["dz"])
    return cache[key]
def stats(sub,gain,h,fix=None):
    e=[p["act"][h]-line(p,gain,fix)[h] for p in sub if h in p["act"]]
    nc=[abs(p["act"][h]-p["g0"]) for p in sub if h in p["act"]]
    if not e: return None
    return len(e),st.mean(abs(x) for x in e),st.mean(e),st.mean(nc)
def fmt(s,h): return f"{h}m n={s[0]:3d} mae {s[1]:5.1f} nc {s[3]:5.1f} bias {s[2]:+6.1f}" if s else f"{h}m -"
G=[(f"{g}, {a}-{b} min",(lambda g,a,b:lambda p:p["dz"]["grp"]==g and a<=p["since"]<b)(g,a,b)) for g in GROUPS for a,b in ((0,60),(60,181))]
G+=[(f"{g}, all",(lambda g:lambda p:p["dz"]["grp"]==g)(g)) for g in GROUPS]
G+=[("<=2 u, all",lambda p:p["dz"]["u"]<=2)]
for gain in (0.45,0.6,0.7):
    print(f"\n== gain {gain} (bias = actual - line; negative = line high) ==")
    for n,f in G:
        sub=[p for p in pts if f(p)]
        print(f"  {n:26s} doses={len({id(p['dz']) for p in sub})} days={len({p['day'] for p in sub})} | "+" | ".join(fmt(stats(sub,gain,h),h) for h in HS))
    if gain==0.45:
        for dz in D:
            sub=[p for p in pts if p["dz"] is dz]
            if sub: print(f"    {lab(dz['t'])} {dz['u']:4.1f} u {dz['grp']:16s} "+" ".join(fmt(stats(sub,gain,h),h) for h in HS))
P=json.load(open(f"{d}/points.json"))
seen=set(); g=defaultdict(list)
for t,mins,f,lo,hi,a,s,basis,_ in P:
    if (t,mins,basis) in seen: continue
    seen.add((t,mins,basis))
    c=[x for x in D if x["grp"]!="no readings" and x["t"]-60<=t<x["end"]]
    if not c: continue
    dz=c[-1]
    if t+mins*60>dz["end"]: continue
    ph="0-60" if t-dz["t"]<3600 else "60-180"
    for k in ((dz["grp"],ph,mins),(dz["grp"],"all",mins)): g[k].append((a-f,a-s,lo<=a<=hi,basis,hi-lo,a>hi,a<lo,dz["day"]))
print("\nLive log (bias = actual - line):")
for k in sorted(g):
    v=g[k]; print(f"  {k[0]:16s} {k[1]:6s} {k[2]:2d}m n={len(v):3d} days={len({x[7] for x in v})} mae {st.mean(abs(x[0]) for x in v):5.1f} nc {st.mean(abs(x[1]) for x in v):5.1f} "
                  f"bias {st.mean(x[0] for x in v):+6.1f} inside {100*st.mean(x[2] for x in v):3.0f}% above {100*st.mean(x[5] for x in v):3.0f}% below {100*st.mean(x[6] for x in v):3.0f}% "
                  f"width {st.mean(x[4] for x in v):5.1f} model {sum(x[3]=='trendInsulinCarbs' for x in v)}")
# Held out by day: trend scale per group
days=sorted({p["day"] for p in pts})
W=(.5,.75,1,1.25,1.5)
def fits(tr,gain):
    fix={}
    for grp in GROUPS:
        sub=[p for p in tr if p["dz"]["grp"]==grp]
        if sub: fix[grp]=min(W,key=lambda w:sum((stats(sub,gain,h,{grp:w}) or (0,0))[1] for h in (30,60)))
    return fix
for gain in (0.45,0.6,0.7):
    print(f"\n== held out by day (trend scale per group), gain {gain} ==")
    win={h:0 for h in HS}; n={h:0 for h in HS}
    for dd in days:
        tr=[p for p in pts if p["day"]!=dd]; te=[p for p in pts if p["day"]==dd]
        fix=fits(tr,gain); row=[]
        for h in HS:
            a,b=stats(te,gain,h),stats(te,gain,h,fix)
            if not a: continue
            n[h]+=1; win[h]+=b[1]<a[1]-0.05
            row.append(f"{h}m {a[1]:.1f}->{b[1]:.1f} (bias {a[2]:+.1f}->{b[2]:+.1f})")
        print(f"  {dd} {fix} "+" ".join(row))
    print("  held-out days better: "+" ".join(f"{h}m {win[h]}/{n[h]}" for h in HS))
    print("  in-sample", fits(pts,gain))
