"""Verified-road integration benchmark, explicitly not yet city/fuel qualification."""
import argparse,pathlib,json,subprocess,time,threading,queue,gzip,hashlib
p=argparse.ArgumentParser();p.add_argument('--hybrid',action='store_true');p.add_argument('--dataset',default='nsnb');p.add_argument('--objective-landmarks',action='store_true');p.add_argument('--profiles',nargs='+',default=['distance','paved','dirt10','dirt30']);p.add_argument('--case',default='nsnb-balanced-road');p.add_argument('--repeat',type=int,default=3);p.add_argument('--out',required=True);p.add_argument('--flexible',action='store_true');p.add_argument('--usable-range-meters',type=float);p.add_argument('--initial-usable-meters',type=float);p.add_argument('--fuel-portfolio',action='store_true');p.add_argument('--portfolio-only',action='store_true');a=p.parse_args()
r=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911');out=pathlib.Path(a.out);out.parent.mkdir(parents=True,exist_ok=True)
fixtures=json.loads((pathlib.Path(__file__).resolve().parents[2]/'docs/experiments/routing-performance-2026-09-10/matrix-inputs.json').read_text());fixture=next(f for f in fixtures if f['id']==a.case);req=fixture['request'];loc=req['locations']
cmd=['/opt/homebrew/opt/openjdk/bin/java','-Xmx2g','-cp',str(r/'tools/gh-adapter')+':'+str(r/'tools/graphhopper-web-11.0.jar'),'HybridHopper' if a.hybrid else 'VerifiedHopper',str(r/f'data/verified-{a.dataset}/verified-input.json'),str(r/f'data/gh-verified-{a.dataset}-directed-v2')]
if a.objective_landmarks:
 cmd.insert(1,'-Ddirt.objectiveLandmarks=true');cmd[-1]+='-objective'
messages=queue.Queue();start=time.perf_counter();child=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
log=out.with_suffix('.log').open('w')
def consume():
 for line in child.stdout:
  if line.startswith('RESULT '):messages.put(('result',json.loads(line[7:])))
  elif line.startswith('READY '):messages.put(('ready',line.strip()))
  else:log.write(line);log.flush()
 messages.put(('exit',child.poll()))
threading.Thread(target=consume,daemon=True).start()
def rss():
 text=subprocess.check_output(['ps','-o','rss=','-p',str(child.pid)],text=True).strip();return int(text)*1024
results=[]
try:
 kind,value=messages.get(timeout=180);assert kind=='ready',(kind,value)
 initialization=time.perf_counter()-start;initialRss=rss()
 for i in range(a.repeat):
  for profile in a.profiles:
   query={'start':[loc[0]['lon'],loc[0]['lat']],'end':[loc[-1]['lon'],loc[-1]['lat']],'profile':profile,'allowUnknown':req.get('accessPolicy',{}).get('motorizedUnknown',False),'wander':req.get('ridePreferences',{}).get('wander',1),'flexible':a.flexible}
   if a.usable_range_meters is not None:query['fuel']={'usableRangeMeters':a.usable_range_meters,'initialUsableMeters':a.initial_usable_meters if a.initial_usable_meters is not None else a.usable_range_meters}
   query['fuelPortfolio']=a.fuel_portfolio or a.portfolio_only;query['portfolioOnly']=a.portfolio_only
   t=time.perf_counter();child.stdin.write(json.dumps(query)+'\n');child.stdin.flush();kind,result=messages.get(timeout=100);assert kind=='result',(kind,result)
   if a.hybrid:
    envelope=result;result=dict(envelope.get('fuel',{}) if 'fuel' in query else envelope.get('road',{}));result['hybridState']=envelope.get('state');result['hybridError']=envelope.get('error');result['roadCandidate']=envelope.get('road')
   record={'run':i,'query':query,'endToEndSeconds':time.perf_counter()-t,'residentBytes':rss(),'result':result};results.append(record)
   print(json.dumps({k:v for k,v in record.items() if k!='result'}|{k:v for k,v in result.items() if k not in ['points','edges','steps','escape','roadSourceKeys','roadCandidate']}),flush=True)
   if not a.hybrid and (result.get('errors') or result.get('error') or ('fuel' in query and result.get('state')!='found')):raise RuntimeError('incomplete route')
finally:
 child.terminate()
 try:child.wait(10)
 except subprocess.TimeoutExpired:child.kill();child.wait()
 log.close()
 with gzip.open(str(out)+'.responses.json.gz','wt') as f:json.dump(results,f)
 report={'fixture':fixture,'dataset':a.dataset,'hybrid':a.hybrid,'initializationSeconds':locals().get('initialization'),'initialResidentBytes':locals().get('initialRss'),'scope':'Verified graph, additive objectives, directed turns, paired endpoint directions. City/highway avoidance, full candidate ranking and fuel NOT qualified. Process-cold is not OS-cold.','runs':[{k:v for k,v in x.items() if k!='result'}|{'result':{k:v for k,v in x['result'].items() if k not in ['edges','points','steps','escape','roadSourceKeys','roadCandidate']},'proofSha256':hashlib.sha256(json.dumps(x['result'].get('steps',x['result'].get('edges')),sort_keys=True).encode()).hexdigest()} for x in results]};out.write_text(json.dumps(report,indent=2))

if a.hybrid and any(x["result"].get("hybridState") not in ("fuel_verified","road_only") for x in results):raise SystemExit(2)
