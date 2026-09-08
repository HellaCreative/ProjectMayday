# Quebec live canary — September 8, 2026

Live JavaScript only. Quebec rebuilt using the Atlantic toll/access correction from the locked September 6 OSM source. Candidate fabric-v4-20260908-02 reuses the accepted Atlantic graph, geometry, fuel and rider-service bytes without rebuilding them, and regenerates connection records for NS, NB, PE, NL and QC. Original releases remain unchanged.

Quebec graph: 8c9a422b1d149ebd187963672620b269b50246461e16748f33d57da428db0f3b. Factory commit: 0d7553663dd3fc7f71dc3fa9cc07b7bb678e699e. Per-region reuse provenance is in release.json.

Purpose: verify the larger pack and Atlantic connections before wider rebuild. Automated live and physical acceptance remain pending. Route quality is a separate unresolved task. No Swift changes, phone installation, download publication, or production publication. Future Swift/Android parity must reproduce accepted live changes; none is claimed by this data-only canary.
