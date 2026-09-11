"""Actual protected private HTTP requests; no hosted resource configuration changes."""
import gzip,hashlib,json,pathlib,subprocess,sys,time
case_id,variant=sys.argv[1:3]
root=pathlib.Path('/tmp/dirt-performance-hosted');root.mkdir(exist_ok=True)
cases=json.load(open('docs/experiments/routing-performance-2026-09-10/matrix-inputs.json'))
fixture=next(c for c in cases if c['id']==case_id)
deployment=json.load(open('/tmp/dirt-performance-private-'+variant+'-deploy.json'))['deployment']
report=dict(case=case_id,variant=variant,deployment=deployment,runs=[])
def save(): (root/(case_id+'-'+variant+'.json')).write_text(json.dumps(report,indent=2))
for run in range(int(sys.argv[3]) if len(sys.argv)>3 else 3):
 request=json.loads(json.dumps(fixture['request']));history=[];excluded=[];windows=[];complete=False
 for window in range(24):
  stem=root/(case_id+'-'+variant+'-'+str(run)+'-'+str(window));inp=pathlib.Path(str(stem)+'.request.json');out=pathlib.Path(str(stem)+'.response.json');headers=pathlib.Path(str(stem)+'.headers.txt')
  inp.write_text(json.dumps(request));at=time.monotonic()
  args=['vercel','curl','/api/fuel-chain' if request.get('fuel') else '/api/route','--deployment',deployment['url'],'--','--silent','--show-error','--max-time','310','--request','POST','--header','Content-Type: application/json','--data-binary','@'+str(inp),'--output',str(out),'--dump-header',str(headers),'--write-out','%{http_code} %{time_total}']
  p=subprocess.run(args,cwd='scripts/pack-fabric',capture_output=True,text=True,timeout=330)
  try:r=json.load(out.open())
  except Exception:r={'status':'invalid_response','error':out.read_text()[:400] if out.exists() else p.stderr[-400:]}
  routes=r.get('routes') or ([r] if r.get('segments') else [])
  proof={k:r.get(k) for k in ['status','error','windowComplete','stops','destinationEscapeMeters','fuelAccessEvidence']}
  proof['routes']=[{k:x.get(k) for k in ['distanceMeters','segments','stats']} for x in routes]
  checks={'continuous':True,'access':True,'range':True};prev=None
  for i,route in enumerate(routes):
   if request.get('fuel'):assert route['distanceMeters']<=request['fuel']['firstLegMaxMeters' if i==0 else 'usableRangeMeters']+1
   for s in route.get('segments',[]):
    if prev:assert all(abs(a-b)<1e-7 for a,b in zip(prev['geometry'][-1],s['geometry'][0]))
    assert s.get('accessClass') not in ['motorized_denied','motorized_impassable']
    if not request.get('accessPolicy',{}).get('motorizedUnknown'):assert s.get('accessClass')!='motorized_unknown'
    prev=s
  if request.get('fuel') and r.get('status')=='complete' and r.get('windowComplete'):
   available=request['fuel']['firstLegMaxMeters' if len(routes)==1 else 'usableRangeMeters']
   assert isinstance(r.get('destinationEscapeMeters'),(int,float)) and routes[-1]['distanceMeters']+r['destinationEscapeMeters']<=available+1
  diag=r.get('diagnostics') or r.get('debug',{}).get('diagnostics',{})
  windows.append(dict(window=window,http=p.stdout.strip(),wallSeconds=time.monotonic()-at,status=r.get('status'),error=r.get('error'),debug=r.get('debug'),diagnostics=diag,checks=checks if r.get('status')=='complete' else None,meters=sum(x['distanceMeters'] for x in routes),stops=len(r.get('stops',[])),signature=hashlib.sha256(json.dumps(proof,sort_keys=True,separators=(',',':')).encode()).hexdigest()))
  with gzip.open(str(stem)+'.proof.json.gz','wt') as f:json.dump(proof,f,separators=(',',':'))
  report['active']=windows;save()
  if r.get('status')!='complete':break
  if not request.get('fuel') or r.get('windowComplete'):complete=True;break
  assert r.get('stops')
  for route in routes:
   for s in route.get('segments',[]):
    history=[h for h in history if h['id']!=s['edgeId']]+[dict(id=s['edgeId'],meters=max(1,s['distanceMeters']))]
    while len(history)>1 and (len(history)>256 or sum(h['meters'] for h in history)>30000):history.pop(0)
  for s in r['stops']:assert s['id'] not in excluded;excluded.append(s['id'])
  last=r['stops'][-1];request['locations'][0]={k:last[k] for k in ['lat','lon']}
  request.setdefault('options',{}).update(priorEdgeIds=[h['id'] for h in history],arrivalEdgeId=history[-1]['id'])
  request['fuel'].update(firstLegMaxMeters=request['fuel']['usableRangeMeters'],excludedStationIds=excluded,windowMaxStops=1,forwardFeeler=True)
 report.pop('active',None);report['runs'].append(dict(run=run,complete=complete,windows=windows));save()
 print(json.dumps(dict(case=case_id,variant=variant,run=run,complete=complete,wallSeconds=sum(w['wallSeconds'] for w in windows),serverMs=sum((w.get('debug') or {}).get('adventureTotalMs',0) for w in windows))),flush=True)
 if not complete:break
