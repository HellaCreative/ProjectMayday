"""Executable P-gate counterexamples. Passing observations do NOT qualify full DIRT."""
import json,pathlib,time,resource
import valhalla
ROOT=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911/valhalla-spike')
def decode(shape):
 if isinstance(shape,dict):return shape['coordinates']
 coords=[];prev=[0,0];i=0
 while i<len(shape):
  for dim in range(2):
   value=0;shift=0
   while True:
    b=ord(shape[i])-63;i+=1;value|=(b&31)<<shift;shift+=5
    if b<32:break
   prev[dim]+=~(value>>1) if value&1 else value>>1
  coords.append([prev[1]/1e6,prev[0]/1e6])
 return coords
a=valhalla.Actor(str(ROOT/'config.json'));results=[]
def loc(lat,lon,type='break'):return dict(lat=lat,lon=lon,type=type,minimum_reachability=0,radius=15,search_cutoff=30)
def run(name,points,opts):
 q=dict(locations=points,costing='motorcycle',costing_options={'motorcycle':opts},shape_format='geojson',directions_options={'units':'kilometers'})
 t=time.perf_counter()
 try:
  r=a.route(q);shapes=[decode(l['shape']) for l in r['trip']['legs']];names=[s for l in r['trip']['legs'] for m in l['maneuvers'] for s in m.get('street_names',[])];row=dict(name=name,request=q,seconds=time.perf_counter()-t,meters=r['trip']['summary']['length']*1000,shapes=shapes,names=names)
 except Exception as e:row=dict(name=name,request=q,error=str(e))
 results.append(row);return row
for trails in [0,.5,.75,1]:
 for highways in [0,.5,1]:run(f'surface_trails{trails}_highways{highways}',[loc(45,-63.001),loc(45,-62.979)],dict(use_trails=trails,use_highways=highways,fixed_speed=30))
run('restricted_no_stop',[loc(45.03,-63.001),loc(45.03,-62.979)],dict(fixed_speed=30))
for kind in ['break','through','break_through']:
 run('restricted_mid_via_'+kind,[loc(45.03,-63.001),loc(45.03,-62.985,kind),loc(45.03,-62.979)],dict(fixed_speed=30))
report=dict(scope='Synthetic source-import and native actor proof; no fuel range, DIRT objective or broad map qualification.',results=results,peakRssRaw=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
(ROOT/'actor-check.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
