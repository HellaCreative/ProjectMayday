"""Check cost normalization against the existing directed-turn/fuel fixture."""
import gzip,hashlib,json,pathlib,shutil,subprocess
from adapter_identity import ensure_current
r=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911');build=ensure_current(r)
descriptor=r/'data/verified-fixture-no/verified-input.json'
source=r/'data/gh-verified-fixture-directed-v3-no';target=r/'data/gh-verified-fixture-objective-km-v1'
out=r/'results/hybrid-objective-km-fixture.json'
if target.exists() or out.exists():raise RuntimeError('Preserve earlier fixture evidence')
shutil.copytree(source,target)
for p in target.glob('landmarks_*'):p.unlink()
(target/'dirt-input.identity').write_text('directed-v2-loop-objective-lm-km:'+hashlib.sha256(descriptor.read_bytes()).hexdigest())
walks=json.loads(descriptor.with_name('walk-checks.json').read_text())
base={'start':[-63,45],'end':[-62.950002,45.009997]}
stations=[{'id':'via','position':[-62.9850006,45.00499916]},{'id':'branch','position':[-62.9599991,45]},{'id':'end','position':[-62.950001,45.009998]}]
queries=walks[:]
for profile in ['distance','paved','dirt10','dirt30']:
 for flexible in [False,True]:queries.append(base|{'profile':profile,'flexible':flexible})
 for fuel in [{'usableRangeMeters':3000,'initialUsableMeters':2200},{'usableRangeMeters':1,'initialUsableMeters':1}]:
  queries.append(base|{'profile':profile,'stations':stations,'fuel':fuel,'fuelRepair':True,'refineFuelRepair':True,'fuelPortfolio':True,'hybrid':True})
def run(graph,flags):
 cmd=['/opt/homebrew/opt/openjdk/bin/java','-Xmx256m',*flags,'-cp',str(r/'tools/gh-adapter')+':'+str(r/'tools/graphhopper-web-11.0.jar'),'VerifiedHopper',str(descriptor),str(graph)]
 p=subprocess.run(cmd,input='\n'.join(map(json.dumps,queries))+'\n',text=True,capture_output=True,timeout=45)
 rows=[json.loads(x[7:]) for x in p.stdout.splitlines() if x.startswith('RESULT ')]
 assert p.returncode==0 and len(rows)==len(queries),(p.returncode,p.stderr,rows)
 return rows
old=run(source,[]);new=run(target,['-Ddirt.objectiveLandmarks=true','-Ddirt.objectiveLandmarkKilometers=true'])
checks=[]
for q,a,b in zip(queries,old,new):
 assert 'error' not in a and 'error' not in b,(q,a,b)
 if 'walk' in q:assert a['accepted']==b['accepted']==q['accepted']
 else:
  assert a.get('state')==b.get('state') and a.get('errors',[])==b.get('errors',[]),(q,a,b)
  for key in ['distance','weight','remainingUsableMeters']:
   if isinstance(a.get(key),(float,int)):assert abs(a[key]-b[key])<1e-5,(q,key,a[key],b[key])
  for key in ['edges','steps','escape','escapeStation','points']:assert a.get(key)==b.get(key),(q,key)
 checks.append({'query':q,'exactProof':True})
out.write_text(json.dumps({'buildIdentity':build,'checks':checks,'count':len(checks),'state':'passed'},indent=2))
with gzip.open(str(out)+'.raw.json.gz','wt') as f:json.dump({'queries':queries,'baseline':old,'kilometers':new},f)
print(json.dumps({'state':'passed','count':len(checks),'exactGeometryAndFuel':True}),flush=True)
