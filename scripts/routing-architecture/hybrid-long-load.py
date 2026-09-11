"""One long-route control and two concurrent replays, with a shared graph."""
import pathlib,json,gzip,subprocess,threading,queue,time,hashlib,argparse
from adapter_identity import ensure_current
r=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911');build_identity=ensure_current(r)
p=argparse.ArgumentParser();p.add_argument('--out',default=str(r/'results/hybrid-wv-load.json'));p.add_argument('--artifact',default=str(r/'data/gh-verified-wv-directed-v2'));a=p.parse_args();out=pathlib.Path(a.out)
if out.exists():raise RuntimeError('Preserve prior evidence; use a new output identity')
q={'start':[-63.34018,44.76481],'end':[-80.19745,38.99357],'profile':'dirt30','allowUnknown':False,'hybrid':True,'fuel':{'usableRangeMeters':193121.28,'initialUsableMeters':193121.28}}
cmd=['/opt/homebrew/opt/openjdk/bin/java','-Xmx2g','-cp',str(r/'tools/gh-adapter')+':'+str(r/'tools/graphhopper-web-11.0.jar'),'ConcurrentVerifiedHopper',str(r/'data/verified-wv/verified-input.json'),a.artifact,'2']
child=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1);messages=queue.Queue();log=out.with_suffix('.log').open('w');rows=[];report={'buildIdentitySha256':build_identity,'command':cmd,'query':q,'workers':2,'clientCounts':[1,2],'runs':[]}
def consume():
 for line in child.stdout:
  if line.startswith('READY '):messages.put(('ready',None))
  elif line.startswith('RESULT '):messages.put(('result',json.loads(line[7:])))
  else:log.write(line);log.flush()
 messages.put(('exit',child.poll()))
threading.Thread(target=consume,daemon=True).start()
try:
 assert messages.get(timeout=180)[0]=='ready'
 expected=None
 for count in [1,2]:
  started=time.perf_counter()
  for i in range(count):child.stdin.write(json.dumps(q|{'requestId':f'{count}-{i}'})+'\n')
  child.stdin.flush()
  for _ in range(count):
   kind,value=messages.get(timeout=110);assert kind=='result',(kind,value)
   envelope=value.get('result',{});result=envelope.get('fuel',{});rows.append({'query':q,'result':result,'response':value})
   proof=hashlib.sha256(json.dumps({'steps':result.get('steps'),'escape':result.get('escape')},sort_keys=True).encode()).hexdigest()
   if expected is None:expected=proof
   row={'clients':count,'state':envelope.get('state'),'seconds':value.get('executionSeconds'),'queueSeconds':value.get('queueSeconds'),'peakActive':value.get('peakConcurrentRoutingCalls'),'proofMatchesControl':proof==expected};report['runs'].append(row);print(json.dumps(row),flush=True)
   assert envelope.get('state')=='fuel_verified' and proof==expected,row
except Exception as ex:report['failure']=repr(ex)
finally:
 child.stdin.close()
 try:child.wait(10)
 except subprocess.TimeoutExpired:child.terminate();child.wait(10)
 log.close();out.write_text(json.dumps(report,indent=2))
 with gzip.open(str(out)+'.responses.json.gz','wt') as f:json.dump(rows,f)
raise SystemExit(bool(report.get('failure')))
