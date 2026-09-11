"""A bounded, sequential native preparation/fuel integration matrix."""
import argparse, pathlib, json, subprocess, os, hashlib
p=argparse.ArgumentParser();p.add_argument('--binary',type=pathlib.Path,required=True);p.add_argument('--pack',type=pathlib.Path,required=True);p.add_argument('--roads',type=pathlib.Path,required=True);p.add_argument('--out',type=pathlib.Path,required=True);a=p.parse_args()
if a.out.exists():raise RuntimeError('Use a new output directory')
a.out.mkdir(parents=True)
here=pathlib.Path(__file__).resolve().parent;guard=here.parents[1]/'guarded-run.py'
base={'start':[-63.34024,44.76481],'end':[-62.18066,45.3933],'profile':'cleanest','rangeMeters':193121.28,'firstMeters':193121.28,'profileMeters':194531.995,'minimumStops':1}
cases=[
 ('matching-indexed','indexed','--matches',{'profile':'cleanest','passes':2},20),
 ('matching-cached','cached','--matches',{'profile':'cleanest','passes':2},20),
 ('matching-eviction','cached','--matches',{'profile':'cleanest','passes':2},20),
 ('matching-cancel-recover','cached','--matches',{'profile':'cleanest','passes':1,'cancelFirstSeconds':0.02},20),
 ('road-controls','cached','--roads',json.loads(a.roads.read_text()),90),
 ('clean-120-a','cached',None,base,30),
 ('clean-120-b','cached',None,base,30),
 ('clean-direct-control','cached',None,base,30),
 ('dirt-120','cached',None,{**base,'profile':'dirt','profileMeters':202314},30),
 ('balanced-120','cached',None,{**base,'profile':'balanced','profileMeters':187998},30),
 ('clean-first-50','cached',None,{**base,'firstMeters':50000},30),
 ('fuel-cancel','cached',None,base,0.02),
]
receipt={'binary':str(a.binary),'binarySHA256':hashlib.sha256(a.binary.read_bytes()).hexdigest(),'matrixScriptSHA256':hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),'pack':str(a.pack),'cases':[],'scope':'Local macOS only. Fresh processes, operating-system file caches uncontrolled; serial timings are not hosted or iPhone capacity.'}
for name,mode,diagnostic,spec,budget in cases:
 file=a.out/(name+'.input.json');file.write_text(json.dumps(spec))
 env={**os.environ,'DIRT_FUEL_PREPARATION':mode,'DIRT_FUEL_CACHE_LIMIT':'64' if name=='matching-eviction' else '1024'}
 env['DIRT_FUEL_SKIP_UNUSED_DIRECT']='0' if name=='clean-direct-control' else '1'
 output=a.out/(name+'.guard.json')
 command=['python3',str(guard),'--out',str(output),'--seconds',str(int(budget)+10),'--rss-mib','512','--',str(a.binary)]
 if diagnostic:command.append(diagnostic)
 command += [str(a.pack),str(file),str(budget)]
 result=subprocess.run(command,env=env,capture_output=True,text=True)
 rows=[]
 for line in output.with_suffix('.log').read_text().splitlines():
  try:rows.append(json.loads(line))
  except json.JSONDecodeError:pass
 phases=[x for x in rows if x.get('stage')!='match']
 summary={'name':name,'returncode':result.returncode,'guard':json.loads(output.read_text()),'phases':phases}
 receipt['cases'].append(summary)
 (a.out/'matrix.json').write_text(json.dumps(receipt,indent=2))
 last=next((x for x in reversed(rows) if x.get('stage') in ['result','pass','preparation']),{})
 print(json.dumps({'case':name,'rc':result.returncode,'stage':last.get('stage'),'state':last.get('state'),'seconds':last.get('seconds'),'resources':last.get('resources'),'guardFailure':summary['guard']['guardFailure']}),flush=True)
 if result.returncode:raise SystemExit(result.returncode)
