"""Prepare four cost-specific indexes from a private graph copy, one process each."""
import argparse,hashlib,json,pathlib,shutil,subprocess,sys,time
from adapter_identity import ensure_current

p=argparse.ArgumentParser()
for name in ['source','target','descriptor','out']:p.add_argument('--'+name,required=True,type=pathlib.Path)
a=p.parse_args();root=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911')
here=pathlib.Path(__file__).resolve().parent
if a.target.exists() or a.out.exists():raise RuntimeError('Refuse to overwrite a prepared artifact or receipt')
if shutil.disk_usage(root).free<8*1024**3:raise RuntimeError('Require copy space plus reserve')
def sha(path):
 with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
build=ensure_current(root)
files=['nodes','edges','geometry','turn_costs','location_index','edgekv_keys','edgekv_vals','dirt-loop-tails.json']
before={name:sha(a.source/name) for name in files}
shutil.copytree(a.source,a.target)
for item in a.target.glob('landmarks_*'):item.unlink()
identity='directed-v2-loop-objective-lm-km:'+sha(a.descriptor)
(a.target/'dirt-input.identity').write_text(identity)
receipt={'source':str(a.source),'target':str(a.target),'descriptor':str(a.descriptor),'identity':identity,'buildIdentity':build,'stages':[],
 'scope':'Isolated search-guidance files only. Identical graph geometry, topology and turns; cost unit divided by1000 for landmark storage. Per-objective lower bounds retain all legal request roads.'}
def save():a.out.write_text(json.dumps(receipt,indent=2))
save()
for profile in ['distance','paved','dirt10','dirt30']:
 command=['/opt/homebrew/opt/openjdk/bin/java','-Xmx2g','-Ddirt.objectiveLandmarks=true','-Ddirt.objectiveLandmarkKilometers=true','-Ddirt.prepareProfile='+profile,
  '-cp',str(root/'tools/gh-adapter')+':'+str(root/'tools/graphhopper-web-11.0.jar'),'VerifiedHopper',str(a.descriptor),str(a.target)]
 guard=str(a.out)+'.'+profile+'.guard.json';start=time.monotonic()
 rc=subprocess.run([sys.executable,str(here/'guarded-run.py'),'--out',guard,'--seconds','450','--rss-mib','4096','--',*command],stdin=subprocess.DEVNULL).returncode
 receipt['stages'].append({'profile':profile,'command':command,'guard':guard,'returncode':rc,'wallSeconds':time.monotonic()-start});save()
 if rc:raise SystemExit(rc)
receipt['baseFileChecks']={name:{'beforeSha256':before[name],'sourceSha256':sha(a.source/name),'targetSha256':sha(a.target/name)} for name in files}
receipt['baseFilesUnchanged']=all(len(set(v.values()))==1 for v in receipt['baseFileChecks'].values())
receipt['landmarks']={x.name:{'bytes':x.stat().st_size,'sha256':sha(x)} for x in a.target.glob('landmarks_*')}
receipt['complete']=receipt['baseFilesUnchanged'];save()
if not receipt['complete']:raise RuntimeError('Graph base changed during preparation')
print(json.dumps({'complete':True,'receipt':str(a.out),'identity':identity}),flush=True)
