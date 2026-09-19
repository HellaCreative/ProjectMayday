#!/usr/bin/env python3
"""Serial, resumable local-pack routing qualification. Case files contain explicit
endpoints/pack chains; every result retains input settings and source identity.
No server routing, pack mutation, simulator creation, or label-budget inflation.
"""
import argparse, hashlib, json, os, platform, re, signal, subprocess, time
from pathlib import Path

p=argparse.ArgumentParser()
p.add_argument('probe',type=Path); p.add_argument('packs',type=Path)
p.add_argument('cases',type=Path); p.add_argument('output',type=Path)
p.add_argument('--styles',default='dirt,balanced,cleanest')
p.add_argument('--only',default=''); p.add_argument('--wander',type=float,default=.5)
p.add_argument('--unknown',action='store_true'); p.add_argument('--seed',type=int,default=1)
a=p.parse_args(); a.output.mkdir(parents=True,exist_ok=True)
probe=a.probe.resolve(); packs=a.packs.resolve()
def git(*args):
 return subprocess.check_output(['git',*args],text=True).strip()
identity={'source':git('rev-parse','HEAD'),'sourceDiffSHA256':hashlib.sha256(git('diff').encode()).hexdigest(),
 'probeSHA256':hashlib.sha256(probe.read_bytes()).hexdigest(),
 'harnessSHA256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
 'caseFileSHA256':hashlib.sha256(a.cases.read_bytes()).hexdigest(),'hardware':platform.platform(),
 'cpu':subprocess.check_output(['sysctl','-n','machdep.cpu.brand_string'],text=True).strip(),
 'memoryBytes':int(subprocess.check_output(['sysctl','-n','hw.memsize'],text=True)),
 'windowSeconds':60,'maximumLabels':1600000,'wander':a.wander,'allowUnknown':a.unknown,
 'avoidHighways':True,'avoidCities':True,'seed':a.seed,'fuelRouting':False}
identityPath=a.output/'identity.json'
if identityPath.exists() and json.loads(identityPath.read_text()) != identity:
 raise SystemExit('Output identity changed; use a new output directory, never mix candidates.')
identityPath.write_text(json.dumps(identity,indent=2))
data=json.loads(a.cases.read_text());cases=data.get('cases',data) if isinstance(data,dict) else data
for case in cases:
 if a.only and not re.search(a.only,case['id']): continue
 for style in a.styles.split(','):
  key=case['id']+'-'+style
  resultPath=a.output/(key+'.json')
  if resultPath.exists(): continue
  raw=a.output/(key+'.raw.json'); timing=a.output/(key+'.time')
  command=[str(probe),str(packs),','.join(case['regions']),*map(str,case['from']),*map(str,case['to']),
    style,'60',str(a.seed),str(case.get('zoom','-'))]
  env=dict({k:v for k,v in os.environ.items() if not k.startswith('DIRT_')},DIRT_PROBE_COMPACT='1',DIRT_MAX_LABELS='1600000',DIRT_WANDER=str(a.wander),DIRT_ALLOW_UNKNOWN=str(int(a.unknown)))
  began=time.monotonic(); timedOut=False
  with raw.open('w') as output,timing.open('w') as errors:
   proc=subprocess.Popen(['/usr/bin/time','-l',*command],stdout=output,stderr=errors,env=env,start_new_session=True)
   try:code=proc.wait(timeout=60*max(1,len(case['regions'])-1)+45)
   except subprocess.TimeoutExpired:
    timedOut=True;os.killpg(proc.pid,signal.SIGTERM)
    try: code=proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
     os.killpg(proc.pid,signal.SIGKILL);code=proc.wait()
  try: result=json.loads(raw.read_text())
  except (ValueError,OSError): result={'status':'failed','error':'harness deadline' if timedOut else 'probe exited without receipt'}
  match=re.search(r'(\d+)\s+maximum resident set size',timing.read_text())
  record={'case':case,'style':style,'settings':identity,'exitCode':code,'wallSeconds':time.monotonic()-began,
    'peakResidentBytes':int(match[1]) if match else None,'result':result,
    'packManifests':[json.loads((packs/r/'pack-manifest.v2.json').read_text()) for r in case['regions']]}
  footprint=re.search(r'(\d+)\s+peak memory footprint',timing.read_text())
  record['peakFootprintBytes']=int(footprint[1]) if footprint else None
  resultPath.write_text(json.dumps(record,indent=2))
  print(key,result.get('status'),result.get('error',result.get('limit')),round(record['wallSeconds'],2),flush=True)
