# National qualification candidate

Not deployed. Service national-v1 flag added;214adventure fixture tests pass,
including3region restriction preservation and duplicate-region rejection.
Exact63-region graph/geometry/fuel admission imported from audited release09.

Real local pack smoke (single process per case, original immutable bytes):
- PEI Balanced fuel:75.072km complete,431ms,126032KiB peakRSS.
- VT/NH Balanced fuel:7.243km complete,5017ms,1089296KiB peakRSS.

These are local smoke tests, not hosted or comprehensive nationwide acceptance.
VT/NH uses over1GB RSS despite a short route: big-region/multi-region memory is
an explicit remaining qualification concern. Runner saves complete result and
uses actual decoded packs. Fixtures in bench/fixtures/national-*.json.

Remaining:3+realregion, long/crosscountry/state/province routes, fuel replacements,
customsettings, runtime deadlines/cache behavior, hosted exactrelease deployment,
Swift offline parity and release archive/signing. Do not activate national based
only on these two successful smokes. Accepted Loop/navigation/fuel behavior frozen.
