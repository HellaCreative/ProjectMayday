"""Exact full-polyline intersections; conservatively exclude each intersecting source edge."""
import pathlib,json,hashlib,struct,time,shapefile,numpy as np,shapely
from shapely.geometry import shape
from shapely.strtree import STRtree
r=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911');out=r/'unified-stress';d=json.loads((r/'data/verified-wv/verified-input.json').read_text());joined=pathlib.Path(d['root']);started=time.perf_counter()
polys=[shape(x.__geo_interface__) for x in shapefile.Reader(str(out/'urban/ne_10m_urban_areas.shp')).shapes()]
assert all(shapely.is_valid(polys)),'Invalid mask polygons require explicit repair review'
tree=STRtree(polys);regions=np.memmap(joined/'sourceRegions.bin',dtype='<u2',mode='r');locals_=np.memmap(joined/'sourceEdges.bin',dtype='<u4',mode='r');blocked=np.zeros(d['edgeCount'],dtype='u1')
for ri,path in enumerate(d['geometryPaths']):
 with open(path,'rb') as f:header=f.read(16)
 count=struct.unpack_from('<I',header,8)[0];width=8 if struct.unpack_from('<H',header,6)[0]&1 else 4
 offsets=np.memmap(path,dtype='<u4',offset=16,shape=(count+1,),mode='r');base=(16+4*(count+1)+width-1)&~(width-1);coords=np.memmap(path,dtype='<f8' if width==8 else '<f4',offset=base,mode='r')
 ids=np.flatnonzero(regions==ri)
 for at in range(0,len(ids),10000):
  selected=ids[at:at+10000];rows=[coords[offsets[e]:offsets[e+1]].reshape(-1,2) for e in locals_[selected]]
  lengths=np.array([len(x) for x in rows]);assert all(lengths>=2)
  lines=shapely.linestrings(np.concatenate(rows),indices=np.repeat(np.arange(len(rows)),lengths))
  pairs=tree.query(lines,predicate='intersects')
  if pairs.size:blocked[selected[np.unique(pairs[0])]]=1
 print(json.dumps({'region':ri,'examined':len(ids),'blockedTotal':int(blocked.sum())}),flush=True)
path=out/'blocked-source-edges.bin';path.write_bytes(blocked.tobytes())
report={'sourceManifestSha256':d['sourceManifestSha256'],'sourceIdentity':d['identity'],'maskSource':json.loads((out/'urban-source.json').read_text()),'maskSha256':hashlib.sha256(path.read_bytes()).hexdigest(),'edges':len(blocked),'blockedEdges':int(blocked.sum()),'seconds':time.perf_counter()-started,'semantics':'Entire source edge excluded if any full-polyline portion intersects an urban polygon, including boundaries; conservative at edge granularity. No geographic corridor clipping.'}
(out/'mask-receipt.json').write_text(json.dumps(report,indent=2))
