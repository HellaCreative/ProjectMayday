"""Read-only immutable pack acquisition for the private benchmark (no publication)."""
import hashlib,json,pathlib,sys,urllib.request,concurrent.futures,time,subprocess
catalog=json.load(open(sys.argv[1]));ids=json.load(open(sys.argv[2]));target=pathlib.Path(sys.argv[3]);target.mkdir(parents=True,exist_ok=True)
source=pathlib.Path('/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt/.build/restriction-release-copy/partial-staging/packs')
def digest(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
 return h.hexdigest()
def acquire(item):
 id,file=item;name=file['name'];destination=target/id/name;destination.parent.mkdir(exist_ok=True)
 started=time.monotonic()
 for p in [destination,pathlib.Path('/tmp/dirt-paging-current')/id/name,source/id/name]:
  if p.exists() and p.stat().st_size==file['bytes'] and digest(p)==file['sha256']:
   if p!=destination:
    if destination.is_symlink():destination.unlink()
    destination.symlink_to(p)
   return dict(region=id,file=name,source='verified_local',bytes=file['bytes'],ms=round((time.monotonic()-started)*1000))
 url='https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/v4/releases/'+catalog['fabricReleaseId']+'/'+id+'/'+name
 partial=destination.with_suffix(destination.suffix+'.partial')
 subprocess.run(['curl','--fail','--silent','--show-error','--max-time','300','--retry','2','--output',str(partial),url],check=True)
 if partial.stat().st_size!=file['bytes'] or digest(partial)!=file['sha256']:raise RuntimeError('Pack identity mismatch: '+url)
 partial.replace(destination)
 return dict(region=id,file=name,source='immutable_download',bytes=file['bytes'],ms=round((time.monotonic()-started)*1000))
items=[(r['id'],f) for r in catalog['regions'] if r['id'] in ids for f in r['files'] if f['name'] in ['graph.v4.bin','geometry.v1.bin','fuel.v1.json']]
results=[]
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
 for result in pool.map(acquire,items):results.append(result);print(json.dumps(result),flush=True)
(target/'acquisition.json').write_text(json.dumps({'release':catalog['fabricReleaseId'],'files':results},indent=2))
