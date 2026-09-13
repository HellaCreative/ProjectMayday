"""Audit saved recovery outputs without changing routing or acceptance thresholds."""
import argparse, collections, json, math
from pathlib import Path


def coordinate(p):
    if isinstance(p, dict):
        return (p.get('lon', p.get('longitude')), p.get('lat', p.get('latitude')))
    return tuple(p[:2])


def meters(a, b):
    x1,y1,x2,y2 = map(math.radians, (*a,*b))
    h=math.sin((y2-y1)/2)**2+math.cos(y1)*math.cos(y2)*math.sin((x2-x1)/2)**2
    return 12742000*math.asin(min(1, math.sqrt(h)))


def geometry_audit(segments):
    seen=collections.Counter(); repeated=0; geometric=0; gaps=[]; last=None; ids=[]
    for s in segments:
        points=[coordinate(p) for p in s.get('geometry',[]) or []]
        if not points: continue
        ids.append(s.get('edgeId'))
        if last is not None: gaps.append(meters(last,points[0]))
        last=points[-1]
        for a,b in zip(points,points[1:]):
            distance=meters(a,b);geometric+=distance
            key=tuple(sorted((tuple(round(v,6) for v in a),tuple(round(v,6) for v in b))))
            if seen[key]: repeated+=distance
            seen[key]+=1
    return {'geometryMeters':round(geometric,2),'exactSegmentRepeatMeters':round(repeated,2),
            'maxGeometryJoinGapMeters':round(max(gaps,default=0),3),
            'emptyEdgeIds':sum(not v for v in ids),'duplicateEdgeOccurrences':len(ids)-len(set(ids)),
            'reachedEndpoint':last}


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--swift',type=Path,required=True);parser.add_argument('--js',type=Path,required=True);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args(); args.output.mkdir(parents=True,exist_ok=True)
    records=[]
    for f in sorted(args.swift.glob('*.json')):
        d=json.loads(f.read_text())
        if f.name.startswith('road-'):
            audit=geometry_audit(d['legs']);audit.update({k:d.get(k) for k in ['distanceMeters','dirtPercent','repeatedMeters','timedOut','pass2','profile']})
            audit['requestedDestination']=d['to']
        elif f.name.startswith('oracle-'):
            routes=d['routes'];segments=[s for r in routes for s in r.get('segments',[]) or []]
            audit=geometry_audit(segments);audit.update({k:d.get(k) for k in ['reachedDestination','requestedDestination','reachedEndpoint','failure','profile']})
            audit['distanceMeters']=sum(r.get('distanceMeters',0) for r in routes)
            audit['fuelStopIds']=[s['id'] for s in d['stops']]
            audit['duplicateFuelStops']=len(audit['fuelStopIds'])-len(set(audit['fuelStopIds']))
            audit['hopMeters']=[r.get('distanceMeters',0) for r in routes]
            audit['overRangeHops']=[v for v in audit['hopMeters'] if v>d['usableMeters']+1e-6]
            audit['dirtPercent']=sum(r.get('distanceMeters',0)*r.get('stats',{}).get('dirtPercent',0) for r in routes)/max(1,audit['distanceMeters'])
        else: continue
        records.append({'file':f.name,'runtime':'swift',**audit})
    for f in sorted(args.js.glob('*.json')):
        d=json.loads(f.read_text())
        if d.get('endpoint')!='/api/route':continue
        r=d['result']; audit=geometry_audit(r.get('segments',[]) or [])
        records.append({'file':f.name,'runtime':'js-exact-oracle','status':r.get('status'), 'distanceMeters':r.get('distanceMeters'), 'dirtPercent':r.get('stats',{}).get('dirtPercent'),**audit})
    (args.output/'RECOVERY-GEOMETRY-AUDIT.json').write_text(json.dumps({'method':'Haversine geometry lengths; undirected identical coordinate-segment repeats rounded to six decimals. This is a repeat lower bound, not proof against nearby or differently split repeated roads. Join gaps are reported without inventing an acceptance cutoff.','records':records},indent=2)+'\n')
    print(f'Audited {len(records)} outputs')
    for r in records:
        print(r['file'],r.get('distanceMeters'), 'repeat',r['exactSegmentRepeatMeters'],'join',r['maxGeometryJoinGapMeters'])

if __name__=='__main__':main()
