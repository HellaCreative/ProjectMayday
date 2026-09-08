# National live pack integration

Base live routing: b3cb2fa. No Routing Final Refinement algorithm changes included.
National candidate: fabric-v4-20260908-03, 63 regions, 138 adjacent pairs.

The full compact audit topology is 336 MiB and remains a published candidate
artifact. The bundled live index retains all 770,848 directed-region rows but
projects only the fields actually read by topologySeamCandidatesFromIndex:
coordinate, gapMeters, osmNodeId, osmWayId and edge accessForward/accessReverse.
Region metadata and topology metadata remain unchanged. Proof descriptions,
barrier decisions and turn audit records remain in the full pack audit rather
than duplicated in this live shortlist index. Actual route searches still use
the complete legal graph. No crossings are removed, rounded or capped by this
projection.

Compared full versus projected selection for every pair in both directions,
with allowUnknown false/true and allCandidates enabled: 552 deep-equality checks
passed. Projection is 123,704,776 bytes JSON, 9,818,275 bytes gzip. Loader readback
confirms 63 regions/138 pairs. Evidence and generation script remain in main
candidate03/runtime-index-verification.json and prepare-runtime-index.cjs.

The loader replaces the old bundled five-region index only in this isolated
service worktree. Keep DIRT_V4_CONNECTION_REVISION empty (old overlay is not for
this release). Set DIRT_V4_REGIONS to all 63 and base overrides to candidate03
only in a verified preview, then coordinated stable DEV activation. Full upload
and live route checks are pending. No production or downloads authorized.

## Memory correction

Preview ef34451 completed AB/BC but Vercel killed both AL/GA requests for memory
exhaustion. Whole-national lookup retention is removed: 63 region gzip files
retain the exact projected content and are loaded through a three-region LRU.
Header remains immediately available. All 63 decoded regions compare equal to
the previous full projection on two passes (126 comparisons), including rereads
after eviction. No candidate filtering, rounding or routing scoring changes.
Previous full-to-projection 552 selection checks still establish field parity;
new per-region equality establishes loader parity. Live replay remains required.

## Single-point fuel region correction

Richard’s build22 Massachusetts destination (-72.66903969731547, 42.42887651518565) was assigned to NY by coarse bounding boxes. The integrated service also retained only23 administrative polygons, omitting MA. Imported the existing complete63-region OSM boundary record from main commit8dfb04f; all23 pre-existing geometries are exactly unchanged. This is service selection data, not a graph-pack rebuild.

Single-point fuel lookup now applies shared polygonOwner when the owner belongs to candidate regions; explicit resolvedRegionId/regionIdHint and multi-location selection retain existing behavior. No graph download is introduced for fuel-file selection. Regression coverage includes MA exact device point, lng spelling, NS02 candidate identity, NY, VT, NH, and no mutation of input. All3 fuel tests and8 endpoint/polygon/canary tests pass locally. Hosted verification remains outstanding; stable DEV unchanged.

This shared JS API correction applies equally to online clients. Swift/offline parity remains deferred under the explicit live-only instruction; Android has no client-specific implementation change here. Replacement routing scope belongs to the routing agent (NS/NB); this national data integration does not expand that engine.
