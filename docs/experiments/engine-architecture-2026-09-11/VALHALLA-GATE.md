# Valhalla DIRT compatibility gate — bounded investigation complete

Pinned Valhalla 3.8.3, source a60c7cbfc83e073f50887cd27e0109d02e6b64e5. All new scripts are in `scripts/routing-architecture/valhalla-spike/`; artifacts are outside the repository at `/Users/richardsmith/.codex/experiments/routing-architecture-20260911/valhalla-spike`. No shared source, published pack, or product runtime changes.

## Evidence already executed

`import-check.lua` calls the actual upstream `lua/graph.lua` `ways_proc` function on eight tag combinations. `access-reference.js` calls DIRT's independent existing access classifier on the same inputs. Raw results: `import-check.tsv`, `access-reference.json`.

| Input | Valhalla transform | DIRT reference | Consequence |
|---|---|---|---|
| access=no, motorcycle=yes | motorcycle allowed | through allowed | Specific permission works |
| untagged track | motorcycle allowed | unknown | Need preserved access provenance and request filtering |
| untagged path | motorcycle denied | unknown | Unknown-enabled routing cannot recover this road merely by changing weights |
| motorcycle=yes, motorcycle:forward=no | both directions allowed | forward denied | Import transform must explicitly preserve motorcycle direction rules |
| motorcycle=yes, motor_vehicle:forward=no | forward denied | forward allowed | Current transform order differs from DIRT specificity |
| access=private | allowed bit plus private flag | denied | Stock private/destination policies require independent verification, not access-bit equivalence |
| access=destination | allowed bit plus private flag | endpoint-only | Need exact endpoint exception audit |
| motorcycle=no | both denied | both denied | Basic explicit denial works |

These findings concern the supplied transform, not a limitation of tiled graph search. Unknown and specific direction data must survive import. Changing a cost alone cannot restore excluded roads or recover discarded provenance.

## Cost and search integration

Actual `src/sif/motorcyclecost.cc` uses travel time multiplied by density + highway + surface factors, additional track/service factors and transition penalties. `use_trails=1` gives surface-factor -0.125: gravel's coefficient is 0.5, so only a 6.25% factor reduction before other effects. This is not DIRT's distance-based paved penalty 10 or 30. Highway adjustment is another additive factor in this time-based expression, not DIRT's class-specific multiplicative factor.

A native custom `DynamicCost` implementation can express DIRT's fixed additive candidate objectives, including the wander distance charge; `CostFactory::Register` is a source integration hook. It also needs a consistent A* lower bound and a hierarchy/shortcut correctness audit. This is an engine extension, not an available JSON cost expression in the stock actor. Balanced's closeness to 50/50, finite-pool ranking, lexicographic city exposure, and fuel constraints remain higher-level work even after this extension.

The stock graph surface enum also does not preserve every source surface leaf/provenance needed by DIRT; retain a source identity/attribute sidecar or extend import encoding. Derivation should use verified V4 identities for an exact comparison rather than treating the newer public OSM import as parity.

## Arrival state and fuel

Source `src/thor/route_action.cc` recognizes both `through` and `break_through`; it pins the previous edge's direction for the next leg. The next `get_path` call starts a separate search. Direction pinning alone does not prove preservation of a preceding via-way restriction prefix. The synthetic forbidden from→via→to chain below tests this directly.

A fuel wrapper that calls independent endpoint routes cannot claim full compatibility. An integration must carry restriction history and arrival direction through station refill, use actual directed road distance with partial starting fuel/reserve, handle station exclusions and destination escape, and preserve alternatives that satisfy range. None of these are established by ordinary motorcycle routing or stop insertion.

## Executable fixture

`fixture.py` produces tiny synthetic OSM with a shorter paved versus longer gravel choice and a separate via-way restriction plus legal detour. `run-check.py` runs actual native actor requests across trail/highway settings and stop types. The coordinator granted a <=256 MiB correctness slot; outcomes follow below. No DIRT regional timing/fuel qualification is claimed.

