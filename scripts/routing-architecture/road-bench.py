"""R-tier engine comparison. Same anchors, ordinary car costs; no DIRT fuel claim."""
import argparse,gzip,hashlib,json,os,pathlib,resource,subprocess,time,urllib.request,urllib.parse
p=argparse.ArgumentParser();p.add_argument('engine',choices=['osrm','graphhopper','valhalla']);p.add_argument('case');p.add_argument('output');p.add_argument('--mode',default='default');p.add_argument('--repeat',type=int,default=6);p.add_argument('--dataset',default='atlantic');a=p.parse_args()
root=pathlib.Path(os.environ.get('DIRT_ENGINE_ROOT','/Users/richardsmith/.codex/experiments/routing-architecture-20260911'))
fixtures=json.loads((pathlib.Path(__file__).resolve().parents[2]/'docs/experiments/routing-performance-2026-09-10/matrix-inputs.json').read_text());fixture=next(f for f in fixtures if f['id']==a.case);points=fixture['request']['locations'];out=pathlib.Path(a.output);out.parent.mkdir(parents=True,exist_ok=True)
started=time.perf_counter();server=None;log=None
def rss(pid):
 s=subprocess.run(['ps','-o','rss=','-p',str(pid)],capture_output=True,text=True).stdout.strip();return int(s)*1024 if s else None
def http(url):
 with urllib.request.urlopen(url,timeout=100) as response:return json.load(response)
try:
 if a.engine=='osrm':
  import osrm
  engine=osrm.OSRM(storage_config=str(root/'data'/f'{a.dataset}-260907.osrm'),algorithm='MLD',use_shared_memory=False,use_mmap=True)
  def native(value):
   if isinstance(value,osrm.Object):return {k:native(value[k]) for k in value}
   if isinstance(value,osrm.Array):return [native(x) for x in value]
   return value
  def query():return native(engine.Route(osrm.RouteParameters(coordinates=[(p['lon'],p['lat']) for p in points],geometries='geojson',overview='full',annotations=['nodes','distance'],radiuses=[2000.0]*len(points))))
 elif a.engine=='valhalla':
  import valhalla
  engine=valhalla.Actor(str(root/'tools'/f'valhalla-{a.dataset}.json'))
  def query():return engine.route({'locations':[dict(p,type='break') for p in points],'costing':'auto','directions_options':{'units':'kilometers'},'shape_format':'geojson'})
 else:
  log=out.with_suffix('.server.log').open('w');server=subprocess.Popen(['/opt/homebrew/opt/openjdk/bin/java','-Xmx2g','-jar',str(root/'tools/graphhopper-web-11.0.jar'),'server',str(root/'tools'/f'graphhopper-{a.dataset}.yml')],stdout=log,stderr=subprocess.STDOUT)
  deadline=time.monotonic()+60
  while time.monotonic()<deadline:
   if server.poll() is not None:raise RuntimeError('GraphHopper startup failed; inspect server log')
   try:http('http://127.0.0.1:18989/info');break
   except (OSError,ValueError):time.sleep(.1)
  else:raise TimeoutError('GraphHopper startup deadline')
  params=[('point',str(p['lat'])+','+str(p['lon'])) for p in points]+[('profile','car'),('points_encoded','false'),('details','surface'),('details','osm_way_id')]
  if a.mode=='lm':params.append(('ch.disable','true'))
  elif a.mode=='flexible':params.extend([('ch.disable','true'),('lm.disable','true')])
  def query():return http('http://127.0.0.1:18989/route?'+urllib.parse.urlencode(params))
 init=time.perf_counter()-started;initialRss=rss(server.pid if server else os.getpid());runs=[]
 for i in range(a.repeat):
  t=time.perf_counter();result=query();elapsed=time.perf_counter()-t
  if a.engine=='osrm':ok=result.get('code')=='Ok';distance=result.get('routes',[{}])[0].get('distance');geometry=result.get('routes',[{}])[0].get('geometry');diagnostics={}
  elif a.engine=='graphhopper':ok=bool(result.get('paths'));distance=result.get('paths',[{}])[0].get('distance');geometry=result.get('paths',[{}])[0].get('points');diagnostics=result.get('hints',{})
  else:ok=result.get('trip',{}).get('status')==0;distance=result.get('trip',{}).get('summary',{}).get('length',0)*1000;geometry=[l.get('shape') for l in result.get('trip',{}).get('legs',[])];diagnostics=result.get('trip',{}).get('summary',{})
  proof=json.dumps({'distance':distance,'geometry':geometry},sort_keys=True).encode();runs.append({'run':i,'seconds':elapsed,'roadComplete':ok,'distanceMeters':distance,'proofSha256':hashlib.sha256(proof).hexdigest(),'residentBytes':rss(server.pid if server else os.getpid()),'diagnostics':diagnostics})
  if i==0:
   with gzip.open(str(out)+'.response.json.gz','wb') as f:f.write(json.dumps(result).encode())
  if not ok:break
 report={'engine':a.engine,'mode':a.mode,'dataset':a.dataset,'fixture':fixture,'scope':'Ordinary road routing only. Input profile/access/fuel semantics NOT claimed equivalent. Native Python binding for OSRM/Valhalla, local HTTP/JVM for GraphHopper; initialization measured separately. Process-cold, not OS-page-cache cold.','initializationSeconds':init,'initialResidentBytes':initialRss,'runs':runs,'ownPeakRss':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss}
 out.write_text(json.dumps(report,indent=2));print(json.dumps({'engine':a.engine,'mode':a.mode,'case':a.case,'initializationSeconds':init,'runs':runs}),flush=True)
 if not all(r['roadComplete'] for r in runs):raise SystemExit(2)
finally:
 if server:
  server.terminate()
  try:server.wait(10)
  except subprocess.TimeoutExpired:server.kill();server.wait()
 if log:log.close()
