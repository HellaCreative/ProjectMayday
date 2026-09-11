"""Bind the native response to actual traced routes, then run the Swift witness.

A complete native response alone is not proof of physical fuel access or of the
legal continuation between its independently searched legs.
"""
import argparse, hashlib, json, pathlib, subprocess
p=argparse.ArgumentParser()
p.add_argument('--binary',required=True,type=pathlib.Path)
p.add_argument('--pack',required=True,type=pathlib.Path)
p.add_argument('--spec',required=True,type=pathlib.Path)
p.add_argument('--log',required=True,type=pathlib.Path)
p.add_argument('--out',required=True,type=pathlib.Path)
a=p.parse_args()
rows=[]
for line in a.log.read_text().splitlines():
 try: rows.append(json.loads(line))
 except json.JSONDecodeError: pass
spec=json.loads(a.spec.read_text())
end=next((x for x in reversed(rows) if x.get('stage')=='result'),{})
response=end.get('nativeResponse',{})
def incomplete(reason):
 result={'accepted':False,'state':'incomplete','errors':[reason]}
 a.out.write_text(json.dumps(result,indent=2));print(json.dumps(result));raise SystemExit(0)
if end.get('timeBudgetExpired') or response.get('status')!='complete' or response.get('windowComplete') is not True:
 incomplete('no_complete_native_candidate')
refills=[{'id':x['id'],'point':[x['lon'],x['lat']]} for x in response['stops']]
locations=[spec['start'],*[x['point'] for x in refills],spec['end']]
distances=response.get('graphMeters',[])
if len(distances)!=len(locations)-1:incomplete('missing_route_distances')
routes=[]
for start,finish,distance in zip(locations,locations[1:],distances):
 matches=[x for x in rows if x.get('stage')=='road' and x.get('state')=='found' and not x.get('searchTimedOut')
          and x.get('query',{}).get('start')==start and x.get('query',{}).get('end')==finish and x.get('distanceMeters')==distance]
 if not matches or len({json.dumps(x['legs'],sort_keys=True) for x in matches})!=1:incomplete('missing_or_ambiguous_selected_road_witness')
 routes.append(matches[-1])
sha=lambda x:hashlib.sha256(x).hexdigest()
payload={'packIdentity':sha((a.pack/'graph.v4.bin').read_bytes()+(a.pack/'geometry.v1.bin').read_bytes()),
         'fuelIdentity':sha((a.pack/'fuel.v1.json').read_bytes()),'profile':spec['profile'],'allowUnknown':False,
         'rangeMeters':spec['rangeMeters'],'firstMeters':spec['firstMeters'],'minimumStops':spec.get('minimumStops',1),
         'excludedStationIds':spec.get('excludedStationIds',[]),'start':spec['start'],'end':spec['end'],'routes':routes,'refills':refills}
input_file=a.out.with_suffix('.input.json');input_file.write_text(json.dumps(payload))
run=subprocess.run([str(a.binary),'--audit',str(a.pack),str(input_file)],capture_output=True,text=True,timeout=30,check=True)
result=json.loads(run.stdout.strip().splitlines()[-1]);result['selectedTraces']=[x['trace'] for x in routes]
result['nativeSearchSeconds']=end['seconds'];result['refills']=refills
a.out.write_text(json.dumps(result,indent=2))
print(json.dumps(result))
