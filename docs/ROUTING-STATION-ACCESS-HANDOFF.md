# Station access evidence checkpoint

September 8, 2026. Read-only inspection of the five unique stations selected by
the longer Ontario fixtures. No source or pack was changed. Current OSM snapshots
are diagnostic evidence; they are not asserted identical to the pack snapshot.

| Selected station | Source observation | Current route projection offset |
| --- | --- | ---: |
| Killaloe Motel Variety | [Way 519983078](https://www.openstreetmap.org/way/519983078), fuel-tagged building | 35 m |
| XTR, Haliburton | [Node 1864593380](https://www.openstreetmap.org/node/1864593380), standalone fuel marker | 14 m |
| Shell, Burk's Falls | [Way 518563690](https://www.openstreetmap.org/way/518563690), fuel-tagged building at selected location | 23 m |
| XTR, Sundridge | [Way 518561678](https://www.openstreetmap.org/way/518561678), fuel-tagged building | 47 m |
| Esso, Rutherglen | [Node 4114563289](https://www.openstreetmap.org/node/4114563289), standalone fuel marker | 22 m |

The Shell catalog ID is `osm:a1037127380`; retain that canonical ID until its
factory identity mapping is explicitly confirmed. Nearby records must not be
merged or excluded as a closed facility merely from proximity or brand.

None of these records alone supplies a directed entrance → refueling position →
exit route. The two standalone-marker neighborhoods returned no service ways in
the inspected ±0.002-degree box. Other neighborhoods contain service ways, but
proximity does not prove that they serve the station. A fuel-tagged building
polygon is not a forecourt boundary. These findings do not mean the stations are
inaccessible or closed. They mean the current road projection cannot establish
all access travel and permissions. Keep `provisional_station_access`.

The pack/access integration needs source-linked facility identity, actual mapped
access paths where present, and separately stated evidence where access is not
mapped. A useful access record must identify legal entry and exit graph positions,
directed path geometry/distance, applicable restrictions and source revision.
Station visitation must consume that travel and preserve turn history. Never
invent a straight driveway, a midpoint turnaround or a fuel reset at an unrelated
nearby road. The existing engine can search real road arcs; the missing part is
verified station-to-access association and, for some sources, mapped access data.
Current operation/opening availability remains separate from access geometry.

Raw API responses, bounding-box source URLs and extracted tags are preserved in
`routing/candidates/rebuild-on-access/` (sources.json, station-specific .osm files,
source-summary.json). No automatic pack correction is justified by this audit.