Existing common Atlantic R-tier results are in `atlantic-road-summary.json`: 360 requests across all engine/modes, with Valhalla NSNB warm median 10.566ms and observed resident 96.52MiB. These are ordinary car results and explicitly do not establish this compatibility gate.

## Native checks completed

The tiny build and actor run succeeded under the granted one-thread, 256 MiB / 60 second guard. Both finished within one sampling interval, so the guard's sampled RSS is not a useful peak estimate; actor `getrusage` high water was 59,195,392 bytes. No performance claim is made from these overlapping tiny correctness runs. The first harness assumed GeoJSON but the motorcycle actor returned encoded polyline; that harness error is preserved in `actor-check-harness-shape-failure.json`, and explicit decoding fixed it.

16 native requests and independent geometry audit (`assert-check.py`) establish:

- All 12 combinations of use_trails 0/.5/.75/1 and use_highways 0/.5/1 chose the 1,731 m paved route. The variable middle is approximately 1,573 m paved versus 2,062 m gravel. Both exact DIRT10 and DIRT30 distance objectives prefer the gravel middle; common paved endpoint tails cancel. The fixture uses equal road class/speed and explicit motorcycle=yes. These highway settings are a control, not a proof of highway avoidance on a mixed-class network.
- The restricted no-stop route uses ways 201→204→203 and a 2,690 m legal detour. With a stop halfway along via way 202, **break, through, and break_through all yield ways 201→202→203, the explicitly forbidden sequence**, and 1,731 m. The audit independently maps returned geometry to fixture source ways; it does not rely on engine maneuver wording.

This rejects the stock multi-waypoint API as a restriction-safe fuel wrapper. It does not reject Valhalla's tiled graph, or demonstrate a fix. Fuel range, partial fuel, reserve, exclusions, history across separate calls and destination escape remain unimplemented.

## Smallest credible continuation extension (source-reviewed, not implemented)

The precise loss is visible in `src/thor/route_action.cc`: the leg loop calls `path_algorithm->Clear()` (around line 779), then at lines 802–808 pins only `last_edge` for a through origin. `BidirectionalAStar::SetOrigin` at lines 1003–1081 creates a fresh label with `kInvalidLabel` predecessor. `DynamicCost::Restricted` (`valhalla/sif/dynamiccost.h`, lines 567–695) walks the predecessor labels through `ComplexRestriction::WalkVias` and compares the preceding from-edge. A last-edge identifier cannot satisfy that check when the origin is inside a via sequence.

A bounded first extension should retain the existing tiled `GraphReader`, costing and forward A* expansion, and add an internal **continuation context** to `PathAlgorithm` / `UnidirectionalAStar::GetBestPath` and `SetOrigin` (`src/thor/unidirectional_astar.cc`, lines 476, 693). Context must carry the ordered, direction-specific detailed GraphIds preceding the pump, the pump edge and percent-along, the graph artifact identity, applicable mode/access policy and time context, and actual remaining fuel. Convert DIRT's source-edge history only through a pinned verified source→GraphId map; reject mismatched generations or unresolved history.

The narrowest first implementation is a separate immutable history chain for restriction checks, spliced behind the first new origin label when its predecessor would be invalid. If history ends on the same directed edge containing the pump, represent that edge once while charging only the remaining fraction. Restriction evaluation must consult the history chain at that boundary without letting the edge-status reset helper reopen history-only edges. Alternatively, seed history-only predecessor labels, but then explicitly stop path reconstruction/cost accounting at the new leg origin and exclude these labels from the adjacency queue and edge-status map. Otherwise already-travelled geometry/cost may be emitted or old edges reset. At a junction, evaluate the saved incoming edge's simple turn mask, barrier/destination-only state and legal outgoing direction before creating any origin label. A snap/heading hint is insufficient.

