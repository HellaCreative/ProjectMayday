"""Assertions for the tiny P gate and bounded fixed-itinerary fuel certificate.
Consumes native outputs and independent V4 walk validation; no engine work.
"""
import json,pathlib,math
root=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911/osrm-spike')
raw=json.loads((root/'results.json').read_text());audit=json.loads((root/'v4-audit.json').read_text())
rows={(r['metric'],r['case']):r for r in raw['results']}
def route(metric,case):return rows[metric,case]['response']['routes'][0]
def ids(metric,case):return route(metric,case)['legs'][0]['annotation']['nodes']
checks=[]
for metric in sorted({k[0] for k in rows}):
 expected=[1,4,3] if metric in ['dirt10-1','dirt30-1'] else [1,2,3]
 assert ids(metric,'surface')==expected
 assert ids(metric,'unknown-off')==[21,24,23]
 assert ids(metric,'denied')==[31,34,33]
 assert rows[metric,'reverse-denied']['response']['code']=='NoRoute'
 assert ids(metric,'via-whole')==[11,12,13,15,14]
 assert math.isclose(route(metric,'via-whole')['distance'],route(metric,'via-stop')['distance'],abs_tol=.1)
 assert ids(metric,'via-resume')==[12,13,14] and ids(metric,'via-resume-bearing')==[12,13,14]
 assert next(x for x in audit if x['metric']==metric and x['case']=='via-stop')['legal']
 assert next(x for x in audit if x['metric']==metric and x['case']=='via-offroad-stop')['legal']
 assert route(metric,'via-offroad-stop')['geometry']==route(metric,'via-stop')['geometry']
 assert 2 < rows[metric,'via-offroad-stop']['response']['waypoints'][1]['distance'] < 3
 assert not next(x for x in audit if x['metric']==metric and x['case']=='separate-call-concatenation')['legal']
 if metric.startswith('dirt'):assert ids(metric,'unknown-on')==[21,22,23]
 checks.append({'metric':metric,'surfaceChoice':expected,'accessAndDirection':True,'singleRequestViaContinuity':True,'separateCallsRetainHistory':False})
# Full-route re-query keeps restriction state and proves this fixed itinerary only.
# The destination is itself a station, hence its escape distance is zero.
def fixed_itinerary(initial,full,excluded=False):
 r=route('dirt10-1','via-whole' if excluded else 'via-stop');remaining=initial;steps=[];accepted=True
 for i,leg in enumerate(r['legs']):
  remaining-=leg['distance'];steps.append({'roadMeters':leg['distance'],'remainingBeforeRefill':remaining})
  if remaining < -.1:accepted=False;break
  if not excluded and i<len(r['legs'])-1:remaining=full;steps[-1]['refill']='mid-via'
 return {'proven':accepted,'initialUsableMeters':initial,'fullUsableMeters':full,'pumpExcluded':excluded,'steps':steps,'remainingUsableMeters':remaining,'destinationEscapeMeters':0,'scope':'Only supplied fixed itinerary and destination at a known station; no completeness or alternative fuel-route claim'}
cases=[fixed_itinerary(250,1000),fixed_itinerary(200,1000),fixed_itinerary(250,1000,True),fixed_itinerary(250,300)]
assert [x['proven'] for x in cases]==[True,False,False,False]
naive=[route('dirt10-1',c)['distance'] for c in ['via-arrive','via-resume']]
assert naive[0]<250 and naive[1]<300
result={'nativeQueries':len(raw['results']),'checks':checks,'fuelCases':cases,'falsePositiveAvoided':{'independentLegMeters':naive,'passesNaiveRangeCheck':True,'failsV4TurnHistory':True},'fixtureSha256':raw['fixtureSha256'],'profileSha256':raw['profileSha256']}
(root/'checks.json').write_text(json.dumps(result,indent=2));print(json.dumps(result))
