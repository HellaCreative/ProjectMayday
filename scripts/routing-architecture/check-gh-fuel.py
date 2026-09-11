import json,pathlib,subprocess,copy
r=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911');f=r/'data/verified-fixture-no';cmd=['/opt/homebrew/opt/openjdk/bin/java','-Xmx256m','-cp',str(r/'tools/gh-adapter')+':'+str(r/'tools/graphhopper-web-11.0.jar'),'VerifiedHopper',str(f/'verified-input.json'),str(r/'data/gh-verified-fixture-directed-v2-no')]
q={'start':[-63,45],'end':[-62.950002,45.009997],'profile':'distance','fuel':{'usableRangeMeters':3000,'initialUsableMeters':2200},'stations':[{'id':'via','position':[-62.9850006,45.00499916]},{'id':'branch','position':[-62.9599991,45]},{'id':'end','position':[-62.950001,45.009998]}]}
queries=[q,copy.deepcopy(q),copy.deepcopy(q),copy.deepcopy(q)]
queries[1]['fuel']['initialUsableMeters']=1000;queries[2]['excludedStationIds']=['via'];queries[3]['arrivalHistory']={'edges':[0,2]}
p=subprocess.run(cmd,input='\n'.join(json.dumps(x) for x in queries)+'\n',text=True,capture_output=True,timeout=30);(r/'results/gh-fuel-fixture.log').write_text(p.stdout+'\n'+p.stderr)
results=[json.loads(l[7:]) for l in p.stdout.splitlines() if l.startswith('RESULT ')];(r/'results/gh-fuel-fixture.json').write_text(json.dumps(results,indent=2));print(json.dumps(results));assert p.returncode==0 and len(results)==4
assert results[0]['state']=='found',results[0]
assert results[1]['state']=='unreachable' and results[2]['state']=='unreachable',results[1:3]
assert 'Continuation import not yet implemented' in results[3]['error']
x=results[0];remaining=q['fuel']['initialUsableMeters'];keys=[]
for s in x['steps']:
 if 'refill' in s:remaining=3000
 else:
  remaining-=s['meters'];assert remaining>=-1e-6
  if not keys or keys[-1]!=s['sourceKey']:keys.append(s['sourceKey'])
assert abs(remaining-x['remainingUsableMeters'])<1e-6
assert sum(s['meters'] for s in x['escape'])<=remaining+1e-6
assert not any(keys[i:i+3]==[0,2,4] for i in range(len(keys)-2)),keys
print('Fuel, partial start, station exclusion, carried via restriction, and legal escape assertions passed; legacy continuation explicitly unsupported.')
