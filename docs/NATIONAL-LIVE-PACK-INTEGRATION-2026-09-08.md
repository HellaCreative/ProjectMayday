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
