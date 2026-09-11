"""Bounded concurrent verified additive/fuel requests; no rider-ranking qualification."""
import argparse,pathlib,json,gzip,subprocess,threading,queue,time,hashlib,statistics
p=argparse.ArgumentParser();p.add_argument('--hybrid',action='store_true');p.add_argument('--workers',type=int,default=2);p.add_argument('--levels',default='1,2,4');p.add_argument('--rounds',type=int,default=2);p.add_argument('--out',required=True);a=p.parse_args()
levels=list(map(int,a.levels.split(',')));assert 1<=a.workers<=4 and max(levels)<=8 and min(levels)>=1 and 1<=a.rounds<=3
r=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911');out=pathlib.Path(a.out);repo=pathlib.Path(__file__).resolve().parents[2]
fixtures={x['id']:x for x in json.loads((repo/'docs/experiments/routing-performance-2026-09-10/matrix-inputs.json').read_text())}
cases=[]
for case,profile in [('ns-short-balanced-road','paved'),('ns-short-balanced-road','dirt10'),('ns-long-dirt-road','dirt30'),('ns-long-dirt-road','paved'),('nsnb-balanced-road','dirt10'),('nsnb-balanced-road','dirt30')]:
 loc=fixtures[case]['request']['locations'];cases.append({'case':case,'query':{'start':[loc[0]['lon'],loc[0]['lat']],'end':[loc[-1]['lon'],loc[-1]['lat']],'profile':profile,'allowUnknown':False,'wander':1,'fuel':{'usableRangeMeters':180000,'initialUsableMeters':90000},'fuelPortfolio':True,'hybrid':a.hybrid}})
cmd=['/opt/homebrew/opt/openjdk/bin/java','-Ddirt.objectiveLandmarks=true','-Xmx2g','-cp',str(r/'tools/gh-adapter')+':'+str(r/'tools/graphhopper-web-11.0.jar'),'ConcurrentVerifiedHopper',str(r/'data/verified-nsnb/verified-input.json'),str(r/'data/gh-verified-nsnb-directed-v2-objective'),str(a.workers)]
messages=queue.Queue();log=out.with_suffix('.log').open('w');started=time.perf_counter();child=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
def consume():
 for line in child.stdout:
  if line.startswith('READY '):messages.put(('ready',line))
  elif line.startswith('RESULT '):messages.put(('result',json.loads(line[7:])))
  else:log.write(line);log.flush()
 messages.put(('exit',None))
threading.Thread(target=consume,daemon=True).start();report={'command':cmd,'workers':a.workers,'cases':cases,'rounds':[],'scope':'Verified NSNB topology, additive profiles plus fuel certificate; not full Dirt/Balanced/Clean ranking, legacy continuation or national/hosted capacity. stdin/stdout transport and JSON decoding included. Queue delay is measured inside worker service; active routing calls include preparation and geometry assembly, not only graph expansion. Process-cold, warm OS cache. RSS does not isolate private memory per request.'};raw=[];serial=0

def rss():return int(subprocess.check_output(['ps','-o','rss=','-p',str(child.pid)],text=True).strip())*1024
def batch(indices):
 global serial
 pending={};records=[]
 for index in indices:
  serial+=1;id=str(serial);q=cases[index]['query']|{'requestId':id};pending[id]=(index,time.perf_counter(),q);child.stdin.write(json.dumps(q)+'\n')
 child.stdin.flush()
 while pending:
  kind,value=messages.get(timeout=110);assert kind=='result',(kind,value)
  index,t,q=pending.pop(value['requestId']);result=value.get('result',{});record={'caseIndex':index,'query':q,'response':value,'endToEndSeconds':time.perf_counter()-t,'residentBytes':rss()};raw.append(record)
  result=result.get('fuel',{}) if a.hybrid else result
  errors=result.get('errors',[]);ok=not value.get('error') and not errors and result.get('state')=='found'
  proof=hashlib.sha256(json.dumps({'steps':result.get('steps'),'escape':result.get('escape')},sort_keys=True).encode()).hexdigest()
  records.append({'caseIndex':index,'complete':ok,'proof':proof,'endToEndSeconds':record['endToEndSeconds'],'queueSeconds':value.get('queueSeconds'),'executionSeconds':value.get('executionSeconds'),'peakConcurrentRoutingCalls':value.get('peakConcurrentRoutingCalls'),'residentBytes':record['residentBytes']})
 return records
try:
 kind,_=messages.get(timeout=180);assert kind=='ready';report['initializationSeconds']=time.perf_counter()-started;report['initialResidentBytes']=rss();controls=[]
 for index in range(len(cases)):controls+=batch([index])
 report['controls']=controls;assert all(x['complete'] for x in controls),'Control incomplete'
 proofs={x['caseIndex']:x['proof'] for x in controls}
 for level in levels:
  for round_ in range(a.rounds):
   t=time.perf_counter();records=[];indices=list(range(len(cases)));indices=indices[round_:]+indices[:round_]
   for i in range(0,len(indices),level):records+=batch(indices[i:i+level])
   duration=time.perf_counter()-t;entry={'outstanding':level,'round':round_,'seconds':duration,'requestsPerSecond':len(records)/duration,'records':records};report['rounds'].append(entry)
   assert all(x['complete'] and x['proof']==proofs[x['caseIndex']] for x in records),'Concurrent result differs from serial control'
   print(json.dumps({k:v for k,v in entry.items() if k!='records'}),flush=True)
except Exception as ex:report['failure']=repr(ex)
finally:
 child.stdin.close()
 try:child.wait(timeout=5)
 except subprocess.TimeoutExpired:child.terminate();child.wait(timeout=10)
 log.close();report['childExitCode']=child.returncode;out.write_text(json.dumps(report,indent=2))
 with gzip.open(str(out)+'.responses.json.gz','wt') as f:json.dump(raw,f)
print(json.dumps({'failure':report.get('failure'),'rounds':len(report['rounds'])}))
raise SystemExit(bool(report.get('failure')))
