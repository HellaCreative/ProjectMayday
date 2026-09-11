"""One unified contract, route admission then load; never load-test an invalid route."""
from pathlib import Path
import json,subprocess,sys,os,time,hashlib
r=Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911');out=r/'unified-stress';here=Path(__file__).resolve().parents[1]
contract={'route':'NS to WV (eastern North America; not literally transcontinental)','anchors':[{'id':'start','lon':-63.34018,'lat':44.76481},{'id':'end','lon':-80.19745,'lat':38.99357}],'joined':'/tmp/dirt-prepared-joins/nb+ns+ny+pa+qc+wv','fuelMeters':120*1609.344,'pavedFactor':500,'unknownSurfaceFactor':500,'knownDirtFactor':1,'allowUnknownMotorizedAccess':False,'startFuel':'full','reserveFraction':0,'urbanMask':json.loads((out/'mask-receipt.json').read_text()),'load':{'simultaneousClients':500,'activeWorkerLimit':2,'totalDeadlineSeconds':180,'processGroupRssMiB':4096,'resultCache':False},'routeDeadlineSeconds':90,'stationEvidence':'OSM fuel nodes matched to legal road projections; physical entrances/operating status not independently established'}
(out/'contract.json').write_text(json.dumps(contract,indent=2))
report={'contractSha256':hashlib.sha256((out/'contract.json').read_bytes()).hexdigest(),'engines':{},'scope':'New contract. Prior simpler results are not passes. At route admission failure, concurrency is not run.'}
def run(name,cmd,env=None):
 guard=out/(name+'.guard.json')
 if guard.exists():raise RuntimeError('Existing results must be preserved; refuse implicit rerun')
 rc=subprocess.run([sys.executable,str(here/'guarded-run.py'),'--out',str(guard),'--seconds','200','--rss-mib','4096','--',*cmd],env=env).returncode
 return {'returncode':rc,'guard':json.loads(guard.read_text())}
report['engines']['bespoke']=run('bespoke',[ 'node',str(here/'unified-stress/bespoke.js')])
p=out/'bespoke-response.json'
if p.exists():
 a=json.loads(p.read_text());report['engines']['bespoke']['route']={'stage':a.get('stage'),'road':a.get('road',{}).get('state'),'fuel':a.get('fuel',{}).get('state'),'reason':a.get('fuel',{}).get('reason')}
(out/'results.json').write_text(json.dumps(report,indent=2))
env=dict(os.environ,JAVA_TOOL_OPTIONS='-Ddirt.stressMask='+str(out/'blocked-source-edges.bin'))
report['engines']['graphhopper']=run('graphhopper',[sys.executable,str(here/'verified-bench.py'),'--dataset','wv','--case','wv-road','--profiles','dirt30','--repeat','1','--usable-range-meters',str(contract['fuelMeters']),'--initial-usable-meters',str(contract['fuelMeters']),'--fuel-portfolio','--out',str(out/'graphhopper-response.json')],env)
p=out/'graphhopper-response.json'
if p.exists():report['engines']['graphhopper']['runs']=json.loads(p.read_text()).get('runs',[])
for engine,reason in [('valhalla','Current regional DIRT500 importer/costing/fuel-history adapter unavailable; large tiles incomplete. Cannot substitute stock car/motorcycle behavior.'),('osrm','Current regional data has car metric, not requested500x metric plus hard mask and qualified fuel integration. Cannot substitute earlier MLD car results.')]:report['engines'][engine]={'status':'not_qualified_for_contract','reason':reason,'concurrencyRun':False}
(out/'results.json').write_text(json.dumps(report,indent=2));print('Route admission stage finished; inspect proofs before any500-client execution.',flush=True)
