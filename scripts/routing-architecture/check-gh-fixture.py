import json,pathlib,subprocess,sys
r=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911');variant=sys.argv[1] if len(sys.argv)>1 else 'no';f=r/('data/verified-fixture-'+variant);checks=json.loads((f/'walk-checks.json').read_text())
cmd=['/opt/homebrew/opt/openjdk/bin/java','-Xmx256m','-cp',str(r/'tools/gh-adapter')+':'+str(r/'tools/graphhopper-web-11.0.jar'),'VerifiedHopper',str(f/'verified-input.json'),str(r/('data/gh-verified-fixture-directed-v2-'+variant))]
queries=checks+[{'start':[-63,45],'end':[-62.950002,45.009997],'profile':'dirt10','flexible':True}]
queries += [{'start':[-63,45],'end':[-62.9850006,45.00499916],'profile':'distance','flexible':True},{'start':[-62.9850006,45.00499916],'end':[-63,45],'profile':'distance','flexible':True}]
p=subprocess.run(cmd,input='\n'.join(json.dumps(c) for c in queries)+'\n',text=True,capture_output=True,timeout=30)
(r/('results/gh-fixture-'+variant+'.log')).write_text(p.stdout+'\n'+p.stderr)
results=[json.loads(l[7:]) for l in p.stdout.splitlines() if l.startswith('RESULT ')]
assert p.returncode==0,(p.returncode,p.stderr)
assert len(results)==len(queries),(len(results),len(queries))
errors=[{'input':c,'actual':a} for c,a in zip(checks,results) if c['accepted']!=a.get('accepted')]
report={'walks':len(checks),'mismatches':errors,'routes':results[len(checks):]};(r/('results/gh-fixture-check-'+variant+'.json')).write_text(json.dumps(report,indent=2));print(json.dumps(report));assert not errors
for x in results[-2:]:assert not x.get('errors') and abs(x['distance']-2043)<1,x
