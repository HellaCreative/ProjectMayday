"""Audit unique returned proofs from HTTP load runs against immutable V4 sources."""
import argparse,gzip,hashlib,json,pathlib,subprocess
p=argparse.ArgumentParser();p.add_argument('--out',required=True,type=pathlib.Path);p.add_argument('runs',nargs='+',type=pathlib.Path);a=p.parse_args()
if a.out.exists():raise RuntimeError('Use a new audit receipt')
root=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911');here=pathlib.Path(__file__).resolve().parent
groups={};seen=set();sources=[];mask=(root/'unified-stress/blocked-source-edges.bin').read_bytes();maskChecks=0
for run in a.runs:
 report=json.loads(run.read_text());region='nsnb' if report['dataset']=='nsnb' else 'wv';records=[]
 if 'runs' in report:
  for x in json.load(gzip.open(str(run)+'.responses.json.gz')):
   for candidate in x['result']['candidates']:records.append({'query':x['query']|{'profile':candidate['id']},'result':candidate['route']})
 else:
  for x in json.load(gzip.open(str(run)+'.controls.json.gz')):
   if x['result'].get('route'):
    records.append({'query':x['query']|{'profile':x['result']['selectedCandidateId']},'result':x['result']['route']|{'state':'found'}})
 proofs=pathlib.Path(str(run)+'.candidate-proofs.jsonl.gz')
 if proofs.exists():records.extend(json.loads(x) for x in gzip.open(proofs,'rt') if x.strip())
 sources.append({'run':str(run),'records':len(records),'fullSuccess':report.get('fullSuccess',sum(x['poolComplete'] for x in report.get('runs',[]))),'submitted':report.get('submitted',len(report.get('runs',[])))})
 for x in records:
  q=x['query'];r=x['result'];fuel='remainingUsableMeters' in r and r['remainingUsableMeters'] is not None
  key=hashlib.sha256(json.dumps({'region':region,'fuel':q.get('fuel'),'allowUnknown':q.get('allowUnknown',False),'exclusions':q.get('excludedStationIds',[]),'steps':r.get('steps',r.get('edges')),'escape':r.get('escape'),'remaining':r.get('remainingUsableMeters')},sort_keys=True).encode()).hexdigest()
  if report['dataset']=='strict-wv':
   walk=[*r.get('steps',r.get('edges',[])),*r.get('escape',[])]
   assert all(mask[s['sourceKey']//2]==0 for s in walk if not s.get('refill')),'Blocked source edge in strict returned route'
   maskChecks+=1
  if key in seen:continue
  seen.add(key)
  if not fuel:r=r|{'edges':r.get('edges',r.get('steps'))}
  groups.setdefault((region,'fuel' if fuel else 'road'),[]).append({'query':q|{'allowUnknown':q.get('allowUnknown',False)},'result':r})
checks=[]
for (region,kind),records in groups.items():
 raw=pathlib.Path(str(a.out)+f'.{region}.{kind}.input.json.gz');result=pathlib.Path(str(a.out)+f'.{region}.{kind}.audit.json')
 with gzip.open(raw,'wt') as f:json.dump(records,f)
 joined='/tmp/dirt-prepared-joins/'+('nb+ns' if region=='nsnb' else 'nb+ns+ny+pa+qc+wv')
 command=['node',str(here/f'audit-verified-{kind if kind=="fuel" else "routes"}.js'),joined,str(raw)]
 if kind=='fuel':command.append(str(root/f'data/verified-{region}/stations.json'))
 with result.open('w') as out:rc=subprocess.run(command,stdout=out,timeout=120).returncode
 checks.append({'region':region,'kind':kind,'count':len(records),'returncode':rc,'output':str(result)})
summary={'sources':sources,'checks':checks,'strictMaskProofChecks':maskChecks,'uniqueProofs':len(seen),'passed':bool(seen) and all(x['returncode']==0 for x in checks),'scope':'Continuous V4 road/turn/access and range/refill/escape audits. Physical station entrances remain provisional.'}
a.out.write_text(json.dumps(summary,indent=2));print(json.dumps(summary),flush=True)
raise SystemExit(not summary['passed'])
