# Forecast error just after the Mac wakes or the iPhone app comes to the foreground (docs/ForecastAccuracy.md §107).
# Input: the export in §107 (one string, points separated by ";"). Usage: python3 scripts/wake-forecasts.py rows.txt [gap minutes, default 30]
# A "first" check is a device check whose previous check from the same device is at least the gap earlier;
# "early" is a later check within 30 min of a first one; "steady" is everything else. Relay checks are the same-moment control.
import sys,statistics as st,collections
rows=[]
for r in open(sys.argv[1]).read().split(';'):
    p=r.split(',')
    if len(p)<15: continue
    d,t,gap,m,f,lo,hi,a,s0,tr,clean,sh,ex,basis,ver=p
    rows.append(dict(d=d.lower(),t=int(t),gap=float(gap),m=int(m),f=float(f),lo=float(lo),hi=float(hi),a=float(a),s0=float(s0),tr=float(tr),clean=clean=='1',sh=sh=='1',ex=ex=='1',basis=basis))
GAP=float(sys.argv[2]) if len(sys.argv)>2 else 30
# label device checks
checks=collections.defaultdict(list)
for r in rows: checks[r['d']].append((r['t'],r['gap']))
firsts={d:sorted({t for t,g in v if g>=GAP}) for d,v in checks.items()}
def win(r):
    if r['d']=='r': return 'relay'
    if r['gap']>=GAP: return 'first'
    fs=[x for x in firsts[r['d']] if x<r['t'] and r['t']-x<1800]
    if fs: return 'early'
    return 'steady'
for r in rows: r['w']=win(r)
relay={(r['t'],r['m']):r for r in rows if r['d']=='r'}
rt=sorted({r['t'] for r in rows if r['d']=='r'})
import bisect
def match(r):
    i=bisect.bisect_left(rt,r['t']); best=None
    for j in (i-1,i):
        if 0<=j<len(rt) and abs(rt[j]-r['t'])<=300: 
            if best is None or abs(rt[j]-r['t'])<abs(best-r['t']): best=rt[j]
    return relay.get((best,r['m'])) if best else None
