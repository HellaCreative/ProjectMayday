"""Opt-in portfolio correctness checks on the existing via-way fuel fixture."""
import json,pathlib,subprocess,copy
r=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911')
f=r/'data/verified-fixture-no'
cmd=['/opt/homebrew/opt/openjdk/bin/java','-Xmx256m','-cp',str(r/'tools/gh-adapter')+':'+str(r/'tools/graphhopper-web-11.0.jar'),'VerifiedHopper',str(f/'verified-input.json'),str(r/'data/gh-verified-fixture-directed-v3-no')]
base={'start':[-63,45],'end':[-62.950002,45.009997],'profile':'distance','fuel':{'usableRangeMeters':3000,'initialUsableMeters':2200},'stations':[{'id':'via','position':[-62.9850006,45.00499916]},{'id':'branch','position':[-62.9599991,45]},{'id':'end','position':[-62.950001,45.009998]},{'id':'forbidden-branch','position':[-62.9700012,45.0099983]}]}
portfolio=copy.deepcopy(base);portfolio.update(fuelPortfolio=True,portfolioOnly=True,forceResourceSearch=True)
excluded=copy.deepcopy(portfolio);excluded['excludedStationIds']=['via']
low=copy.deepcopy(portfolio);low['fuel']['initialUsableMeters']=1000
queries=[base,portfolio,excluded,low]
p=subprocess.run(cmd,input='\n'.join(map(json.dumps,queries))+'\n',text=True,capture_output=True,timeout=60)
(r/'results/gh-portfolio-fixture.log').write_text(p.stdout+'\n'+p.stderr)
results=[json.loads(x[7:]) for x in p.stdout.splitlines() if x.startswith('RESULT ')]
(r/'results/gh-portfolio-fixture.json').write_text(json.dumps(results,indent=2))
assert p.returncode==0 and len(results)==4
ref,result=results[:2]
assert result['state']=='found' and result['reason']=='scalar_portfolio_fixed_path_certificate'
assert len(result['portfolio'])==7 and all(x['complete'] for x in result['portfolio'])
assert abs(result['weight']-ref['weight'])<1e-6, 'Final score must exclude search penalty'
assert abs(result['distance']-ref['distance'])<1e-6
keys=[];remaining=2200
for step in result['steps']:
 if 'refill' in step:remaining=3000
 else:
  remaining-=step['meters'];assert remaining>=-1e-6
  if not keys or keys[-1]!=step['sourceKey']:keys.append(step['sourceKey'])
assert not any(keys[i:i+3]==[0,2,4] for i in range(len(keys)-2)),keys
assert abs(remaining-result['remainingUsableMeters'])<1e-6
assert sum(x['meters'] for x in result['escape'])<=remaining+1e-6
for x in results[2:]:assert x['state']=='incomplete' and x['reason']=='portfolio_no_certificate',x
print('Portfolio: original objective, seven scalar candidates, carried via history, fuel accounting, escape, station exclusion, partial start and honest incomplete status passed.')
