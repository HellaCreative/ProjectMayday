#!/usr/bin/env python3
"""Build reciprocal border smoke-test requests from immutable source topology.

Endpoints are on known directed roads reachable from a recorded border node,
inside the owning region polygon. This is fixture screening, NOT proof that the
engine can obey turns/barriers or produce a suitable ride. Retain all limitations.
Requires numpy; outputs JSON only, never changes packs.
"""
import argparse, collections, functools, json, math, mmap, struct
from pathlib import Path
import numpy as np

parser = argparse.ArgumentParser()
parser.add_argument('packs', type=Path)
parser.add_argument('polygons', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('--only', default='')
args = parser.parse_args()
canada = set('bc ab sk mb on-s on-n qc-s qc-n nb ns pe nl-island nl-lab yt nt nu'.split())
roots = {p.parent.name: p.parent for p in args.packs.glob('*/graph.v4.bin')}
@functools.lru_cache(maxsize=2)
def seams(region):
    return json.loads((roots[region]/'cross-pack-seams.v2.json').read_text())['neighbors']

def rings(region):
    data = json.loads((args.polygons/(region+'.clip.geojson')).read_text())
    result = []
    for feature in data['features']:
        g = feature['geometry']
        result.extend([g['coordinates']] if g['type']=='Polygon' else g['coordinates'])
    return result

def inside_ring(point, ring):
    x,y=point; inside=False
    for a,b in zip(ring, ring[1:]+ring[:1]):
        if (a[1]>y)!=(b[1]>y) and x < (b[0]-a[0])*(y-a[1])/(b[1]-a[1])+a[0]: inside=not inside
    return inside

def inside(point, polygons):
    return any(inside_ring(point,p[0]) and not any(inside_ring(point,h) for h in p[1:]) for p in polygons)

def seam_key(row):
    return (row['osmNodeId'],row['osmWayId'],row['localEdgeId'],row['remoteEdgeId'])

pairs=[]; tasks=collections.defaultdict(list)
for a in sorted(roots):
    if args.only and not any(a in pair.split('--') for pair in args.only.split(',')): continue
    for b in sorted(seams(a)):
        if b not in roots or a>=b or (a in canada and b in canada): continue
        key=a+'--'+b
        if args.only and key not in args.only.split(','): continue
        opposite={seam_key(r) for r in seams(b).get(a,[])}
        legal=[r for r in seams(a)[b] if seam_key(r) in opposite and (r['edge']['accessForward']==0 or r['edge']['accessReverse']==0) and not r['barrierDecision']]
        if not legal:
            pairs.append({'regions':[a,b], 'error':'no reciprocal known permitted seam for fixture'})
            continue
        # Sample geographically distributed recorded connections, trying another
        # if one is only a tiny source component; never invent a connection.
        legal=sorted(legal,key=lambda r:tuple(r['coordinate']))
        choices=[legal[int((len(legal)-1)*f)] for f in [.5,.25,.75,0,1,.125,.375,.625,.875]]
        pairs.append({'regions':[a,b], 'anchors':choices})
        for region in [a,b]: tasks[region].append((key,choices))

selected={};manifests={}
for region, requests in tasks.items():
    polygons=rings(region)
    points=np.asarray([v for p in polygons for v in p[0]])
    center=(points.min(axis=0)+points.max(axis=0))/2
    manifests[region]=json.loads((roots[region]/'pack-manifest.v2.json').read_text())
    with (roots[region]/'graph.v4.bin').open('rb') as f:
        m=mmap.mmap(f.fileno(),0,access=mmap.ACCESS_READ)
        n,e,a=struct.unpack_from('<III',m,8)
        def array(h,d,count):return np.frombuffer(m,dtype=d,count=count,offset=struct.unpack_from('<I',m,h)[0])
        xy=array(44,'<f4',n*2).reshape(-1,2)
        offsets=array(24,'<i4',n+1);targets=array(28,'<i4',a);edges=array(32,'<i4',a)
        access=array(112,'u1',e*2).reshape(-1,2);osm=array(104,'<i8',n)
        edgeFrom=array(64,'<i4',e)
        for key, choices in requests:
            for choice in choices:
                anchor=np.asarray(choice['coordinate']);scale=math.cos(math.radians(float(anchor[1])))
                delta=center-anchor;delta[0]*=scale;norm=float(np.linalg.norm(delta))
                target=anchor+delta/max(norm,1e-9)*min(norm,.35)/np.asarray([scale,1])
                rootsHere=np.flatnonzero(osm==int(choice['osmNodeId']))
                if not len(rootsHere): continue
                queue=collections.deque(map(int,rootsHere));seen=set(queue)
                candidates=[]
                while queue and len(seen)<150000:
                    node=queue.popleft(); coord=xy[node]
                    if math.hypot((float(coord[0])-anchor[0])*scale,float(coord[1])-anchor[1])>.7: continue
                    degree=0
                    for arc in range(int(offsets[node]),int(offsets[node+1])):
                        edge=int(edges[arc])
                        if access[edge,0 if int(edgeFrom[edge])==node else 1]!=0:continue
                        degree+=1;other=int(targets[arc])
                        if other not in seen:seen.add(other);queue.append(other)
                    if degree>=2:candidates.append(node)
                if not candidates:continue
                ids=np.asarray(candidates); coords=xy[ids]
                ds=(coords-target)*np.asarray([scale,1]);order=np.argsort(np.sum(ds*ds,axis=1))
                chosen=None
                for index in order[:1000]:
                    point=coords[index].tolist()
                    distance=math.hypot((point[0]-anchor[0])*scale,point[1]-anchor[1])*111000
                    if distance>=10000 and inside(point,polygons):
                        chosen={'point':point,'osmNode':int(osm[int(ids[index])]),'anchorNode':choice['osmNodeId'],
                                'anchor':anchor.tolist(),'reachableNodesScreened':len(seen),'screeningCapped':bool(queue),'offsetMeters':distance}
                        break
                if chosen:
                    selected[(key,region)]=chosen;break
            print(region,key,'selected' if (key,region) in selected else 'FIXTURE UNRESOLVED',flush=True)
        del coord,xy,offsets,targets,edges,access,osm,edgeFrom;m.close()

cases=[];unresolved=[]
for pair in pairs:
    a,b=pair['regions'];key=a+'--'+b
    if (key,a) not in selected or (key,b) not in selected:
        unresolved.append(pair);continue
    for source,dest in [(a,b),(b,a)]:
        start,end=selected[(key,source)],selected[(key,dest)]
        cases.append({'id':source+'-to-'+dest,'kind':'canada-us' if a in canada or b in canada else 'us-border',
            'regions':[a,b],'from':start['point'],'to':end['point'],'screening':{'start':start,'end':end}})
args.output.write_text(json.dumps({'cases':cases,'unresolvedFixtures':unresolved,'packManifests':manifests},indent=2))
print('Wrote',len(cases),'directed tests;',len(unresolved),'unresolved border fixtures',flush=True)
