# National DEV pack activation

Richard authorized all 63 regions in live DEV and DEV downloads on September 9,
while preserving the accepted routing behavior. Production is unchanged.

Frozen routing base: f2da612 / qu663xg1q. The accepted replacement engine remains
scoped to NS/NB; this pack publication does not claim national replacement-engine
or offline algorithm parity. National data loading and existing regional routing
must be checked separately from route-quality acceptance.

New immutable data release: fabric-v4-20260909-01, derived from the sealed
fabric-v4-20260908-03 road fabric and its original locked OSM sources.

- All 63 source hashes rechecked; city/town nodes, ways and relations inventoried.
- Metadata correction preserves every road/legal binary section, geometry, fuel,
  Rider Services and border proof. NS graph is unchanged. NB embeds its exact
  previously accepted supplemental boxes. The loader applies those boxes once.
- Other regions use the existing factory city/town classification thresholds;
  NB's reviewed town threshold is not silently made a new national policy.
- Missing populations remain explicitly unknown. Population-scaled boxes are
  DIRT estimates, not measured OSM urban boundaries. Area records are retained
  for audit and are outside the node-based classification policy.
- Future builds must generate/validate source-locked classification, including
  a valid empty result, rather than silently omitting a missing sidecar.
- New NS/NB pack admission requires exact graph/geometry/fuel checksums. Search,
  costs, fuel candidate rules and limits retain the frozen implementation.
- National crossing lookup retains every existing proof with bounded memory;
  exact regional ownership fixes fuel-file selection at overlapping boundaries.

223 local routing/legal/metadata checks pass. Six accepted NS/NB baseline legs retain exact geometry and fuel-stop identities against the previous frozen results. All 63 regional data revisions
have local byte-identity evidence. Hosted qualification and publication status
live under the candidate's release/upload/verification records; these local
passes do not constitute physical-device acceptance.

App coordination: Routing Final Refinement owns GraphPackStore.swift and
OfflinePacksSheet.swift. Supply verified immutable DEV catalog URLs for its
AppConfig update; do not overwrite its active work. No device installation or
automatic pack transfer is part of this task.

Resource incident: inactive-cache cleanup also removed SourcePackages from the
app agent's active DerivedData folder because age/open-file checks were
insufficient. Cleanup stopped; app agent was informed and is restoring its
dependencies. No source, sealed OSM/pack data or test evidence was removed.