def sc(r): return r['hi']-r['lo']+10*max(r['lo']-r['a'],r['a']-r['hi'],0)
def summ(xs):
    if not xs: return 'n=0'
    days=len({(x['t']+8*3600)//86400 for x in xs})
    mae=st.mean(abs(x['a']-x['f']) for x in xs); nc=st.mean(abs(x['a']-x['s0']) for x in xs)
    b=st.mean(x['a']-x['f'] for x in xs); ins=100*st.mean(x['lo']<=x['a']<=x['hi'] for x in xs)
    return f"n={len(xs):3d} days={days} MAE={mae:5.1f} noch={nc:5.1f} bias={b:+5.1f} in={ins:3.0f}% sc={st.mean(sc(x) for x in xs):5.1f}"
use=[r for r in rows if r['clean'] and r['sh']]
print(f"GAP>={GAP} min")
for dev in ('m','i','mi'):
  for m in (15,30,60):
    for w in ('first','early','steady'):
        xs=[r for r in use if r['d'] in dev and r['m']==m and r['w']==w]
        print(dev,m,w.ljust(6),summ(xs))
  print()
for m in (15,30,60): print('relay',m,summ([r for r in use if r['d']=='r' and r['m']==m]))
print("\nmatched to relay within 5 min (device vs relay, same moment):")
for m in (15,30,60):
  for w in ('first','early','steady'):
    pr=[(r,match(r)) for r in use if r['d'] in 'mi' and r['m']==m and r['w']==w]
    pr=[(a,b) for a,b in pr if b]
    if not pr: print(m,w,'n=0'); continue
    da=st.mean(abs(a['a']-a['f']) for a,b in pr); db=st.mean(abs(b['a']-b['f']) for a,b in pr)
    dstart=st.mean(a['s0']-b['s0'] for a,b in pr); dline=st.mean(abs(a['f']-b['f']) for a,b in pr)
    print(m,w.ljust(6),f"n={len(pr):3d} dev MAE={da:5.1f} relay MAE={db:5.1f} |line diff|={dline:4.1f} start diff={dstart:+4.1f}")
print("\nbasis share first vs steady:")
for w in ('first','steady'):
    c=collections.Counter(r['basis'] for r in use if r['d'] in 'mi' and r['m']==15 and r['w']==w); print(w,dict(c))
print("|trend| first",st.mean(abs(r['tr']) for r in use if r['w']=='first' and r['m']==15),"steady",st.mean(abs(r['tr']) for r in use if r['w']=='steady' and r['m']==15))
print("first gap lengths (min):", sorted(int(r['gap']) for r in use if r['w']=='first' and r['m']==15))
import datetime as dt
print("\nmatched inside% device vs relay (15):")
for w in ('first','early','steady'):
  for dev in ('m','i'):
    pr=[(r,match(r)) for r in use if r['d']==dev and r['m']==15 and r['w']==w]; pr=[(a,b) for a,b in pr if b]
    if pr: print(dev,w.ljust(6),len(pr),f"dev in={100*st.mean(a['lo']<=a['a']<=a['hi'] for a,b in pr):.0f}% relay in={100*st.mean(b['lo']<=b['a']<=b['hi'] for a,b in pr):.0f}% devMAE={st.mean(abs(a['a']-a['f']) for a,b in pr):.1f} relayMAE={st.mean(abs(b['a']-b['f']) for a,b in pr):.1f}")
def day(t): return dt.datetime.utcfromtimestamp(t+8*3600).strftime('%d')
print("\niPhone first by Perth day:")
for m in (15,30,60):
  c=collections.defaultdict(list)
  for r in use:
    if r['d']=='i' and r['m']==m and r['w']=='first': c[day(r['t'])].append(r)
  print(m,{k:(len(v),round(st.mean(x['a']-x['f'] for x in v)),round(st.mean(abs(x['a']-x['f']) for x in v))) for k,v in sorted(c.items())})
print("\niPhone steady by Perth day 30:")
c=collections.defaultdict(list)
for r in use:
  if r['d']=='i' and r['m']==30 and r['w']=='steady': c[day(r['t'])].append(r)
print({k:(len(v),round(st.mean(x['a']-x['f'] for x in v))) for k,v in sorted(c.items())})
print("\nhour of day (Perth) of first checks, iPhone/Mac:")
for dev in 'mi': print(dev,sorted(int(dt.datetime.utcfromtimestamp(r['t']+8*3600).hour) for r in use if r['d']==dev and r['m']==15 and r['w']=='first'))
print("\nstart diff vs relay first checks, worst:",sorted(round(a['s0']-match(a)['s0']) for a in use if a['d'] in 'mi' and a['m']==15 and a['w']=='first' and match(a)))
print("\nexcluding 15 Nov, iPhone:")
for m in (15,30,60):
  for w in ('first','steady'):
    print(m,w,summ([r for r in use if r['d']=='i' and r['m']==m and r['w']==w and day(r['t'])!='15']))
print("\nLODO fixes for iPhone first checks (fit on other days):")
def scaled(r,k,b=0):
  c=(r['lo']+r['hi'])/2; h=(r['hi']-r['lo'])/2
  return dict(r,f=r['f']+b,lo=c+b-k*h,hi=c+b+k*h)
def fitk(xs):
  rat=sorted(abs(x['a']-(x['lo']+x['hi'])/2)/max((x['hi']-x['lo'])/2,1) for x in xs)
  q=rat[int(0.8*(len(rat)-1))]; return min(2.5,max(1.0,q))
for m in (15,30):
  pts=[r for r in use if r['d']=='i' and r['m']==m and r['w']=='first']
  days=sorted({day(r['t']) for r in pts}); res=[]
  for d in days:
    tr=[r for r in pts if day(r['t'])!=d]; te=[r for r in pts if day(r['t'])==d]
    if len(tr)<10: continue
    k=fitk(tr); b=st.median(x['a']-x['f'] for x in tr)
    base=st.mean(sc(x) for x in te); wk=st.mean(sc(scaled(x,k)) for x in te)
    mb=st.mean(abs(x['a']-x['f']) for x in te); mo=st.mean(abs(x['a']-x['f']-b) for x in te)
    res.append((d,len(te),round(k,2),round(base),round(wk),round(b,1),round(mb,1),round(mo,1)))
  print(m,'day n k score_base score_width offset MAE_base MAE_offset'); [print('  ',x) for x in res]
  print('  width better on',sum(x[4]<x[3] for x in res),'/',len(res),' offset better on',sum(x[7]<x[6] for x in res),'/',len(res))
print("\nmatched no-change MAE (15):")
for dev in ('m','i','mi'):
  for w in ('first','steady'):
    pr=[(r,match(r)) for r in use if r['d'] in dev and r['m']==15 and r['w']==w]; pr=[(a,b) for a,b in pr if b]
    print(dev,w,len(pr),'days',len({day(a['t']) for a,b in pr}),'noch',round(st.mean(abs(a['a']-a['s0']) for a,b in pr),1),'dev',round(st.mean(abs(a['a']-a['f']) for a,b in pr),1),'relay',round(st.mean(abs(b['a']-b['f']) for a,b in pr),1),'linediff',round(st.mean(abs(a['f']-b['f']) for a,b in pr),1))
print("first checks count by device:",{d:len(v) for d,v in firsts.items()})
