"""Bounded native OSRM HTTP concurrency comparison; ordinary-road (R) tier only.
Must be scheduled by the experiment coordinator: do not overlap capacity runs
with imports. One native server, mmap data, fixed worker count; HTTP client
concurrency is NOT measured simultaneous engine-search concurrency.
"""
import argparse,concurrent.futures,math,hashlib,http.client,json,os,pathlib,shutil,signal,socket,statistics,subprocess,sys,threading,time,urllib.parse
ROOT=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911')
REPO=pathlib.Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--dataset',default='atlantic');p.add_argument('--data',type=pathlib.Path)
p.add_argument('--fixtures',default='ns-short-balanced-road,ns-long-dirt-road,nsnb-balanced-road,bangor-road')
p.add_argument('--workers',type=int,default=2);p.add_argument('--levels',default='1,2,4,8');p.add_argument('--rounds',type=int,default=3);p.add_argument('--requests',type=int,default=32)
p.add_argument('--seconds',type=float,default=600);p.add_argument('--timeout',type=float,default=60);p.add_argument('--rss-mib',type=int,default=2048);p.add_argument('--out',type=pathlib.Path,required=True)
p.add_argument('--smoke',action='store_true',help='Tiny synthetic API smoke only, not a capacity comparison')
a=p.parse_args();levels=[int(n) for n in a.levels.split(',')]
if not 1<=a.workers<=8 or not all(1<=n<=8 for n in levels) or not 1<=a.requests<=128 or not 1<=a.rounds<=5:p.error('Bounds: workers/levels1..8,requests1..128,rounds1..5')
if a.smoke:
 a.data=ROOT/'osrm-spike/dirt10-1/fixture.osrm';levels=[1,2];a.rounds=1;a.requests=4;a.workers=1;a.rss_mib=min(a.rss_mib,256)
 fixtures=[{'id':'tiny-surface','request':{'locations':[{'lon':-63,'lat':45},{'lon':-62.996,'lat':45}]}},{'id':'tiny-via','request':{'locations':[{'lon':-63,'lat':45.02},{'lon':-62.994,'lat':45.02}]}}]
else:
 all_fixtures=json.loads((REPO/'docs/experiments/routing-performance-2026-09-10/matrix-inputs.json').read_text());lookup={f['id']:f for f in all_fixtures};fixtures=[lookup[n] for n in a.fixtures.split(',')]
data=a.data or ROOT/'data'/f'{a.dataset}-260907.osrm'
if not data.with_suffix('.osrm.properties').exists():p.error('Prepared dataset properties missing')
a.out.parent.mkdir(parents=True,exist_ok=True)
# Bind ephemeral localhost port before startup; report unavoidable close/bind race.
with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
cmd=[sys.executable,'-m','osrm','routed','--algorithm','MLD','--mmap','--ip','127.0.0.1','--port',str(port),'--threads',str(a.workers),str(data)]
report={'scope':'R-tier native HTTP only; fixture Dirt/Balanced/Clean/access/fuel settings are not implemented by the car dataset. Smoke uses synthetic custom cost, still not a capacity result. Process-cold is not OS-cache-cold.', 'smoke':a.smoke,'command':cmd,'dataset':str(data),'workers':a.workers,'levels':levels,'rounds':a.rounds,'requestsPerRound':a.requests,'fixtures':fixtures,'results':[],'samples':[],'limits':{'rssMiB':a.rss_mib,'diskReserveGiB':4,'requestTimeoutSeconds':a.timeout,'totalDeadlineSeconds':a.seconds},'measurementLimits':['HTTP outstanding requests are measured; actual native searches and internal server queue delay are not instrumented.','Client queue delay is submission-to-dispatch; response latency includes server queue, search, assembly, transport and JSON decode.','One server maps shared immutable graph; RSS is summed over only its process group, sampled every100ms, including CLI wrapper. Mapping size is not resident or private memory.','No exact fetched/reread byte counters or per-request private-memory counters. Report artifact bytes and HTTP response bytes separately.','Thread count bounds worker execution; Python client threads perform network I/O, not OSRM binding searches.','Socket disconnect is not evidence that native search is cancelled. Process shutdown is separately measured.','Local host, fixed prepared car metric, no full DIRT qualification or production-user extrapolation.']}
report['artifactBytes']=sum(f.stat().st_size for f in data.parent.glob(data.name+'*') if f.is_file())
report['propertiesSha256']=hashlib.sha256(data.with_suffix('.osrm.properties').read_bytes()).hexdigest()
report['sourceCommit']=subprocess.check_output(['git','-C',str(ROOT/'sources/osrm'),'rev-parse','HEAD'],text=True).strip()
stop=threading.Event();failure=[];lock=threading.Lock();active=0;maxactive=0;server=None

def persist():a.out.write_text(json.dumps(report,indent=2))
def sample():
 while not stop.is_set():
  try:
   rows=subprocess.check_output(['ps','-axo','pgid=,rss='],text=True).splitlines();rss=sum(int(v[1])*1024 for line in rows if len(v:=line.split())==2 and int(v[0])==server.pid)
   report['samples'].append({'elapsedSeconds':time.perf_counter()-started,'groupRssBytes':rss,'phase':phase})
   reason='RSS limit' if rss>a.rss_mib*1024**2 else ('Disk reserve' if shutil.disk_usage(ROOT).free<4*1024**3 else ('Total deadline' if time.perf_counter()-started>a.seconds else None))
   if reason:
    failure.append(reason);os.killpg(server.pid,signal.SIGTERM);stop.set()
  except ProcessLookupError:break
  stop.wait(.1)
