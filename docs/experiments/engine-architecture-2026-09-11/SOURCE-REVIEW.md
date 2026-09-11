# Source-based architecture screening — active

Exact upstream revisions:versions.json. Source checkouts under~/.codex/experiments/routing-architecture-20260911/sources. No engine rejected yet.

## Valhalla3.8.3

Inspected src/baldr/graphreader.cc:tile_extract_t reads an archive;GraphReader chooses mapped archive tiles or tile directory;TileCacheLRU supports eviction based on bytes. This is genuine geographic topology access rather than our prior columnar random paging adapter. Inspect hierarchy relaxation/shortcuts against custom surface weighting before claiming exact preference support.

Inspected src/sif/motorcyclecost.cc:use_trails>=.5 only gives a cubic negative surface adjustment capped by-.125 at1; it is not DIRT's10/30paved-vs-dirt candidate scoring. Separate dynamic-cost extension or candidate generation/ranking required. Existing motorcycle access is preferable to assuming car eligibility, but import semantics still need a contract fixture. Python actor calls release the GIL;one Actor per active worker and tile-cache thread safety must be explicit.

Upstream pyvalhalla wheel runs the native actor but its installed valhalla_build_tiles wrapper has no bundled executable. Building the actual C++ data tools from pinned source is underway;this packaging issue is not an engine rejection.

## GraphHopper11.0

Inspected supplied motorcycle.json,CarAccessParser.java,CustomWeighting.java and config-example.yml. Supplied motorcycle model uses car_access and excludes track grades>1;CarAccessParser itself excludes some grades/paths before custom weights run. Custom weights cannot resurrect importer-rejected edges. A DIRT-specific importer/encoded-value integration is needed, not just relabeling the default motorcycle profile.

CustomWeighting combines distance/(speed*priority) with distance influence. This can represent additive surface penalties and intermediate wander charges if import attributes/base costs are designed consistently. Balanced50/50 remains candidate-pool selection rather than an additive shortest-path objective. CH is profile-prepared;LM preparation can be reused only when request weights never fall below the preparation weights. Road benchmark imports car with actual turn costs and prepares both CH and16landmarks;MMAP storage selected.

## OSRM26.9.0

Inspected profiles/car.lua,include/engine/engine_config.hpp,Python build metadata/stubs. Car Lua enables restrictions and continue-straight-at-waypoint but its eligibility/speeds are not DIRT. EngineConfig supports shared memory and mmap. Native Python wheel contains extract,partition,customize,routed commands, so local graph generation does not require rebuilding the binary. MLD can serve a prepared network;per-request arbitrary cost/profile semantics require examination/customization and likely separate prepared metrics. Ordinary fastest/routability roads are only an R-tier control.

## Resource decisions

First common input:dated2026-09-07 Geofabrik NS/NB/Maine merged by exact OSM identity,253,883,602bytes. Original source hashes and timing receipts in data/*-source.json. Merge is not a published map-pack change. No corridor clipping is used. Date/eligibility differ from DIRT's immutable V4 release,so ordinary-road timings are not parity claims.

Tools installed:isolated pyvalhalla3.8.3,osrm-bindings26.9.0,upstreamGraphHopperjar;Homebrew CMake,Luajit,protobuf-c,spatialite-tools/readosm needed for Valhalla. Homebrew also installed newer protobuf/abseil dependency versions;automatic cleanup disabled so prior versions remain. No user app/process was stopped.