Start with the existing forward search rather than bidirectional joining: `SetForwardConnection` / `SetReverseConnection` and `IsBridgingEdgeRestricted` also inspect predecessor chains, so bidirectional continuation needs corresponding history-aware join tests. No need to replace the tiled graph, but this is a real search/API patch. Test all source restriction walks against V4, including restrictions spanning multiple fuel stops, a pump on the via edge or junction, reversal, only-rule overlap, graph seams and retained 256-edge/30 km history.

This continuation hook alone still cannot turn one shortest path per station into a correct fuel solver. Fuel labels must distinguish arrival direction/restriction state and remaining fuel; an ordinary edge-status table holding one best cost can discard a longer arrival with sufficient fuel or a different legal continuation. Reuse Valhalla's tile access and cost evaluation in a resource-label search, or extend its labels/dominance to include these states. An exact station layer must enumerate materially distinct arrivals and range-feasible connections; simply retrying shorter-distance car routes would change the objective. This is more adaptation than the endpoint wrapper initially suggests.

## Strong-cost hierarchy implications

`MotorcycleCost::AStarCostFactor` is time-derived; replace it with an admissible bound in the new distance-cost units (e.g. minimum per-meter factor including wander, with nonnegative transition costs). Preserve actual meters separately for fuel, independent of weighted cost. Unknown/dirt provenance and exact class factors must be imported, not inferred from lossy surface categories.

First correctness runs should disable hierarchy pruning and shortcut use. `BidirectionalAStar` explicitly skips shortcut edges when hierarchy limits are unlimited (`ignore_hierarchy_limits_`, lines 148–155 and 199–205). Default hierarchy pruning can stop lower-class exploration away from endpoints, precisely where strong dirt preference may need it. A coarse path that suppresses those roads is not a proof of the DIRT optimum. Re-enabling hierarchy requires comparisons against full detailed search across long mixed-class routes, proof that shortcut weights compose the custom cost/attributes correctly, and safe lower-bound guidance which leaves alternatives discoverable. Disabling hierarchy retains tiled on-demand graph access but may remove much of Valhalla's long-route speed advantage; measure before selecting it.

## Reproduction and recovery

From the private architecture checkout, run `python3 scripts/routing-architecture/valhalla-spike/fixture.py`, then convert the generated external fixture using `osmium cat <external>/fixture.osm -o <external>/fixture.osm.pbf --overwrite`. Build with the already installed `<engine-root>/sources/valhalla/build/valhalla_build_tiles -c <external>/config.json <external>/fixture.osm.pbf` under `guarded-run.py --rss-mib 256 --seconds 60`. Use the existing `<engine-root>/tools/venv/bin/python` for `run-check.py`, then system Python for `assert-check.py`. Execute `luajit import-check.lua <engine-root>/sources/valhalla` and `node access-reference.js` for the importer comparison. Exact successful build/check commands are preserved in external `build.json` and `check-run-v2.json`; `identities.json` pins source and fixture hashes.

The fixture is entirely synthetic and disconnected from published packs. It can be regenerated from the scripts. Recovery consists of returning to the unchanged prior checkpoints and ignoring/removing only this experiment's external `valhalla-spike` folder; no shared engine source was patched. Gate disposition: credible native extension, **stock importer/cost/waypoint wrapper rejected for DIRT parity**. The coordinator should compare adaptation cost with GraphHopper and OSRM before funding a full Valhalla extension; repeated ordinary regional timings remain separate R-tier evidence.

## Eastern import memory investigation and bounded adaptation

The seven-region tile build failed its 4 GiB process RSS guard at 123.14 s / 4,314.59 MiB. It was not killed by an unexplained engine timeout. The last stage log was “Clarifying and fixing cul-de-sacs”. Samples show ~241 MiB through 112 s, then ~400 MiB/second growth as the scan touched `way_nodes.bin` (2.4 GiB) and `ways.bin` (2.1 GiB). `PBFGraphParser::ParseWays` calls `culdesac_processor::clarify_and_fix`; this walks every mapped node and reads every associated mapped way. `sequence` uses whole-file shared mappings. This evidence supports file-backed residency as the immediate cause, not a retained in-memory graph or the runtime tile cache.