def path(f):
 coordinates=';'.join(f"{v['lon']},{v['lat']}" for v in f['request']['locations'])
 return '/route/v1/driving/'+coordinates+'?'+urllib.parse.urlencode({'overview':'full','geometries':'geojson','annotations':'nodes,distance','radiuses':';'.join(['10' if a.smoke else '2000']*len(f['request']['locations']))})
def query(f,submitted=None):
 global active,maxactive
 dispatched=time.perf_counter()
 with lock:active+=1;maxactive=max(maxactive,active)
 row={'fixture':f['id'],'clientQueueSeconds':dispatched-submitted if submitted else 0}
 conn=http.client.HTTPConnection('127.0.0.1',port,timeout=a.timeout)
 try:
  conn.request('GET',path(f),headers={'Connection':'close'});response=conn.getresponse();raw=response.read();value=json.loads(raw)
  route=value.get('routes',[{}])[0];row.update(httpStatus=response.status,code=value.get('code'),roadComplete=value.get('code')=='Ok',responseBytes=len(raw),distanceMeters=route.get('distance'),proofSha256=hashlib.sha256(json.dumps({'distance':route.get('distance'),'geometry':route.get('geometry')},sort_keys=True).encode()).hexdigest())
 except Exception as error:row.update(roadComplete=False,error=type(error).__name__+': '+str(error))
 finally:
  conn.close();row['responseSeconds']=time.perf_counter()-dispatched
  row['totalSeconds']=row['responseSeconds']+row['clientQueueSeconds']
  with lock:active-=1
 return row
def quantiles(values):
 v=sorted(values);return {'median':statistics.median(v),'p95':v[min(len(v)-1,math.ceil(.95*len(v))-1)],'max':max(v)}
started=time.perf_counter();phase='startup';monitor=None
try:
 log=a.out.with_suffix('.server.log').open('w');server=subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
 monitor=threading.Thread(target=sample,daemon=True);monitor.start()
 deadline=time.monotonic()+a.timeout
 while time.monotonic()<deadline:
  if server.poll() is not None:raise RuntimeError('Server exited during startup')
  try:
   with socket.create_connection(('127.0.0.1',port),timeout=.1):break
  except OSError:time.sleep(.02)
 else:raise TimeoutError('Startup deadline')
 report['startupSeconds']=time.perf_counter()-started
 phase='first-request';report['firstRequest']=query(fixtures[0]);report['startupPlusFirstSeconds']=time.perf_counter()-started
 if not report['firstRequest']['roadComplete']:raise RuntimeError('First route failed')
 phase='warm-controls';report['warmControls']=[query(f) for f in fixtures]
 if not all(r['roadComplete'] for r in report['warmControls']):raise RuntimeError('Mixed control route failed')
 proofs={r['fixture']:r['proofSha256'] for r in report['warmControls']}
 for level in levels:
  for round_ in range(a.rounds):
   phase=f'clients-{level}-round-{round_}';t=time.perf_counter();maxactive=0
   with concurrent.futures.ThreadPoolExecutor(max_workers=level) as pool:
    futures=[pool.submit(query,fixtures[(i+round_)%len(fixtures)],time.perf_counter()) for i in range(a.requests)]
    rows=[f.result() for f in futures]
   elapsed=time.perf_counter()-t
   for r in rows:r['stableProof']=r.get('proofSha256')==proofs[r['fixture']]
   report['results'].append({'clientConcurrency':level,'nativeWorkerUpperBound':a.workers,'round':round_,'elapsedSeconds':elapsed,'requestsPerSecond':len(rows)/elapsed,'maxOutstandingHttpRequests':maxactive,'latencySeconds':quantiles([r['responseSeconds'] for r in rows]),'clientQueueSeconds':quantiles([r['clientQueueSeconds'] for r in rows]),'requests':rows})
   report['results'][-1]['sampledGroupRssBytes']=[s['groupRssBytes'] for s in report['samples'] if s['phase']==phase]
   persist()
   if failure or any(not r['roadComplete'] or not r['stableProof'] for r in rows):raise RuntimeError('Guard, route or proof failure; later levels skipped')
 phase='disconnect-probe';t=time.perf_counter()
 with socket.create_connection(('127.0.0.1',port),timeout=2) as sock:
  sock.sendall(('GET '+path(fixtures[-1])+' HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n').encode())
 report['disconnectProbe']={'clientCloseSeconds':time.perf_counter()-t,'nativeSearchCancellation':'unobserved; handler has no propagated client cancellation token','healthRequest':query(fixtures[0])}
 phase='retained-idle';time.sleep(.3)
except Exception as error:report['failure']=type(error).__name__+': '+str(error)
finally:
 if server:
  phase='shutdown';t=time.perf_counter();forced=False
  if server.poll() is None:
   os.killpg(server.pid,signal.SIGTERM)
   try:server.wait(timeout=5)
   except subprocess.TimeoutExpired:forced=True;os.killpg(server.pid,signal.SIGKILL);server.wait(timeout=5)
  report['shutdown']={'seconds':time.perf_counter()-t,'returncode':server.returncode,'forcedKill':forced}
 stop.set()
 if monitor:monitor.join(timeout=2)
 if server:log.close()
 report['guardFailures']=failure;report['peakSampledGroupRssBytes']=max((s['groupRssBytes'] for s in report['samples']),default=0)
 report['retainedIdleGroupRssBytes']=[s['groupRssBytes'] for s in report['samples'] if s['phase']=='retained-idle']
 persist()
print(json.dumps({'out':str(a.out),'failure':report.get('failure'),'samples':len(report['samples']),'completedRounds':len(report['results']),'peakSampledGroupRssBytes':report['peakSampledGroupRssBytes']}))
if report.get('failure') or failure:raise SystemExit(1)
