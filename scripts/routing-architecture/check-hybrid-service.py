"""Bounded service cancellation, queue deadlines, overflow and recovery."""
import pathlib,json,subprocess,queue,threading,time
from adapter_identity import ensure_current
r=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911');build_identity=ensure_current(r)
cmd=['/opt/homebrew/opt/openjdk/bin/java','-Ddirt.objectiveLandmarks=true','-Xmx1g','-cp',str(r/'tools/gh-adapter')+':'+str(r/'tools/graphhopper-web-11.0.jar'),'ConcurrentVerifiedHopper',str(r/'data/verified-nsnb/verified-input.json'),str(r/'data/gh-verified-nsnb-directed-v2-objective'),'1']
p=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1);events=queue.Queue();records=[]
def consume():
 for line in p.stdout:
  if line.startswith('READY '):events.put(('READY',{}))
  elif line.startswith(('RESULT ','CONTROL ')):
   kind,value=line.split(' ',1);events.put((kind,json.loads(value)))
 events.put(('EXIT',{}))
threading.Thread(target=consume,daemon=True).start()
q={'start':[-63.340199,44.764804],'end':[-65.244265,47.013162],'profile':'dirt30','hybrid':True,'fuel':{'usableRangeMeters':180000,'initialUsableMeters':90000}}
def send(*items):
 p.stdin.write(''.join(json.dumps(x)+'\n' for x in items));p.stdin.flush()
def terminal(ids,seconds=15):
 found={};deadline=time.monotonic()+seconds
 while set(found)!=set(ids):
  kind,value=events.get(timeout=max(.01,deadline-time.monotonic()));records.append({'kind':kind,'value':value})
  assert kind!='EXIT','service exited'
  if kind=='RESULT':
   assert value['requestId'] in ids and value['requestId'] not in found,value
   found[value['requestId']]=value
 return found
try:
 assert events.get(timeout=30)[0]=='READY'
 send(q|{'requestId':'cancel-running'})
 time.sleep(.05);started=time.monotonic();send({'cancelRequestId':'cancel-running'})
 a=terminal(['cancel-running']);assert a['cancel-running'].get('error')=='cancelled',a
 assert time.monotonic()-started<3,'cancellation did not release promptly'
 send(q|{'requestId':'block'},q|{'requestId':'block'},{'memorySnapshotId':'busy','requestGc':True},q|{'requestId':'expired','timeoutMillis':1},q|{'requestId':'cancel-queued'},{'cancelRequestId':'cancel-queued'})
 a=terminal(['block','expired','cancel-queued']);assert a['block']['result']['state']=='fuel_verified',a
 assert a['expired'].get('error')=='queue_deadline' and a['cancel-queued'].get('error')=='cancelled',a
 send(*[q|{'requestId':f'overflow-{i}','timeoutMillis':1} for i in range(30)])
 a=terminal([f'overflow-{i}' for i in range(30)])
 assert any(v.get('error')=='bounded_queue_full' for v in a.values()),'overflow not exercised'
 send({'requestId':'invalid','hybrid':True,'timeoutMillis':-1},q|{'requestId':'recovered'})
 a=terminal(['recovered']);assert a['recovered']['result']['state']=='fuel_verified','service failed recovery'
 send({'memorySnapshotId':'idle-after-work','requestGc':True})
 while True:
  kind,value=events.get(timeout=10);records.append({'kind':kind,'value':value})
  if value.get('memorySnapshotId')=='idle-after-work':
   assert value.get('explicitGcRequested') and 'resources' in value,value
   break
 assert all(v['value'].get('peakConcurrentRoutingCalls',1)<=1 for v in records),'worker bound exceeded'
 controls=[v['value'] for v in records if v['kind']=='CONTROL']
 assert all(any(v.get('cancelRequestId')==name and v.get('accepted') for v in controls) for name in ['cancel-running','cancel-queued']),controls
 assert any(v.get('error')=='duplicate_request_id' for v in controls),controls
 assert any(v.get('memorySnapshotId')=='busy' and v.get('error')=='service_not_idle' for v in controls),controls
 assert any(v.get('error')=='invalid_request' for v in controls),controls
 print('Running/queued cancellation, queue expiry, duplicate IDs, bounded overflow, invalid input, idle-only GC and recovery passed.')
finally:
 p.stdin.close()
 try:p.wait(10)
 except subprocess.TimeoutExpired:p.terminate();p.wait(10)
 (r/'results/hybrid-service-check.json').write_text(json.dumps(records,indent=2))
