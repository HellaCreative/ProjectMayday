"""Summarize evidence without treating simulator data as phone qualification."""
import argparse, json, pathlib, hashlib, statistics
p=argparse.ArgumentParser(); p.add_argument('log',type=pathlib.Path); a=p.parse_args()
rows=[json.loads(x) for x in a.log.read_text().splitlines()]
session=next(x for x in rows if x.get('stage')=='session')
finished=next((x for x in rows if x.get('stage')=='finished'), None)
samples=[x['metrics'] for x in rows if x.get('stage')=='sample']
heartbeats=[x['intervalSeconds'] for x in rows if x.get('stage')=='ui_heartbeat']
def peak(name):
    values=[x[name] for x in samples if name in x]
    return max(values) if values else None
def minimum(name):
    values=[x[name] for x in samples if name in x]
    return min(values) if values else None
queries=[]
for x in rows:
    if x.get('stage')!='query': continue
    value={k:v for k,v in x.items() if k not in ['legs','metricsBefore','metricsAfter','stage']}
    if 'legs' in x:
        value['roadResultSHA256']=hashlib.sha256(json.dumps({k:x[k] for k in ['legs','distanceMeters','knownDirtPercent']},sort_keys=True,separators=(',',':')).encode()).hexdigest()
    queries.append(value)
print(json.dumps({'logSHA256':hashlib.sha256(a.log.read_bytes()).hexdigest(),
    'simulator':session['simulator'],'hardwareIdentifier':session['hardwareIdentifier'],'os':session['os'],
    'sourceManifest':session['manifest'],'sessionCompleted':finished is not None,
    'outcome':finished['outcome'] if finished else 'unfinished',
    'endToEndSeconds':finished.get('endToEndSeconds') if finished else None,
    'loaded':next((x for x in rows if x.get('stage')=='loaded'),None),
    'sampledPeakPhysicalFootprintMiB':peak('physicalFootprintMiB'),
    'sampledPeakResidentMiB':peak('residentMiB'),
    'minimumAvailableDirtyMemoryMiB':minimum('availableDirtyMemoryMiB'),
    'maxThermalState':peak('thermalState'),'sampleCount':len(samples),
    'maxUIHeartbeatIntervalSeconds':max(heartbeats) if heartbeats else None,
    'medianUIHeartbeatIntervalSeconds':statistics.median(heartbeats) if heartbeats else None,
    'batteryLevelStart':session['batteryLevelStart'],
    'batteryLevelEnd':finished['batteryLevelEnd'] if finished else None,
    'queries':queries,
    'limits':'Sampled peaks can miss allocation spikes. Heartbeat is a UI-thread scheduling proxy, not frame-rate measurement. Coarse battery level on a short run cannot establish battery drain. Fuel, full app overhead, long-haul and sustained heat remain unqualified.'},indent=2))