Configuration-only fixes are not supported by this phase: `max_cache_size` controls GraphReader, and the configured `id_table_size` is read by the admin parser, not this scan. One thread can lower later parallel costs, but the failing scan is already serial. Disabling driving roads, pedestrian loops, or cul-de-sac processing would change data/decisions. Independently building administrative extracts and concatenating tile folders is unsafe because overlapping tile/local identifiers and cross-boundary restrictions need global reconciliation. No geographic clipping is proposed.

Implemented an isolated streaming replacement for this scan: flush existing files, read sequential node records through `ifstream`, fetch each new way by its exact index through another stream, and keep the unchanged intersection/cul-de-sac decision logic and sparse final writes. All roads and records remain. Expected phase residency is near the pre-scan ~241 MiB plus streams and sparse loop pages, rather than touching the complete ~4.5 GiB mappings; this is a hypothesis until measured. OS file cache can still contain bytes outside process RSS; this is not a claim of equal reduction in machine-wide physical memory. Extra buffered I/O/seek overhead may increase build time.

`make-streaming-parser-patch.py` generates `culdesac-streaming.patch` and `pbfgraphparser.streaming.cc` in external `valhalla-spike`; the shared pinned source remains untouched. `make-streaming-test.py` extracts the old and new actual classes and compiles them against actual `OSMWay`, `OSMWayNode` and `sequence` types. 128 combinations of loop intersection patterns produce byte-identical node and way files. The fixture-only node-count setter covers <=4-node ways; it does not test the upstream large-node saturation branch. First compile failed an unresolved setter, preserved; the corrected test compiled under 256 MiB (173.75 MiB sampled) and passed. Results: `streaming-test-result.txt`, command/guard `streaming-test-compile-v2.json`.

`build-streaming-parser.py` prepares exact compiler flags from the existing CMake build, compiles only the private replacement parser object, then links that object ahead of the read-only original archive into a private tile-builder binary. `streaming-build-plan.json` contains the exact commands. Running requires the coordinator's heavy-work slot; no shared object/archive/executable is overwritten. The unfinished eastern files cannot be safely resumed at `parserelations`: `ParseWays` had not returned and saved its OSMData metadata. Retry from parseways/initialization in a separately named artifact directory, preserving failure evidence. Separate stage processes via `--end parseways`, `--start parserelations` etc. can release retained stage state after successful metadata serialization, but do not solve the failing scan by themselves. Later whole-file sort/scan phases may expose additional memory limits; this first fix is not proof the full import fits.

The private parser-object build/link subsequently succeeded in the granted 1,536 MiB / 300 s slot: 16.77 s, 611.61 MiB sampled peak. A first compiler invocation lacked the original source directory's local `scoped_timer.h` include; adding that read-only include path resolved it, with failure log preserved. Shared source `git status` remains clean. Binary: `/Users/richardsmith/.codex/experiments/routing-architecture-20260911/valhalla-spike/valhalla_build_tiles_streaming`, SHA-256 `32e2dd3d124e04c274b63c2ac9fe500d32851a69ddbb7d56aec1a747c47a46f6`. Full binary/object/source/config identities are in `streaming-binary-identity.json`.

Prepared retry configuration is `valhalla-spike/valhalla-eastern-streaming.json`; it changes only artifact directory and concurrency from 2 to 1, preserving all imported roads and semantic settings. New output directory is `valhalla-spike/eastern-streaming-tiles`. Verified stage commands are in `eastern-streaming-retry-plan.json`. No regional retry has been launched by this subtask; the coordinator controls the memory slot.
