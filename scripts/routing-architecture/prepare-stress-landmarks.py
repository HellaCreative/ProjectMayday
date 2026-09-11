"""Clone an isolated engine artifact; prepare stronger pinned-mask LM guidance."""
import pathlib,shutil,hashlib,json,subprocess
from adapter_identity import ensure_current
r=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911')
build_identity=ensure_current(r)
source=r/'data/gh-verified-wv-directed-v2';target=r/'data/gh-verified-wv-strict-lm-km-v2';descriptor=r/'data/verified-wv/verified-input.json';mask=r/'unified-stress/blocked-source-edges.bin'
if target.exists():raise RuntimeError('Existing candidate must be preserved; refuse implicit overwrite')
if shutil.disk_usage(r).free<8*1024**3:raise RuntimeError('Require copy space plus reserve')
shutil.copytree(source,target)
for name in ['landmarks_distance','landmarks_subnetwork_distance']:(target/name).unlink()
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
identity='directed-v2-loop-stress-lm-km:'+sha(mask)+':'+sha(descriptor)
(target/'dirt-input.identity').write_text(identity)
cmd=['/opt/homebrew/opt/openjdk/bin/java','-Ddirt.stressMask='+str(mask),'-Ddirt.stressLandmarks=true','-Xmx2g','-cp',str(r/'tools/gh-adapter')+':'+str(r/'tools/graphhopper-web-11.0.jar'),'VerifiedHopper',str(descriptor),str(target)]
receipt={'buildIdentitySha256':build_identity,'source':str(source),'target':str(target),'identity':identity,'command':cmd,'scope':'Private GH search-guidance preparation from an isolated copy; no source packs or source graph modified.'}
(r/'results/hybrid-strict-lm-km-recipe.json').write_text(json.dumps(receipt,indent=2))
p=subprocess.run(cmd,input='',text=True)
receipt['returncode']=p.returncode
unchanged=['nodes','edges','geometry','turn_costs','location_index','edgekv_keys','edgekv_vals','dirt-loop-tails.json']
receipt['baseFileChecks']={name:{'sourceSha256':sha(source/name),'targetSha256':sha(target/name)} for name in unchanged}
assert all(v['sourceSha256']==v['targetSha256'] for v in receipt['baseFileChecks'].values()),'Preparation changed cloned topology'
(r/'results/hybrid-strict-lm-km-recipe.json').write_text(json.dumps(receipt,indent=2))
raise SystemExit(p.returncode)
