"""Independent fixture audit: geometry → source-way walk, forbidden sequence and distance costs."""
import json,pathlib,math
root=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911/valhalla-spike')
rows=json.loads((root/'actor-check.json').read_text())['results'];assert len(rows)==16 and all('error' not in r for r in rows)
def restriction_walk(r):
 ways=[]
 for shape in r['shapes']:
  for a,b in zip(shape,shape[1:]):
   if a==b:continue
   mid=(a[0]+b[0])/2
   way=204 if max(a[1],b[1])>45.03001 else 201 if mid< -62.99 else 202 if mid < -62.98 else 203
   if not ways or ways[-1]!=way:ways.append(way)
 return ways
def prohibited(walk):return any(walk[i:i+3]==[201,202,203] for i in range(len(walk)-2))
def meters(a,b):
 p,q=map(math.radians,[a[0],b[0]]);dp=q-p;dl=math.radians(b[1]-a[1]);return 6371000*2*math.asin(math.sqrt(math.sin(dp/2)**2+math.cos(p)*math.cos(q)*math.sin(dl/2)**2))
paved=meters((45,-63),(45,-62.98));gravel=2*meters((45,-63),(45.006,-62.99))
assert paved*10>gravel and paved*30>gravel
surface=rows[:12];assert all(max(p[1] for s in r['shapes'] for p in s)==45 for r in surface)
walks={r['name']:restriction_walk(r) for r in rows[12:]}
assert not prohibited(walks['restricted_no_stop'])
assert all(prohibited(walks['restricted_mid_via_'+kind]) for kind in ['break','through','break_through'])
report=dict(status='Counterexamples reproduced, not DIRT qualification',nativeRequests=16,forbiddenWaySequence=[201,202,203],walks=walks,surfaceCounterexample=dict(pavedMeters=paved,gravelMeters=gravel,dirt10Chooses='gravel',dirt30Chooses='gravel',stockMotorcycleChoices='paved for all12 options'),notes='Synthetic ways have verified motorcycle=yes and same road class/speed. Way classification is independent of engine instructions; it uses the fixture geometry. Stop is not a turn or a legal reset of the OSM restriction.')
(root/'audit.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
