#!/usr/bin/env python3
"""Summarize native replay geometry without treating completion as route quality.

Usage: audit-native-fuel-replay.py <evidence-directory>
Exact undirected segments rounded to six decimals give a lower bound on retrace;
this does not detect differently sampled overlapping roads or prove legality.
"""
import hashlib
import json
import math
import sys
from pathlib import Path


def meters(a, b):
    lon1, lat1, lon2, lat2 = map(math.radians, (*a, *b))
    v = math.sin((lat2-lat1)/2)**2 + math.cos(lat1)*math.cos(lat2)*math.sin((lon2-lon1)/2)**2
    return 12742000 * math.asin(min(1, math.sqrt(v)))


def summarize(path):
    record = json.loads(path.read_text())
    routes = record.get('routes', [])
    seen, repeated, joins, ferry = set(), 0, [], 0
    shapes = []
    previous = None
    for route in routes:
        geometry = route.get('geometry', [])
        shapes.append(geometry)
        if previous and geometry:
            joins.append(meters(previous, geometry[0]))
        if geometry:
            previous = geometry[-1]
        for a, b in zip(geometry, geometry[1:]):
            key = tuple(sorted((tuple(round(x, 6) for x in a), tuple(round(x, 6) for x in b))))
            if key in seen:
                repeated += meters(a, b)
            seen.add(key)
        ferry += sum(s.get('distanceMeters', 0) for s in route.get('segments', []) if s.get('structureType') == 'ferry')
    destination = record.get('requestedDestination', {})
    end = destination if isinstance(destination, list) else [destination.get('longitude'), destination.get('latitude')]
    return dict(case=path.stem, reached=record.get('reachedDestination'), failure=record.get('failure'),
        stops=[s['id'] for s in record.get('stops', [])],
        hopMeters=[r.get('distanceMeters') for r in routes], usableMeters=record.get('usableMeters'),
        shapeSHA256=hashlib.sha256(json.dumps(shapes, separators=(',', ':')).encode()).hexdigest(),
        exactRepeatedSegmentMeters=repeated, reportedBacktrackMeters=sum(r.get('backtrackMeters', 0) for r in routes),
        maxJoinGapMeters=max(joins, default=0), ferryMeters=ferry,
        remainingEndpointMeters=meters(previous, end) if previous and all(v is not None for v in end) else None)


if __name__ == '__main__':
    print(json.dumps([summarize(p) for p in sorted(Path(sys.argv[1]).glob('oracle-*.json'))], indent=2))
