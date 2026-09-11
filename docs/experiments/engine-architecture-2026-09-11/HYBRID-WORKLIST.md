# Hybrid implementation deep dive

Owner authorized implementation after checkpoint
`f3a10ffe10ae7f319af263073e7694bdbcb67afd`. Work remains local/private.
The first refinement milestone is implemented and reviewed; the broader product
checklist remains open where specified. See [evidence and limits](HYBRID-REFINEMENT.md).

- [x] Diagnose and improve the measured long-route bottleneck: stronger pinned
  strict-cost LM index, exact WV proof retained, first request 48.0 → 35.9 s.
- [x] Implement and compare legal downstream fuel rejoining, objective-aware
  excursions and early retry. Retain a verified incumbent when refinement fails.
- [x] Separate heap, mapped-buffer capacity, allocation, GC and external RSS;
  document the timing/resource schema and validate 20 measured records.
- [x] Implement bounded workers/queue, expiry, active/queued cancellation,
  duplicate-ID rejection and recovery; local service checks pass.
- [x] Expand into dense Quebec, repeat NSNB four additive objectives, and compare
  strict WV serial and two concurrent requests with independent audits.
- [x] Preserve rejected approaches, raw evidence, review report and checkpoint.
- [ ] DIRT product character: share fuel-aware candidates across Dirt/Balanced/
  Clean and apply the accepted final ranking. Quebec dirt30 has less known dirt
  than dirt10 after different fuel fallbacks; penalty strength is insufficient.
- [ ] Physical station entrances, continuation import, arbitrary rider waypoints,
  editing and destination fuel evidence beyond a legal road projection.
- [ ] Broader ranges, fuel off/on, Ontario and additional accepted crossings;
  every-region coverage and unreasonable-backtracking acceptance.
- [ ] Hosted CPU/cold-cache/capacity evidence and precise repeated-read accounting.
  Two laptop long routes do not establish 500-client capacity.
- [ ] App, navigation and offline integration/parity. Current envelope explicitly
  says navigationReady=false and productProfileParity=false.

Fuel repair is currently cheap compared with road search, supporting continued
integrated fuel development. Early exploration everywhere and downstream-only
replacement both regressed real cases and were rejected. Scaled existing distance
bounds saved less than 1% of visits and added overhead; disabled by default.
The stronger strict index requires a fixed compatible mask/cost family and cannot
be generalized silently to product profiles. CH and predictive GPS warming remain
unadopted; no daemon, infrastructure or deployment was introduced.
