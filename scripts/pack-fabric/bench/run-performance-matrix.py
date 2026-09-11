"""Sequential paired runs; keep CPU/memory benchmarks from competing."""
import json,pathlib,subprocess,sys,time
cases=json.load(open('docs/experiments/routing-performance-2026-09-10/matrix-inputs.json'))
root=pathlib.Path(sys.argv[1]);root.mkdir(parents=True,exist_ok=True)
phase=int(sys.argv[2]);repeats=sys.argv[3] if len(sys.argv)>3 else '3'
results=[]
for case in cases:
 if case['phase']!=phase:continue
 for variant in (sys.argv[4].split(',') if len(sys.argv)>4 else (['baseline','combined','compact-join'] if phase==4 else ['baseline','combined'])):
  out=root/(case['id']+'-'+variant+'.json')
  if out.exists() and 'runs' in (existing:=json.load(out.open())) and existing['runs'] and 'active' not in existing:
   print('RESUME '+out.name,flush=True);continue
  at=time.monotonic()
  try:
   with (root/(out.stem+'.log')).open('w') as log:
    p=subprocess.run(['node','--expose-gc','scripts/pack-fabric/bench/compare-routing-preparation.js',case['id'],variant,str(out),repeats],stdout=log,stderr=subprocess.STDOUT,timeout=600)
   row=dict(case=case['id'],variant=variant,exit=p.returncode,seconds=round(time.monotonic()-at,1))
  except subprocess.TimeoutExpired:row=dict(case=case['id'],variant=variant,error='600s process limit')
  if out.exists():
   d=json.load(out.open());row['runs']=[dict(complete=r['complete'],ms=round(r['ms']),peakMiB=round(r['peakRoutingMiB'])) for r in d['runs']]
  results.append(row);print(json.dumps(row),flush=True)
  (root/('phase-'+str(phase)+'-progress.json')).write_text(json.dumps(results,indent=2))
