"""Bounded public source acquisition; keep a hashed complete routing/admin subset."""
import hashlib,json,pathlib,shutil,subprocess,time,urllib.request
root=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911');data=root/'data'
rows=json.loads((data/'long-source-plan.json').read_text())
rows=[{'id':'ns','url':'https://download.geofabrik.de/north-america/canada/nova-scotia-260907.osm.pbf'},{'id':'nb','url':'https://download.geofabrik.de/north-america/canada/new-brunswick-260907.osm.pbf'}]+rows
def digest(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
for row in rows:
 name=row['id'];out=data/(name+'-roads-260907.osm.pbf');receipt=data/(name+'-roads-source.json')
 if out.exists() and receipt.exists():
  if digest(out)!=json.loads(receipt.read_text())['filteredSha256']:raise RuntimeError('Existing subset identity mismatch')
  continue
 raw=data/(name+'-260907.osm.pbf');downloaded=not raw.exists();start=time.monotonic()
 if downloaded:
  if shutil.disk_usage(data).free<4*1024**3+row['bytes']*2:raise RuntimeError('Insufficient disk reserve for '+name)
  partial=raw.with_suffix('.partial')
  subprocess.run(['curl','--fail','--location','--silent','--show-error','--retry','2','--max-time','600','--output',str(partial),row['url']],check=True)
  if partial.stat().st_size!=row['bytes']:raise RuntimeError('Source size mismatch '+name)
  partial.rename(raw)
 sourceHash=digest(raw);sourceInfo=json.loads(subprocess.check_output(['osmium','fileinfo','-j',str(raw)]))
 cmd=['osmium','tags-filter',str(raw),'w/highway','w/route=ferry','r/route=ferry','r/type=restriction','r/boundary=administrative','n/amenity=fuel','n/barrier','-o',str(out)]
 subprocess.run(cmd,check=True)
 record={**row,'sourceSha256':sourceHash,'sourceInfo':sourceInfo,'filterCommand':cmd,'filteredBytes':out.stat().st_size,'filteredSha256':digest(out),'seconds':time.monotonic()-start,'removedDownloadedRawAfterHash':downloaded,'scope':'All highway/ferry ways, restriction/admin relations and referenced members/nodes, fuel and barrier nodes; whole selected regions, no route corridor. Public source differs from V4; other landuse/POI features omitted.'};receipt.write_text(json.dumps(record,indent=2));print(json.dumps({k:v for k,v in record.items() if k not in ['sourceInfo','filterCommand']}),flush=True)
 if downloaded:raw.unlink() # only this script's reproducible raw download; never previous experiment inputs
target=data/'eastern-260907.osm.pbf'
if not target.exists():subprocess.run(['osmium','merge']+[str(data/(r['id']+'-roads-260907.osm.pbf')) for r in rows]+['-o',str(target)],check=True)
(data/'eastern-source.json').write_text(json.dumps({'regions':[r['id'] for r in rows],'bytes':target.stat().st_size,'sha256':digest(target),'sourceReceipts':[r['id']+'-roads-source.json' for r in rows]},indent=2));print('Eastern input complete',flush=True)
