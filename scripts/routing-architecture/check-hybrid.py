"""Local hybrid boundary regression: fuel failure must preserve only an unverified road."""
import json,pathlib,subprocess
r=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911')
q={'start':[-63,45],'end':[-62.950002,45.009997],'profile':'dirt10','stations':[{'id':'via','position':[-62.9850006,45.00499916]},{'id':'branch','position':[-62.9599991,45]},{'id':'end','position':[-62.950001,45.009998]}]}
queries=[q,q|{'fuel':{'usableRangeMeters':3000,'initialUsableMeters':2200}},q|{'fuel':{'usableRangeMeters':1,'initialUsableMeters':1}},q|{'arrivalHistory':{'edges':[0,2]}}]
cp=str(r/'tools/gh-adapter')+':'+str(r/'tools/graphhopper-web-11.0.jar')
p=subprocess.run(['/opt/homebrew/opt/openjdk/bin/java','-Xmx256m','-cp',cp,'HybridHopper',str(r/'data/verified-fixture-no/verified-input.json'),str(r/'data/gh-verified-fixture-directed-v3-no')],input='\n'.join(map(json.dumps,queries))+'\n',text=True,capture_output=True,timeout=30)
a=[json.loads(x[7:]) for x in p.stdout.splitlines() if x.startswith('RESULT ')]
assert p.returncode==0 and len(a)==4,(p.stderr,a)
assert a[0]['state']=='road_only' and a[0]['fuel']['status']=='not_requested'
assert a[1]['state']=='fuel_verified' and a[1]['fuel']['state']=='found'
assert a[2]['state']=='fuel_unresolved' and a[2]['road']['state']=='found' and a[2]['road']['fuelStatus']=='unverified'
assert a[2]['navigationReady'] is False and a[2]['fuel']['state']=='incomplete'
assert a[3]['state']=='error' and 'history' in a[3]['error']
(r/'results/hybrid-boundary-fixture.json').write_text(json.dumps(a,indent=2))
print('Hybrid boundary: road-only, verified fuel, unresolved fuel with retained road, and refusal to discard arrival history passed.')
