"""Tiny isolated OSRM P gate; explicit constraints and source-walk assertions.
Builds execute sequentially. Run through parent memory guard after scheduling.
"""
import argparse, json, os, pathlib, subprocess, sys, time, hashlib
import xml.etree.ElementTree as X
ROOT=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911')
HERE=pathlib.Path(__file__).resolve().parent
OUT=ROOT/'osrm-spike'; OUT.mkdir(exist_ok=True)
p=argparse.ArgumentParser();p.add_argument('--build',action='store_true');a=p.parse_args()
# Preference diamond, turn-history diamond, access diamond: disconnected controls.
nodes={1:(-63,45),2:(-62.998,45),3:(-62.996,45),4:(-62.998,45.003),
 11:(-63,45.02),12:(-62.998,45.02),13:(-62.996,45.02),14:(-62.994,45.02),15:(-62.996,45.023),
 21:(-63,45.04),22:(-62.998,45.04),23:(-62.996,45.04),24:(-62.998,45.043),
 31:(-63,45.06),32:(-62.998,45.06),33:(-62.996,45.06),34:(-62.998,45.063)}
ways=[(101,[1,2,3],'paved',0,0),(102,[1,4,3],'dirt',0,0),
 (111,[11,12],'dirt',0,2),(112,[12,13],'dirt',0,2),(113,[13,14],'dirt',0,2),(114,[13,15,14],'dirt',0,2),
 (121,[21,22,23],'dirt',1,1),(122,[21,24,23],'paved',0,0),
 (131,[31,32,33],'dirt',2,2),(132,[31,34,33],'paved',0,2)]
def fixture():
 root=X.Element('osm',version='0.6',generator='DIRT private compatibility fixture')
 for n,(lon,lat) in nodes.items():X.SubElement(root,'node',id=str(n),lon=str(lon),lat=str(lat),version='1')
 for wid,ns,surf,f,b in ways:
  w=X.SubElement(root,'way',id=str(wid),version='1')
  for n in ns:X.SubElement(w,'nd',ref=str(n))
  for k,v in {'highway':'track' if surf=='dirt' else 'residential','name':str(wid),'dirt:surface':surf,'dirt:access:forward':str(f),'dirt:access:backward':str(b)}.items():X.SubElement(w,'tag',k=k,v=v)
 r=X.SubElement(root,'relation',id='900',version='1')
 for wid,role in [(111,'from'),(112,'via'),(113,'to')]:X.SubElement(r,'member',type='way',ref=str(wid),role=role)
 X.SubElement(r,'tag',k='type',v='restriction');X.SubElement(r,'tag',k='restriction',v='no_straight_on')
 return X.tostring(root,encoding='utf-8',xml_declaration=True)
(OUT/'fixture-data.json').write_text(json.dumps({'nodes':nodes,'ways':ways},indent=2))
metrics=[('paved',1),('dirt10',1),('dirt30',1),('dirt10',0),('dirt10',0.5)]
if a.build:
 builds=[]
 for objective,wander in metrics:
  name=f'{objective}-{wander}'; directory=OUT/name;directory.mkdir(exist_ok=True)
  source=directory/'fixture.osm';source.write_bytes(fixture()); env=dict(os.environ,DIRT_OBJECTIVE=objective,DIRT_WANDER=str(wander))
  for stage,args in [('extract',['-p',str(HERE/'profile.lua'),str(source)]),('partition',[str(source.with_suffix('.osrm'))]),('customize',[str(source.with_suffix('.osrm'))])]:
   cmd=[sys.executable,'-m','osrm',stage,'-t','1',*args];started=time.perf_counter()
   with (directory/f'{stage}.log').open('w') as log:r=subprocess.run(cmd,env=env,stdout=log,stderr=subprocess.STDOUT)
   builds.append({'metric':name,'stage':stage,'seconds':time.perf_counter()-started,'returncode':r.returncode})
   (OUT/'build-results.json').write_text(json.dumps(builds,indent=2))
   if r.returncode:raise RuntimeError(f'{name} {stage} failed')
import osrm

def native(v):
 if isinstance(v,osrm.Object):return {k:native(v[k]) for k in v}
 if isinstance(v,osrm.Array):return [native(x) for x in v]
 return v
results=[]
for objective,wander in metrics:
 name=f'{objective}-{wander}'; engine=osrm.OSRM(storage_config=str(OUT/name/'fixture.osrm'),algorithm='MLD',use_shared_memory=False,use_mmap=True)
 def route(label,points,**kw):
  t=time.perf_counter()
  try:r=native(engine.Route(osrm.RouteParameters(coordinates=points,geometries='geojson',overview='full',annotations=['nodes','distance','weight'],radiuses=[10.]*len(points),**kw)))
  except RuntimeError as error:r={'code':str(error).split(' - ')[0],'message':str(error)}
  row={'metric':name,'case':label,'seconds':time.perf_counter()-t,'response':r};results.append(row);return r
 route('surface',[nodes[1],nodes[3]])
 route('unknown-on',[nodes[21],nodes[23]])
 route('unknown-off',[nodes[21],nodes[23]],exclude=['unknown'])
 route('denied',[nodes[31],nodes[33]])
 route('reverse-denied',[nodes[33],nodes[31]])
 route('via-whole',[nodes[11],nodes[14]])
 pump=(-62.997,45.02)
 route('via-stop',[nodes[11],pump,nodes[14]],continue_straight=True)
 route('via-offroad-stop',[nodes[11],(pump[0],pump[1]+0.00002),nodes[14]],continue_straight=True)
 route('via-arrive',[nodes[11],pump])
 route('via-resume',[pump,nodes[14]],continue_straight=True)
 # Bearings are not a prior-edge history token; explicitly test an eastbound resumption.
 route('via-resume-bearing',[pump,nodes[14]],bearings=[(90,10),None])
(OUT/'results.json').write_text(json.dumps({'fixtureSha256':hashlib.sha256(fixture()).hexdigest(),'profileSha256':hashlib.sha256((HERE/'profile.lua').read_bytes()).hexdigest(),'results':results},indent=2))
for r in results:
 x=r['response']; paths=x.get('routes',[]); route=paths[0] if paths else {}; print(json.dumps({'metric':r['metric'],'case':r['case'],'code':x.get('code'),'distance':route.get('distance'),'weight':route.get('weight'),'nodes':[leg.get('annotation',{}).get('nodes') for leg in route.get('legs',[])]}))
